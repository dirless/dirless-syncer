require "../../spec_helper"

module Dirless::Syncer
  describe IdentityStoreClient do
    creds  = SpecHelper::FAKE_CREDENTIALS
    is_id  = SpecHelper::IDENTITY_STORE_ID
    region = SpecHelper::REGION

    describe "#list_users" do
      it "returns users from Identity Store" do
        SpecHelper.stub_users([
          {id: "usr-001", username: "alice", display_name: "Alice Example"},
          {id: "usr-002", username: "bob", display_name: "Bob Example"},
        ])

        client = IdentityStoreClient.new(is_id, region, creds)
        users = client.list_users

        users.size.should eq(2)
        users[0].user_id.should eq("usr-001")
        users[0].username.should eq("alice")
        users[1].username.should eq("bob")
      end

      it "returns empty array when no users exist" do
        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return(status: 200, body: {"Users" => [] of String}.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        client.list_users.should be_empty
      end

      it "follows pagination via NextToken" do
        page1_body = {"IdentityStoreId" => is_id}.to_json
        page2_body = {"IdentityStoreId" => is_id, "NextToken" => "page2token"}.to_json

        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"}, body: page1_body)
          .to_return(status: 200, body: {
            "Users"     => [{"UserId" => "usr-001", "UserName" => "alice", "DisplayName" => "Alice"}],
            "NextToken" => "page2token",
          }.to_json)

        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"}, body: page2_body)
          .to_return(status: 200, body: {
            "Users" => [{"UserId" => "usr-002", "UserName" => "bob", "DisplayName" => "Bob"}],
          }.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        users = client.list_users

        users.size.should eq(2)
        users.map(&.username).should eq(["alice", "bob"])
      end

      it "raises on non-200 response" do
        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return(status: 403, body: {"message" => "Access denied"}.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        expect_raises(Exception, /Identity Store API error.*403/) do
          client.list_users
        end
      end

      it "propagates HTTP client errors as exceptions (M1 — timeout/connection errors bubble up)" do
        # WebMock raises an error for unstubbed requests, simulating a
        # connection or network failure. The IdentityStoreClient must not
        # swallow the error — it should propagate so the caller can handle it.
        expect_raises(Exception) do
          IdentityStoreClient.new(is_id, region, creds).list_users
        end
      end

      it "does not leak HTTP clients on connection errors (ensure closes client)" do
        # Unstubbed request raises — the ensure block must close the client.
        # If the client leaks, this would eventually exhaust file descriptors.
        # We verify the exception propagates cleanly (ensure doesn't mask it).
        5.times do
          expect_raises(Exception) do
            IdentityStoreClient.new(is_id, region, creds).list_users
          end
        end
      end

      it "retries on 429 and succeeds when the next attempt returns 200" do
        call_count = 0
        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return do |_|
            call_count += 1
            if call_count == 1
              HTTP::Client::Response.new(status_code: 429, body: "throttled")
            else
              HTTP::Client::Response.new(status_code: 200, body: {"Users" => [{"UserId" => "usr-001", "UserName" => "alice", "DisplayName" => "Alice"}]}.to_json)
            end
          end

        client = IdentityStoreClient.new(is_id, region, creds)
        users = client.list_users
        users.size.should eq(1)
        users[0].username.should eq("alice")
        call_count.should be >= 2
      end

      it "retries on 500 and succeeds when the next attempt returns 200" do
        call_count = 0
        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return do |_|
            call_count += 1
            if call_count == 1
              HTTP::Client::Response.new(status_code: 500, body: "internal error")
            else
              HTTP::Client::Response.new(status_code: 200, body: {"Users" => [{"UserId" => "usr-001", "UserName" => "alice", "DisplayName" => "Alice"}]}.to_json)
            end
          end

        client = IdentityStoreClient.new(is_id, region, creds)
        users = client.list_users
        users.size.should eq(1)
        call_count.should be >= 2
      end

      it "raises after max retries on persistent 500 errors" do
        WebMock.stub(:post, SpecHelper::IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return(status: 500, body: "internal error")

        client = IdentityStoreClient.new(is_id, region, creds)
        expect_raises(Exception, /after 3 retries/) do
          client.list_users
        end
      end
    end

    describe "#list_groups" do
      it "returns groups from Identity Store" do
        SpecHelper.stub_groups([
          {id: "grp-001", display_name: "engineering"},
          {id: "grp-002", display_name: "ops"},
        ])

        client = IdentityStoreClient.new(is_id, region, creds)
        groups = client.list_groups

        groups.size.should eq(2)
        groups[0].group_id.should eq("grp-001")
        groups[0].display_name.should eq("engineering")
      end
    end

    describe "#list_group_memberships" do
      it "returns a map of group_id to user_ids" do
        SpecHelper.stub_memberships("grp-001", ["usr-001", "usr-002"])
        SpecHelper.stub_memberships("grp-002", ["usr-001"])

        groups = [
          ISGroup.new(group_id: "grp-001", display_name: "engineering"),
          ISGroup.new(group_id: "grp-002", display_name: "ops"),
        ]

        client = IdentityStoreClient.new(is_id, region, creds)
        memberships = client.list_group_memberships(groups)

        memberships["grp-001"].should eq(["usr-001", "usr-002"])
        memberships["grp-002"].should eq(["usr-001"])
      end

      it "returns empty array for a group with no members" do
        SpecHelper.stub_memberships("grp-001", [] of String)

        groups = [ISGroup.new(group_id: "grp-001", display_name: "empty-group")]
        client = IdentityStoreClient.new(is_id, region, creds)
        memberships = client.list_group_memberships(groups)

        memberships["grp-001"].should be_empty
      end
    end
  end
end
