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
    #
    # Lease acquisition and heartbeats are single-node operations (they talk to
    # @base_url directly). Sync payloads are pushed to every backend node via
    # #sync_all so that all nodes stay current without relying on primary-push
    # database replication as the sole delivery mechanism.
    class BackendClient
      # HTTP::Client subclass that connects to a specific IP while using the
      # original hostname for TLS SNI and certificate verification — identical
      # to the pattern used in dirless-agent's BackendClient.
      private class TargetedClient < HTTP::Client
        def initialize(@target_ip : String, sni_host : String, port : Int32, tls : OpenSSL::SSL::Context::Client)
          super(sni_host, port, tls: tls)
        end

        private def connect : IO
          socket = TCPSocket.new(@target_ip, @port, connect_timeout: @connect_timeout)
          socket.read_timeout = @read_timeout if @read_timeout
          socket.write_timeout = @write_timeout if @write_timeout
          OpenSSL::SSL::Socket::Client.new(
            socket,
            context: @tls.as(OpenSSL::SSL::Context::Client),
            sync_close: true,
            hostname: @host,
          )
        end
      end

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

      # Pushes *payload* to every IP in *backend_ips*, contacting each node
      # directly (using TargetedClient for HTTPS so SNI/cert validation still
      # works against the shared FQDN). Logs a warning for each failed node but
      # only raises BackendError if every node fails — a partial success (at
      # least one node accepted the payload) is treated as ok because the
      # primary-push DB replication will propagate the data to lagging nodes.
      def sync_all(payload : String, backend_ips : Array(String)) : Nil
        uri = URI.parse(@base_url)
        sni_host = uri.host.not_nil!
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        scheme = uri.scheme

        errors = [] of String
        backend_ips.each do |ip|
          begin
            client = build_client_for(ip, sni_host, port, scheme)
            begin
              response = client.post(
                "/v1/syncer/sync",
                headers: HTTP::Headers{"Content-Type" => "application/json"},
                body: payload,
              )
            ensure
              client.close rescue nil
            end
            if response.status_code == 200
              Log.info { "Sync to #{ip} succeeded" }
            else
              raise BackendError.new("Sync to #{ip} failed (HTTP #{response.status_code}): #{response.body}")
            end
          rescue ex : BackendError
            Log.warn { ex.message }
            errors << ex.message.to_s
          rescue ex
            msg = "Could not connect to #{ip}: #{ex.message}"
            Log.warn { msg }
            errors << msg
          end
        end

        if errors.size == backend_ips.size
          raise BackendError.new("All #{backend_ips.size} backend node(s) failed to sync: #{errors.join("; ")}")
        end
      end

      private def post(path : String, body : String) : HTTP::Client::Response
        uri = URI.parse("#{@base_url}#{path}")
        client = build_client(uri)
        begin
          client.post(
            path,
            headers: HTTP::Headers{"Content-Type" => "application/json"},
            body: body,
          )
        rescue ex : Socket::ConnectError | IO::TimeoutError
          raise BackendError.new("Could not connect to Dirless backend at #{@base_url}: #{ex.message}")
        ensure
          client.close
        end
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

      private def build_client_for(ip : String, sni_host : String, port : Int32, scheme : String?) : HTTP::Client
        if scheme == "https"
          tls = OpenSSL::SSL::Context::Client.new
          tls.certificate_chain = @cert_path
          tls.private_key = @key_path
          tls.ca_certificates = @ca_path
          TargetedClient.new(ip, sni_host, port, tls)
        else
          HTTP::Client.new(ip, port)
        end
      end

      private Log = ::Log.for("dirless.syncer.client")
    end
  end
end
