require "http/client"
require "json"
require "base64"
require "uri"
require "compress/gzip"
require "age-crystal"

module Dirless
  module Syncer
    class BackendError < Exception; end

    class BackendClient
      def initialize(
        @base_url : String,
        @hmac_secret : String,
        @tenant_id : String,
        @age_public_key : String,
      )
      end

      private getter age_public_key : String

      # Compresses, encrypts, and PUTs *payload* to the backend.
      # The backend stores the ciphertext without ever seeing plaintext.
      # Plaintext counts are sent as headers so the backend can report stats
      # without needing to decrypt anything.
      def sync(payload : String, user_count : Int32, group_count : Int32) : Nil
        pub_key = Age::PublicKey.new(@age_public_key)
        compressed = gzip(payload)
        ciphertext = Age.encrypt(compressed, pub_key)
        encoded = Base64.strict_encode(ciphertext)
        response = put("/v1/snapshot/aws-identity-center", encoded, content_type: "application/octet-stream",
                       user_count: user_count, group_count: group_count)
        return if response.status_code == 200
        raise BackendError.new("Sync failed (HTTP #{response.status_code}): #{response.body}")
      rescue ex : BackendError
        raise ex
      rescue ex : Age::Error
        raise BackendError.new("Failed to encrypt sync payload: #{ex.message}")
      end

      private def gzip(data : String) : Bytes
        io = IO::Memory.new
        Compress::Gzip::Writer.open(io) { |gz| gz.print data }
        io.to_slice
      end

      private def put(
        path : String,
        body : String,
        content_type : String = "application/json",
        user_count : Int32? = nil,
        group_count : Int32? = nil,
      ) : HTTP::Client::Response
        uri = URI.parse("#{@base_url}#{path}")
        client = build_client(uri)
        headers = auth_headers(content_type)
        headers["X-Dirless-User-Count"]  = user_count.to_s  if user_count
        headers["X-Dirless-Group-Count"] = group_count.to_s if group_count
        begin
          client.put(path, headers: headers, body: body)
        rescue ex : Socket::ConnectError | IO::TimeoutError
          raise BackendError.new("Could not connect to Dirless backend at #{@base_url}: #{ex.message}")
        ensure
          client.close
        end
      end

      private def post(
        path : String,
        body : String,
        content_type : String = "application/json",
        user_count : Int32? = nil,
        group_count : Int32? = nil,
      ) : HTTP::Client::Response
        uri = URI.parse("#{@base_url}#{path}")
        client = build_client(uri)
        headers = auth_headers(content_type)
        headers["X-Dirless-User-Count"]  = user_count.to_s  if user_count
        headers["X-Dirless-Group-Count"] = group_count.to_s if group_count
        begin
          client.post(path, headers: headers, body: body)
        rescue ex : Socket::ConnectError | IO::TimeoutError
          raise BackendError.new("Could not connect to Dirless backend at #{@base_url}: #{ex.message}")
        ensure
          client.close
        end
      end

      private def auth_headers(content_type : String) : HTTP::Headers
        HTTP::Headers{
          "Content-Type"        => content_type,
          "Authorization"       => "Bearer #{@hmac_secret}",
          "X-Tenant-ID"         => @tenant_id,
          "X-Dirless-Recipient" => @age_public_key,
        }
      end

      private def build_client(uri : URI) : HTTP::Client
        client = if uri.scheme == "https"
                   HTTP::Client.new(uri, tls: true)
                 else
                   HTTP::Client.new(uri)
                 end
        client.connect_timeout = 10.seconds
        client.read_timeout = 30.seconds
        client
      end

      private Log = ::Log.for("dirless.syncer.client")
    end
  end
end
