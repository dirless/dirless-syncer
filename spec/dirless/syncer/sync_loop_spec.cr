require "../../spec_helper"

module Dirless::Syncer
  BACKEND_HOST = "localhost:4000"

  private def self.stub_happy_path
    # IMDS
    WebMock.stub(:put, "169.254.169.254/latest/api/token")
      .to_return(status: 200, body: "fake-imds-token")
    WebMock.stub(:get, "169.254.169.254/latest/meta-data/iam/security-credentials")
      .to_return(status: 200, body: "my-instance-role")
    WebMock.stub(:get, "169.254.169.254/latest/meta-data/iam/security-credentials/my-instance-role")
      .to_return(status: 200, body: {
        "AccessKeyId"     => "AKIAIOSFODNN7EXAMPLE",
        "SecretAccessKey" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "Token"           => "AQoXnyc4lcK4w",
      }.to_json)

    # Identity Store
    SpecHelper.stub_users([
      {id: "usr-001", username: "alice", display_name: "Alice"},
      {id: "usr-002", username: "bob", display_name: "Bob"},
    ])
    SpecHelper.stub_groups([
      {id: "grp-001", display_name: "engineering"},
    ])
    SpecHelper.stub_memberships("grp-001", ["usr-001", "usr-002"])

    # Backend
    WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/lease/acquire")
      .to_return(status: 200, body: {
        "status"     => "acquired",
        "syncer_id"  => SpecHelper::SYNCER_ID,
        "expires_at" => "2099-01-01T00:00:00Z",
      }.to_json)
    WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/sync")
      .to_return(status: 200, body: {"status" => "ok"}.to_json)
  end

  describe SyncLoop do
    describe "#run_once" do
      it "completes a full sync cycle on the happy path" do
        stub_happy_path
        SyncLoop.new(SpecHelper.config).run_once  # should not raise
      end

      it "sends provider IDs (not usernames) in the members array" do
        # Set up all stubs except sync so we can capture the sync body ourselves.
        WebMock.stub(:put, "169.254.169.254/latest/api/token")
          .to_return(status: 200, body: "fake-imds-token")
        WebMock.stub(:get, "169.254.169.254/latest/meta-data/iam/security-credentials")
          .to_return(status: 200, body: "my-instance-role")
        WebMock.stub(:get, "169.254.169.254/latest/meta-data/iam/security-credentials/my-instance-role")
          .to_return(status: 200, body: {
            "AccessKeyId"     => "AKIAIOSFODNN7EXAMPLE",
            "SecretAccessKey" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "Token"           => "AQoXnyc4lcK4w",
          }.to_json)
        SpecHelper.stub_users([
          {id: "usr-001", username: "alice", display_name: "Alice"},
          {id: "usr-002", username: "bob", display_name: "Bob"},
        ])
        SpecHelper.stub_groups([{id: "grp-001", display_name: "engineering"}])
        SpecHelper.stub_memberships("grp-001", ["usr-001", "usr-002"])
        WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/lease/acquire")
          .to_return(status: 200, body: {
            "status"     => "acquired",
            "syncer_id"  => SpecHelper::SYNCER_ID,
            "expires_at" => "2099-01-01T00:00:00Z",
          }.to_json)

        captured_body = ""
        WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/sync")
          .to_return do |request|
            captured_body = WebMock.body(request) || ""
            HTTP::Client::Response.new(200, body: {"status" => "ok"}.to_json)
          end

        SyncLoop.new(SpecHelper.config).run_once

        parsed = JSON.parse(captured_body)
        engineering = parsed["groups"].as_a.find { |g| g["name"].as_s == "engineering" }.not_nil!
        members = engineering["members"].as_a.map(&.as_s)

        # Must contain provider IDs, not usernames
        members.should contain("usr-001")
        members.should contain("usr-002")
        members.should_not contain("alice")
        members.should_not contain("bob")
      end

      it "skips the sync cycle gracefully when the lease is held by another syncer" do
        WebMock.stub(:put, "169.254.169.254/latest/api/token")
          .to_return(status: 200, body: "fake-imds-token")
        WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/lease/acquire")
          .to_return(status: 409, body: {
            "error"      => "lease held by another syncer",
            "expires_at" => "2099-01-01T00:00:00Z",
          }.to_json)

        SyncLoop.new(SpecHelper.config).run_once  # should not raise
      end

      it "handles a backend sync error gracefully" do
        stub_happy_path
        WebMock.stub(:post, "#{BACKEND_HOST}/v1/syncer/sync")
          .to_return(status: 413, body: {"error" => "payload exceeds maximum allowed size"}.to_json)

        SyncLoop.new(SpecHelper.config).run_once  # should not raise — errors are logged, not propagated
      end
    end
  end
end
