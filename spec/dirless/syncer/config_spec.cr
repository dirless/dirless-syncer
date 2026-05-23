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
          interval_seconds = 300
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
    end
  end

  private def self.write_config(
    backend_url : String = "http://localhost:4000",
    identity_store_id : String = "d-1234567890",
    region : String = "us-east-1",
    interval_seconds : Int32 = 300,
  ) : String
    path = File.tempname("dirless-syncer-config-spec", ".toml")
    File.write(path, <<-TOML)
      [backend]
      url = "#{backend_url}"

      [identity_center]
      identity_store_id = "#{identity_store_id}"
      region = "#{region}"

      [syncer]
      interval_seconds = #{interval_seconds}
      TOML
    path
  end
end
