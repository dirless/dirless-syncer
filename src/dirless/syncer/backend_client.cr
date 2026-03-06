require "http/client"
require "json"
require "openssl"
require "uri"

module Dirless
  module Syncer
    class BackendError < Exception; end

    class LeaseConflictError < BackendError
      getter expires_at : String?

      def initialize(message : String, @expires_at : String?)
        super(message)
      end
    end

    # mTLS HTTP client for talking to the Dirless backend.
    class BackendClient
      def initialize(
        @base_url : String,
        @cert_path : String,
        @key_path : String,
        @ca_path : String,
      )
      end

      def acquire_lease(syncer_id : String) : String
        body = {"syncer_id" => syncer_id}.to_json
        response = post("/v1/syncer/lease/acquire", body)
        case response.status_code
        when 200
          JSON.parse(response.body)["expires_at"].as_s
        when 409
          parsed = JSON.parse(response.body)
          raise LeaseConflictError.new(
            "Lease held by another syncer",
            parsed["expires_at"]?.try(&.as_s),
          )
        else
          raise BackendError.new("Unexpected response from lease/acquire (HTTP #{response.status_code}): #{response.body}")
        end
      end

      def heartbeat(syncer_id : String) : Nil
        body = {"syncer_id" => syncer_id}.to_json
        response = post("/v1/syncer/lease/heartbeat", body)
        return if response.status_code == 200
        raise BackendError.new("Heartbeat failed (HTTP #{response.status_code}): #{response.body}")
      end

      def sync(payload : String) : Nil
        response = post("/v1/syncer/sync", payload)
        return if response.status_code == 200
        raise BackendError.new("Sync failed (HTTP #{response.status_code}): #{response.body}")
      end

      private def post(path : String, body : String) : HTTP::Client::Response
        uri = URI.parse("#{@base_url}#{path}")
        client = build_client(uri)
        client.post(
          path,
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: body,
        )
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise BackendError.new("Could not connect to Dirless backend at #{@base_url}: #{ex.message}")
      end

      private def build_client(uri : URI) : HTTP::Client
        if uri.scheme == "https"
          tls = OpenSSL::SSL::Context::Client.new
          tls.certificate_chain = @cert_path
          tls.private_key = @key_path
          tls.ca_certificates = @ca_path
          HTTP::Client.new(uri, tls: tls)
        else
          HTTP::Client.new(uri)
        end
      end
    end
  end
end
