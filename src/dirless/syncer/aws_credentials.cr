require "http/client"
require "json"

module Dirless
  module Syncer
    struct AWSCredentials
      getter access_key_id : String
      getter secret_access_key : String
      getter session_token : String

      def initialize(@access_key_id, @secret_access_key, @session_token)
      end
    end

    module IMDSCredentials
      IMDS_BASE  = "http://169.254.169.254"
      IMDS_TOKEN = "#{IMDS_BASE}/latest/api/token"
      IMDS_CREDS = "#{IMDS_BASE}/latest/meta-data/iam/security-credentials"
      TOKEN_TTL  = "21600"

      def self.fetch : AWSCredentials
        token = fetch_token
        role = fetch_role(token)
        fetch_credentials(token, role)
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Cannot reach AWS IMDS - is this an EC2 instance? (#{ex.message})"
      end

      private def self.fetch_token : String
        response = HTTP::Client.put(
          IMDS_TOKEN,
          headers: HTTP::Headers{"X-aws-ec2-metadata-token-ttl-seconds" => TOKEN_TTL},
        )
        raise "IMDSv2 token request failed (HTTP #{response.status_code})" unless response.status_code == 200
        response.body.strip
      end

      private def self.fetch_role(token : String) : String
        response = HTTP::Client.get(
          IMDS_CREDS,
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS credentials request failed (HTTP #{response.status_code})" unless response.status_code == 200
        response.body.strip.lines.first? || raise "No IAM role attached to this instance"
      end

      private def self.fetch_credentials(token : String, role : String) : AWSCredentials
        response = HTTP::Client.get(
          "#{IMDS_CREDS}/#{role}",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS credentials fetch failed (HTTP #{response.status_code})" unless response.status_code == 200
        parsed = JSON.parse(response.body)
        AWSCredentials.new(
          access_key_id: (parsed["AccessKeyId"]?.try(&.as_s) || raise "IMDS response missing AccessKeyId"),
          secret_access_key: (parsed["SecretAccessKey"]?.try(&.as_s) || raise "IMDS response missing SecretAccessKey"),
          session_token: (parsed["Token"]?.try(&.as_s) || raise "IMDS response missing Token"),
        )
      end
    end
  end
end
