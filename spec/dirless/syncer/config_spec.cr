require "../../spec_helper"

module Dirless::Syncer
  describe Config do
    describe ".load" do
      it "loads a valid config without raising" do
        config = SpecHelper.config
        config.backend_url.should eq(SpecHelper::BACKEND_URL)
        config.identity_store_id.should eq(SpecHelper::IDENTITY_STORE_ID)
      end

      it "raises when backend_url is empty" do
        path = write_config(backend_url: "")
        expect_raises(Exception, /backend_url must not be empty/) do
          Config.load(path)
        end
      end

      it "raises when backend_url has invalid scheme" do
        path = write_config(backend_url: "ftp://example.com")
        expect_raises(Exception, /backend_url must start with http:\/\/ or https:\/\//) do
          Config.load(path)
        end
      end

      it "loads without identity_center section (auto-detect)" do
        path = File.tempname("dirless-syncer-config-spec", ".toml")
        File.write(path, <<-TOML)
          [backend]
          url = "http://localhost:4000"

          [syncer]
          id = "syncer-01"
          interval_seconds = 300
          heartbeat_interval_seconds = 10

          [tls]
          cert_path = "/tmp/cert.crt"
          key_path  = "/tmp/cert.key"
          ca_path   = "/tmp/ca.crt"
          TOML
        config = Config.load(path)
        config.identity_store_id.should be_nil
        config.region.should be_nil
      end

      it "raises when interval_seconds is zero" do
        path = write_config(interval_seconds: 0)
        expect_raises(Exception, /interval_seconds must be positive/) do
          Config.load(path)
        end
      end

      it "raises when interval_seconds is negative" do
        path = write_config(interval_seconds: -5)
        expect_raises(Exception, /interval_seconds must be positive/) do
          Config.load(path)
        end
      end

      it "raises when cert_path is empty for HTTPS backend" do
        path = write_config(backend_url: "https://backend.example.com", cert_path: "")
        expect_raises(Exception, /cert_path must not be empty for HTTPS/) do
          Config.load(path)
        end
      end

      it "raises when key_path is empty for HTTPS backend" do
        path = write_config(backend_url: "https://backend.example.com", key_path: "")
        expect_raises(Exception, /key_path must not be empty for HTTPS/) do
          Config.load(path)
        end
      end

      it "raises when ca_path is empty for HTTPS backend" do
        path = write_config(backend_url: "https://backend.example.com", ca_path: "")
        expect_raises(Exception, /ca_path must not be empty for HTTPS/) do
          Config.load(path)
        end
      end

      it "allows empty TLS paths for HTTP backend" do
        path = write_config(backend_url: "http://localhost:4000", cert_path: "", key_path: "", ca_path: "")
        config = Config.load(path)
        config.backend_url.should eq("http://localhost:4000")
      end
    end
  end

  private def self.write_config(
    backend_url : String = "http://localhost:4000",
    identity_store_id : String = "d-1234567890",
    region : String = "us-east-1",
    syncer_id : String = "syncer-test-001",
    interval_seconds : Int32 = 300,
    heartbeat_interval_seconds : Int32 = 10,
    cert_path : String = "/tmp/cert.crt",
    key_path : String = "/tmp/cert.key",
    ca_path : String = "/tmp/ca.crt",
  ) : String
    path = File.tempname("dirless-syncer-config-spec", ".toml")
    File.write(path, <<-TOML)
      [backend]
      url = "#{backend_url}"

      [identity_center]
      identity_store_id = "#{identity_store_id}"
      region = "#{region}"

      [syncer]
      id = "#{syncer_id}"
      interval_seconds = #{interval_seconds}
      heartbeat_interval_seconds = #{heartbeat_interval_seconds}

      [tls]
      cert_path = "#{cert_path}"
      key_path  = "#{key_path}"
      ca_path   = "#{ca_path}"
      TOML
    path
  end
end
