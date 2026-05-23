require "../../spec_helper"

module Dirless::Syncer
  private def self.test_client
    BackendClient.new(
      base_url: SpecHelper::BACKEND_URL,
      hmac_secret: SpecHelper::HMAC_SECRET,
      tenant_id: SpecHelper::TENANT_ID,
      age_public_key: SpecHelper::AGE_PUBLIC_KEY,
    )
  end

  describe BackendClient do
    backend_host = "localhost:4000"

    describe "#sync" do
      it "succeeds on 200" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)

        payload = {"groups" => [] of String, "users" => [] of String}.to_json
        test_client.sync(payload) # should not raise
      end

      it "raises BackendError on non-200" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/sync")
          .to_return(status: 413, body: {"error" => "payload exceeds maximum allowed size"}.to_json)

        expect_raises(BackendError, /Sync failed.*413/) do
          test_client.sync("big payload")
        end
      end
    end

    describe "client resource cleanup" do
      it "does not leak HTTP clients on repeated errors" do
        WebMock.stub(:post, "#{SpecHelper::BACKEND_URL}/v1/syncer/sync")
          .to_return(status: 500, body: "error")

        5.times do
          expect_raises(BackendError) do
            test_client.sync("payload")
          end
        end
      end
    end
  end
end
