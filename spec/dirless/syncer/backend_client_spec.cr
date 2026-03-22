require "../../spec_helper"

module Dirless::Syncer
  private def self.test_client
    BackendClient.new(
      base_url: SpecHelper::BACKEND_URL,
      cert_path: "/tmp/dirless-spec-test_client.crt",
      key_path: "/tmp/dirless-spec-test_client.key",
      ca_path: "/tmp/dirless-spec-ca.crt",
    )
  end

  describe BackendClient do
    backend_host = "localhost:4000"

    describe "#acquire_lease" do
      it "returns expires_at on success" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/lease/acquire")
          .to_return(status: 200, body: {
            "status"     => "acquired",
            "syncer_id"  => SpecHelper::SYNCER_ID,
            "expires_at" => "2026-03-06T16:35:30Z",
          }.to_json)

        expires_at = test_client.acquire_lease(SpecHelper::SYNCER_ID)
        expires_at.should eq("2026-03-06T16:35:30Z")
      end

      it "raises LeaseConflictError when lease is held by another syncer" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/lease/acquire")
          .to_return(status: 409, body: {
            "error"      => "lease held by another syncer",
            "expires_at" => "2026-03-06T16:35:30Z",
          }.to_json)

        expect_raises(LeaseConflictError) do
          test_client.acquire_lease(SpecHelper::SYNCER_ID)
        end
      end

      it "raises BackendError on unexpected status" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/lease/acquire")
          .to_return(status: 500, body: "Internal Server Error")

        expect_raises(BackendError, /Unexpected response.*500/) do
          test_client.acquire_lease(SpecHelper::SYNCER_ID)
        end
      end
    end

    describe "#heartbeat" do
      it "succeeds on 200" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/lease/heartbeat")
          .to_return(status: 200, body: {
            "status"     => "renewed",
            "syncer_id"  => SpecHelper::SYNCER_ID,
            "expires_at" => "2026-03-06T16:35:30Z",
          }.to_json)

        test_client.heartbeat(SpecHelper::SYNCER_ID) # should not raise
      end

      it "raises BackendError when heartbeat fails" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/lease/heartbeat")
          .to_return(status: 409, body: {"error" => "lease expired or held by another syncer"}.to_json)

        expect_raises(BackendError, /Heartbeat failed.*409/) do
          test_client.heartbeat(SpecHelper::SYNCER_ID)
        end
      end
    end

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
      it "does not leak HTTP clients on repeated connection errors" do
        # Stub with 500 to trigger BackendError (WebMock intercepts before real connect).
        WebMock.stub(:post, "#{SpecHelper::BACKEND_URL}/v1/syncer/sync")
          .to_return(status: 500, body: "error")

        5.times do
          expect_raises(BackendError) do
            test_client.sync("payload")
          end
        end
      end
    end

    describe "#sync_all" do
      payload = {"groups" => [] of String, "users" => [] of String}.to_json

      it "posts to all provided IPs and succeeds when all return 200" do
        WebMock.stub(:post, "http://node1:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)
        WebMock.stub(:post, "http://node2:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)
        WebMock.stub(:post, "http://node3:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)

        test_client.sync_all(payload, ["node1", "node2", "node3"]) # should not raise
      end

      it "succeeds when one node is down — simulates primary going offline" do
        WebMock.stub(:post, "http://node1:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)
        # node2 is not stubbed — WebMock raises a connection error for it.
        WebMock.stub(:post, "http://node3:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)

        # 2 out of 3 nodes succeeded — must not raise.
        test_client.sync_all(payload, ["node1", "node2", "node3"])
      end

      it "succeeds when two nodes are down — simulates majority failure with one survivor" do
        WebMock.stub(:post, "http://node1:4000/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)
        # node2 and node3 are not stubbed — both raise connection errors.

        # 1 out of 3 nodes succeeded — still ok.
        test_client.sync_all(payload, ["node1", "node2", "node3"])
      end

      it "raises BackendError when all nodes fail" do
        # No nodes stubbed — all raise WebMock connection errors.
        expect_raises(BackendError, /All.*backend node/) do
          test_client.sync_all(payload, ["bad1", "bad2", "bad3"])
        end
      end

      it "raises BackendError when a node returns a non-200 response and it is the only node" do
        WebMock.stub(:post, "http://bad-status:4000/v1/syncer/sync")
          .to_return(status: 413, body: {"error" => "payload too large"}.to_json)

        expect_raises(BackendError, /All.*backend node/) do
          test_client.sync_all(payload, ["bad-status"])
        end
      end

      it "succeeds when only a single healthy node is provided" do
        WebMock.stub(:post, "#{backend_host}/v1/syncer/sync")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)

        test_client.sync_all(payload, ["localhost"])
      end
    end
  end
end
