require "http/client"
require "json"
require "uri"
require "./aws_credentials"
require "./aws_signer"

module Dirless
  module Syncer
    module AWSDetector
      IMDS_BASE      = "http://169.254.169.254"
      IMDS_TOKEN_TTL = "21600"

      # Fetches the region from the EC2 instance identity document via IMDSv2.
      def self.detect_region : String
        token = fetch_imds_token
        doc = HTTP::Client.get(
          "#{IMDS_BASE}/latest/dynamic/instance-identity/document",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS identity document request failed (HTTP #{doc.status_code})" unless doc.status_code == 200
        JSON.parse(doc.body)["region"]?.try(&.as_s) ||
          raise "region not found in IMDS identity document"
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Cannot reach AWS IMDS — is this running on an EC2 instance? (#{ex.message})"
      end

      # Returns the AWS account ID for the running EC2 instance via IMDSv2.
      def self.detect_account_id : String
        token = fetch_imds_token
        doc = HTTP::Client.get(
          "#{IMDS_BASE}/latest/dynamic/instance-identity/document",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS identity document request failed (HTTP #{doc.status_code})" unless doc.status_code == 200
        JSON.parse(doc.body)["accountId"]?.try(&.as_s) ||
          raise "accountId not found in IMDS identity document"
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Cannot reach AWS IMDS — is this running on an EC2 instance? (#{ex.message})"
      end

      # Returns the EC2 instance ID (e.g. "i-1234567890abcdef0") as the syncer ID.
      def self.detect_syncer_id : String
        token = fetch_imds_token
        response = HTTP::Client.get(
          "#{IMDS_BASE}/latest/meta-data/instance-id",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token" => token},
        )
        raise "IMDS instance-id request failed (HTTP #{response.status_code})" unless response.status_code == 200
        response.body.strip
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Cannot reach AWS IMDS — is this running on an EC2 instance? (#{ex.message})"
      end

      # Calls the SSO Admin ListInstances API to find the Identity Center instance
      # for this AWS account. Requires the sso:ListInstances IAM permission.
      # Raises if no instance is found or more than one is found (ambiguous).
      def self.detect_identity_store_id(region : String, credentials : AWSCredentials) : String
        uri = URI.parse("https://sso.#{region}.amazonaws.com/instances")
        base_headers = HTTP::Headers{"Content-Type" => "application/json"}
        headers = AWSSigner.sign("GET", uri, "sso", region, credentials, base_headers)

        client = HTTP::Client.new(uri, tls: true)
        client.connect_timeout = 10.seconds
        client.read_timeout = 15.seconds
        begin
          response = client.get(uri.request_target, headers: headers)
        ensure
          client.close rescue nil
        end

        raise "SSO Admin ListInstances failed (HTTP #{response.status_code}): #{response.body}" unless response.status_code == 200

        instances = JSON.parse(response.body)["Instances"]?.try(&.as_a) || [] of JSON::Any
        case instances.size
        when 0
          raise "No IAM Identity Center instance found in this AWS account. " \
                "Have you enabled IAM Identity Center?"
        when 1
          instances[0]["IdentityStoreId"]?.try(&.as_s) ||
            raise "IdentityStoreId missing from SSO Admin ListInstances response"
        else
          raise "Multiple IAM Identity Center instances found — set identity_store_id " \
                "explicitly in config to specify which one to use"
        end
      rescue ex : Socket::ConnectError | IO::TimeoutError
        raise "Could not reach SSO Admin API: #{ex.message}"
      end

      private def self.fetch_imds_token : String
        response = HTTP::Client.put(
          "#{IMDS_BASE}/latest/api/token",
          headers: HTTP::Headers{"X-aws-ec2-metadata-token-ttl-seconds" => IMDS_TOKEN_TTL},
        )
        raise "IMDSv2 token request failed (HTTP #{response.status_code})" unless response.status_code == 200
        response.body.strip
      end
    end
  end
end
