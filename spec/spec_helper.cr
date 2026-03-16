require "spec"
require "webmock"
require "../src/dirless/syncer/config"
require "../src/dirless/syncer/aws_credentials"
require "../src/dirless/syncer/aws_signer"
require "../src/dirless/syncer/identity_store"
require "../src/dirless/syncer/backend_client"
require "../src/dirless/syncer/sync_loop"

Spec.before_each { WebMock.reset }

module Dirless
  module Syncer
    module SpecHelper
      IDENTITY_STORE_ID = "d-1234567890"
      REGION            = "us-east-1"
      SYNCER_ID         = "syncer-test-001"
      BACKEND_URL       = "http://localhost:4000"

      FAKE_CREDENTIALS = AWSCredentials.new(
        access_key_id:     "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        session_token:     "AQoXnyc4lcK4w",
      )

      IS_ENDPOINT = "https://identitystore.us-east-1.amazonaws.com/"

      def self.config : Config
        config_path = File.tempname("dirless-syncer-spec", ".toml")
        File.write(config_path, <<-TOML)
          [backend]
          url = "#{BACKEND_URL}"

          [identity_center]
          identity_store_id = "#{IDENTITY_STORE_ID}"
          region = "#{REGION}"

          [syncer]
          id = "#{SYNCER_ID}"
          interval_seconds = 300
          heartbeat_interval_seconds = 10

          [tls]
          cert_path = "/tmp/dirless-spec-client.crt"
          key_path  = "/tmp/dirless-spec-client.key"
          ca_path   = "/tmp/dirless-spec-ca.crt"
          TOML
        Config.load(config_path)
      end

      # The Identity Store API uses JSON 1.1 RPC: all operations POST to the
      # root endpoint, differentiated by the X-Amz-Target header.

      def self.stub_users(users : Array(NamedTuple(id: String, username: String, display_name: String)))
        items = users.map do |u|
          {"UserId" => u[:id], "UserName" => u[:username], "DisplayName" => u[:display_name]}
        end
        WebMock.stub(:post, IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListUsers"})
          .to_return(status: 200, body: {"Users" => items}.to_json)
      end

      def self.stub_groups(groups : Array(NamedTuple(id: String, display_name: String)))
        items = groups.map { |g| {"GroupId" => g[:id], "DisplayName" => g[:display_name]} }
        WebMock.stub(:post, IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListGroups"})
          .to_return(status: 200, body: {"Groups" => items}.to_json)
      end

      def self.stub_memberships(group_id : String, user_ids : Array(String))
        items = user_ids.map { |uid| {"MembershipId" => "mem-#{uid}", "GroupId" => group_id, "MemberId" => {"UserId" => uid}} }
        expected_body = {"IdentityStoreId" => IDENTITY_STORE_ID, "GroupId" => group_id}.to_json
        WebMock.stub(:post, IS_ENDPOINT)
          .with(headers: {"X-Amz-Target" => "AWSIdentityStore.ListGroupMemberships"}, body: expected_body)
          .to_return(status: 200, body: {"GroupMemberships" => items}.to_json)
      end
    end
  end
end
