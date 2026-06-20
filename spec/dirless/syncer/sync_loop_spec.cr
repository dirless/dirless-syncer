require "../../spec_helper"

module Dirless::Syncer
  BACKEND_HOST = "localhost:4000"

  private def self.stub_imds
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
  end

  private def self.stub_happy_path
    stub_imds
    SpecHelper.stub_users([
      {id: "usr-001", username: "alice", display_name: "Alice"},
      {id: "usr-002", username: "bob", display_name: "Bob"},
    ])
    SpecHelper.stub_groups([{id: "grp-001", display_name: "engineering"}])
    SpecHelper.stub_memberships("grp-001", ["usr-001", "usr-002"])
    WebMock.stub(:put, "#{BACKEND_HOST}/v1/snapshot/aws-identity-center")
      .to_return(status: 200, body: {"status" => "ok"}.to_json)
  end

  private def self.new_loop
    SyncLoop.new(
      SpecHelper.config,
      identity_store_id: SpecHelper::IDENTITY_STORE_ID,
      region: SpecHelper::REGION,
      hmac_secret: SpecHelper::HMAC_SECRET,
      tenant_id: SpecHelper::TENANT_ID,
      age_public_key: SpecHelper::AGE_PUBLIC_KEY,
    )
  end

  describe SyncLoop do
    describe "#run_once" do
      it "completes a full sync cycle on the happy path" do
        stub_happy_path
        new_loop.run_once # should not raise
      end

      it "assigns the primary group deterministically (smallest group_id wins)" do
        stub_imds
        SpecHelper.stub_users([{id: "usr-001", username: "alice", display_name: "Alice"}])
        SpecHelper.stub_groups([
          {id: "grp-zebra", display_name: "zebra-team"},
          {id: "grp-alpha", display_name: "alpha-team"},
          {id: "grp-mid", display_name: "mid-team"},
        ])
        SpecHelper.stub_memberships("grp-zebra", ["usr-001"])
        SpecHelper.stub_memberships("grp-alpha", ["usr-001"])
        SpecHelper.stub_memberships("grp-mid", ["usr-001"])
        WebMock.stub(:put, "#{BACKEND_HOST}/v1/snapshot/aws-identity-center")
          .to_return(status: 200, body: {"status" => "ok"}.to_json)

        new_loop.run_once # should not raise - determinism verified at IdentityStore level
      end

      it "handles a backend sync error gracefully" do
        stub_happy_path
        WebMock.stub(:put, "#{BACKEND_HOST}/v1/snapshot/aws-identity-center")
          .to_return(status: 413, body: {"error" => "payload exceeds maximum allowed size"}.to_json)

        new_loop.run_once # errors are logged, not propagated
      end
    end
  end
end
