require "http/client"
require "json"
require "openssl/hmac"
require "random/secure"
require "file_utils"
require "age-crystal"
require "x509-crystal"
require "./config"

module Dirless
  module Syncer
    module Enroller
      CERT_DIR        = "/etc/dirless"
      HMAC_KEY_PATH   = "/etc/dirless/hmac.key"
      CERT_VALID_DAYS = 3650
      IMDS_BASE       = "http://169.254.169.254"
      IMDS_TOKEN_TTL  = "21600"

      def self.enrolled?(config : Config) : Bool
        File.exists?(config.cert_path) &&
          File.exists?(config.key_path) &&
          File.exists?(config.ca_path)
      end

      def self.enroll(config : Config, token : String) : Nil
        Log.info { "No mTLS certs found — starting self-enrollment" }

        tenant_id = derive_tenant_id
        Log.info { "Tenant ID: #{tenant_id}" }

        Log.info { "Generating age keypair..." }
        age_keypair = Age.keygen

        Log.info { "Generating X.509 certificate bundle..." }
        bundle = X509.generate(common_name: tenant_id, days: CERT_VALID_DAYS)

        FileUtils.mkdir_p(CERT_DIR)
        File.chmod(CERT_DIR, 0o700)
        write_file(config.ca_path, bundle.ca_cert)
        write_file(config.cert_path, bundle.client_cert)
        write_file(config.key_path, bundle.client_key)
        write_file("/etc/dirless/age.key", age_keypair.secret_key.value)

        Log.info { "Registering with #{config.backend_url}..." }
        post_enrollment(config.backend_url, token, tenant_id, age_keypair.public_key.value, bundle.ca_cert)

        Log.info { "Enrollment complete" }
      end

      private def self.derive_tenant_id : String
        hmac_secret = load_or_generate_hmac_key
        account_id = fetch_aws_account_id
        hashed = OpenSSL::HMAC.hexdigest(:sha256, hmac_secret, account_id)
        "aws___#{hashed}"
      end

      private def self.load_or_generate_hmac_key : String
        if File.exists?(HMAC_KEY_PATH)
          File.read(HMAC_KEY_PATH).strip
        else
          secret = Random::Secure.hex(32)
          write_file(HMAC_KEY_PATH, secret)
          secret
        end
      end

      private def self.fetch_aws_account_id : String
        imds_token = HTTP::Client.put(
          "#{IMDS_BASE}/latest/api/token",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token-ttl-seconds" => IMDS_TOKEN_TTL},
        )
        raise "IMDSv2 token request failed (HTTP #{imds_token.status_code})" unless imds_token.status_code == 200
        token = imds_token.body.strip

        identity = HTTP::Client.get(
          "#{IMDS_BASE}/latest/dynamic/instance-identity/document",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS identity document request failed (HTTP #{identity.status_code})" unless identity.status_code == 200

        parsed = JSON.parse(identity.body)
        parsed["accountId"]?.try(&.as_s) || raise "accountId not found in IMDS identity document"
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Cannot reach AWS IMDS — is this running on an EC2 instance? (#{ex.message})"
      end

      private def self.post_enrollment(
        server : String,
        token : String,
        tenant_id : String,
        age_public_key : String,
        ca_cert : String,
      ) : Nil
        uri = URI.parse("#{server.rstrip("/")}/v1/enrollment/enroll")
        body = {tenant_id: tenant_id, age_public_key: age_public_key, ca_cert: ca_cert}.to_json

        client = HTTP::Client.new(uri)
        client.connect_timeout = 10.seconds
        client.read_timeout = 30.seconds
        response = client.post(
          uri.request_target,
          headers: HTTP::Headers{
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{token}",
          },
          body: body,
        )

        case response.status_code
        when 200
          # enrolled
        when 401
          raise "Enrollment failed: invalid token — check enrollment_token in config"
        when 403
          parsed = JSON.parse(response.body)
          raise "Enrollment failed: #{parsed["error"]?}"
        else
          raise "Enrollment failed (HTTP #{response.status_code}): #{response.body}"
        end
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Could not connect to #{server} for enrollment: #{ex.message}"
      end

      private def self.write_file(path : String, content : String) : Nil
        File.write(path, content)
        File.chmod(path, 0o600)
        Log.info { "  wrote #{path}" }
      end

      private Log = ::Log.for("dirless.syncer.enroller")
    end
  end
end
