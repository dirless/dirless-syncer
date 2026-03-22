require "../../spec_helper"

module Dirless::Syncer
  IMDS_TOKEN_URL = "http://169.254.169.254/latest/api/token"
  IMDS_CREDS_URL = "http://169.254.169.254/latest/meta-data/iam/security-credentials"
  IMDS_ROLE_NAME = "dirless-test-role"

  private def self.stub_imds_token
    WebMock.stub(:put, IMDS_TOKEN_URL)
      .to_return(status: 200, body: "test-imds-token")
  end

  private def self.stub_imds_role
    WebMock.stub(:get, IMDS_CREDS_URL)
      .to_return(status: 200, body: IMDS_ROLE_NAME)
  end

  private def self.stub_imds_credentials(body : String)
    WebMock.stub(:get, "#{IMDS_CREDS_URL}/#{IMDS_ROLE_NAME}")
      .to_return(status: 200, body: body)
  end

  describe IMDSCredentials do
    describe ".fetch" do
      it "returns credentials when IMDS returns valid JSON" do
        stub_imds_token
        stub_imds_role
        stub_imds_credentials({
          "AccessKeyId"     => "AKIAIOSFODNN7EXAMPLE",
          "SecretAccessKey" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          "Token"           => "AQoXnyc4lcK4w",
        }.to_json)

        creds = IMDSCredentials.fetch
        creds.access_key_id.should eq("AKIAIOSFODNN7EXAMPLE")
        creds.secret_access_key.should eq("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        creds.session_token.should eq("AQoXnyc4lcK4w")
      end

      it "raises with a clear message when AccessKeyId is missing from IMDS response" do
        stub_imds_token
        stub_imds_role
        stub_imds_credentials({
          "SecretAccessKey" => "secret",
          "Token"           => "token",
        }.to_json)

        expect_raises(Exception, /IMDS response missing AccessKeyId/) do
          IMDSCredentials.fetch
        end
      end

      it "raises with a clear message when SecretAccessKey is missing from IMDS response" do
        stub_imds_token
        stub_imds_role
        stub_imds_credentials({
          "AccessKeyId" => "AKIAIOSFODNN7EXAMPLE",
          "Token"       => "token",
        }.to_json)

        expect_raises(Exception, /IMDS response missing SecretAccessKey/) do
          IMDSCredentials.fetch
        end
      end

      it "raises with a clear message when Token is missing from IMDS response" do
        stub_imds_token
        stub_imds_role
        stub_imds_credentials({
          "AccessKeyId"     => "AKIAIOSFODNN7EXAMPLE",
          "SecretAccessKey" => "secret",
        }.to_json)

        expect_raises(Exception, /IMDS response missing Token/) do
          IMDSCredentials.fetch
        end
      end
    end
  end
end
