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
        WebMock.stub(:get, "#{SpecHelper::IS_BASE}/identitystores/#{is_id}/users")
          .to_return(status: 200, body: {"Users" => [] of String}.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        client.list_users.should be_empty
      end

      it "follows pagination via nextToken" do
        WebMock.stub(:get, "#{SpecHelper::IS_BASE}/identitystores/#{is_id}/users")
          .to_return(status: 200, body: {
            "Users"     => [{"UserId" => "usr-001", "UserName" => "alice", "DisplayName" => "Alice"}],
            "nextToken" => "page2token",
          }.to_json)

        WebMock.stub(:get, "#{SpecHelper::IS_BASE}/identitystores/#{is_id}/users?nextToken=page2token")
          .to_return(status: 200, body: {
            "Users" => [{"UserId" => "usr-002", "UserName" => "bob", "DisplayName" => "Bob"}],
          }.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        users = client.list_users

        users.size.should eq(2)
        users.map(&.username).should eq(["alice", "bob"])
      end

      it "raises on non-200 response" do
        WebMock.stub(:get, "#{SpecHelper::IS_BASE}/identitystores/#{is_id}/users")
          .to_return(status: 403, body: {"message" => "Access denied"}.to_json)

        client = IdentityStoreClient.new(is_id, region, creds)
        expect_raises(Exception, /Identity Store API error.*403/) do
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
