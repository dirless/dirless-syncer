require "log"
require "./config"
require "./aws_credentials"
require "./identity_store"
require "./backend_client"

module Dirless
  module Syncer
    class SyncLoop
      Log = ::Log.for("dirless.syncer")

      def initialize(
        @config : Config,
        @identity_store_id : String,
        @region : String,
        @hmac_secret : String,
        @tenant_id : String,
        @age_public_key : String,
      )
        @backend = BackendClient.new(
          base_url: @config.backend_url,
          hmac_secret: @hmac_secret,
          tenant_id: @tenant_id,
          age_public_key: @age_public_key,
        )
      end

      def run : Nil
        Log.info { "Syncer started (interval=#{@config.interval_seconds}s)" }
        loop do
          run_once
          Log.info { "Sleeping #{@config.interval_seconds}s until next sync" }
          sleep @config.interval_seconds.seconds
        end
      end

      def run_once : Nil
        payload = build_payload
        Log.info { "Posting encrypted sync payload to backend" }
        @backend.sync(payload)
        Log.info { "Sync complete" }
      rescue ex : Exception
        Log.error { "Sync failed: #{ex.message}" }
      end

      private def build_payload : String
        credentials = IMDSCredentials.fetch
        client = IdentityStoreClient.new(@identity_store_id, @region, credentials)

        Log.info { "Fetching users and groups from Identity Store" }
        users = client.list_users
        groups = client.list_groups
        memberships = client.list_group_memberships(groups)

        Log.info { "Fetched #{users.size} users, #{groups.size} groups" }

        payload_groups = groups.map do |group|
          member_ids = memberships[group.group_id]? || [] of String
          {
            "name"        => group.display_name,
            "external_id" => group.group_id,
            "members"     => member_ids,
          }
        end

        user_primary_group = {} of String => String
        memberships.keys.sort!.each do |group_id|
          user_ids = memberships[group_id]
          user_ids.each do |uid|
            user_primary_group[uid] ||= group_id
          end
        end

        payload_users = users.map do |user|
          entry = {
            "username"    => user.username,
            "external_id" => user.user_id,
          } of String => String | Nil
          if primary = user_primary_group[user.user_id]?
            entry["primary_group"] = primary
          end
          entry
        end

        {"groups" => payload_groups, "users" => payload_users}.to_json
      end
    end
  end
end
