require "http/client"
require "json"
require "base64"
require "uri"
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

      # Encrypts *payload* with the tenant's age public key and POSTs the
      # ciphertext to the backend. The backend never sees plaintext.
      def sync(payload : String) : Nil
        pub_key = Age::PublicKey.new(@age_public_key)
        ciphertext = Age.encrypt(payload, pub_key)
        encoded = Base64.strict_encode(ciphertext)
        response = post("/v1/syncer/sync", encoded, content_type: "application/octet-stream")
        return if response.status_code == 200
        raise BackendError.new("Sync failed (HTTP #{response.status_code}): #{response.body}")
      rescue ex : BackendError
        raise ex
      rescue ex : Age::Error
        raise BackendError.new("Failed to encrypt sync payload: #{ex.message}")
      end

      private def post(path : String, body : String, content_type : String = "application/json") : HTTP::Client::Response
        uri = URI.parse("#{@base_url}#{path}")
        client = build_client(uri)
        begin
          client.post(
            path,
            headers: auth_headers(content_type),
            body: body,
          )
        rescue ex : Socket::ConnectError | IO::TimeoutError
          raise BackendError.new("Could not connect to Dirless backend at #{@base_url}: #{ex.message}")
        ensure
          client.close
        end
      end

      private def auth_headers(content_type : String) : HTTP::Headers
        HTTP::Headers{
          "Content-Type"  => content_type,
          "Authorization" => "Bearer #{@hmac_secret}",
          "X-Tenant-ID"   => @tenant_id,
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
