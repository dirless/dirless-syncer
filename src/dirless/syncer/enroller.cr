require "http/client"
require "json"
require "openssl/hmac"
require "random/secure"
require "file_utils"
require "age-crystal"
require "./config"

module Dirless
  module Syncer
    module Enroller
      CERT_DIR            = "/etc/dirless"
      HMAC_KEY_PATH       = "/etc/dirless/hmac.key"
      AGE_KEY_PATH        = "/etc/dirless/age.key"
      AGE_PUBLIC_KEY_PATH = "/etc/dirless/age_public.key"
      TENANT_ID_PATH      = "/etc/dirless/tenant_id"
      IMDS_BASE           = "http://169.254.169.254"
      IMDS_TOKEN_TTL      = "21600"

      def self.enrolled? : Bool
        File.exists?(AGE_KEY_PATH) &&
          File.exists?(AGE_PUBLIC_KEY_PATH) &&
          File.exists?(TENANT_ID_PATH)
      end

      def self.enroll(config : Config, token : String) : Nil
        Log.info { "Not enrolled - starting enrollment" }

        unless File.exists?(AGE_KEY_PATH)
          raise "Age private key not found at #{AGE_KEY_PATH}.\n" \
                "Generate a keypair at https://dirless.com/age-keypair.html " \
                "and place the private key at #{AGE_KEY_PATH} (chmod 600).\n" \
                "Use the same key you enrolled your hosts with."
        end

        secret_key = File.read(AGE_KEY_PATH).strip
        age_keypair = Age.keypair_from_secret(secret_key)
        Log.info { "Using existing age key: #{age_keypair.public_key.value}" }

        tenant_id = derive_tenant_id(token)
        Log.info { "Tenant ID: #{tenant_id}" }

        FileUtils.mkdir_p(CERT_DIR)
        File.chmod(CERT_DIR, 0o700)
        File.chmod(AGE_KEY_PATH, 0o600)
        write_file(AGE_PUBLIC_KEY_PATH, age_keypair.public_key.value)
        write_file(TENANT_ID_PATH, tenant_id)

        Log.info { "Registering with #{config.backend_url}..." }
        post_enrollment(config.backend_url, token, tenant_id, age_keypair.public_key.value)

        Log.info { "Enrollment complete" }
      end

      def self.read_tenant_id : String
        File.read(TENANT_ID_PATH).strip
      end

      def self.read_age_public_key : String
        File.read(AGE_PUBLIC_KEY_PATH).strip
      end

      def self.read_hmac_secret : String
        File.read(HMAC_KEY_PATH).strip
      end

      private def self.derive_tenant_id(enrollment_token : String) : String
        write_file(HMAC_KEY_PATH, enrollment_token)
        account_id = fetch_aws_account_id
        hashed = OpenSSL::HMAC.hexdigest(:sha256, enrollment_token, account_id)
        "aws___#{hashed}"
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
        raise "Cannot reach AWS IMDS - is this running on an EC2 instance? (#{ex.message})"
      end

      private def self.post_enrollment(
        server : String,
        token : String,
        tenant_id : String,
        age_public_key : String,
      ) : Nil
        uri = URI.parse("#{server.rstrip("/")}/v1/enrollment/enroll")
        body = {tenant_id: tenant_id, age_public_key: age_public_key}.to_json

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
          raise "Enrollment failed: invalid token - check enrollment_token in config"
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
