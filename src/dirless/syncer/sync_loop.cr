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
        aws_account_id = AWSDetector.detect_account_id
        payload, user_count, group_count = build_payload
        Log.info { "Posting encrypted sync payload to backend" }
        @backend.sync(payload, user_count, group_count, aws_account_id: aws_account_id)
        Log.info { "Sync complete" }
      rescue ex : Exception
        Log.error { "Sync failed: #{ex.message}" }
      end

      private def build_payload : {String, Int32, Int32}
        credentials = IMDSCredentials.fetch
        client = IdentityStoreClient.new(@identity_store_id, @region, credentials)

        Log.info { "Fetching users and groups from Identity Store" }
        users = client.list_users
        groups = client.list_groups
        memberships = client.list_group_memberships(groups)

        Log.info { "Fetched #{users.size} users, #{groups.size} groups" }

        # Sort by external_id for stable UID/GID assignment across syncs.
        sorted_groups = groups.sort_by(&.group_id)
        sorted_users  = users.sort_by(&.user_id)

        # GIDs: 60001, 60002, … (one per group)
        group_gid = {} of String => Int32
        sorted_groups.each_with_index { |g, i| group_gid[g.group_id] = 60001 + i }

        # UIDs: 60001+groups.size, … (one per user)
        uid_base = 60001 + sorted_groups.size
        user_uid = {} of String => Int32
        sorted_users.each_with_index { |u, i| user_uid[u.user_id] = uid_base + i }

        # Resolve user_id → username for group membership entries.
        id_to_username = {} of String => String
        sorted_users.each { |u| id_to_username[u.user_id] = u.username }

        # Primary group GID per user (first group in sorted order they belong to).
        user_primary_gid = {} of String => Int32
        sorted_groups.each do |g|
          gid = group_gid[g.group_id]
          (memberships[g.group_id]? || [] of String).each do |user_id|
            user_primary_gid[user_id] ||= gid
          end
        end

        payload = JSON.build do |json|
          json.object do
            json.field "groups" do
              json.array do
                sorted_groups.each do |g|
                  json.object do
                    json.field "name", g.display_name
                    json.field "gid", group_gid[g.group_id]
                    json.field "members" do
                      json.array do
                        (memberships[g.group_id]? || [] of String).each do |user_id|
                          if username = id_to_username[user_id]?
                            json.string username
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
            json.field "users" do
              json.array do
                sorted_users.each do |u|
                  uid = user_uid[u.user_id]
                  gid = user_primary_gid[u.user_id]? || uid
                  json.object do
                    json.field "username", u.username
                    json.field "uid", uid
                    json.field "gid", gid
                    json.field "gecos", u.display_name
                    json.field "home", "/home/#{u.username}"
                    json.field "shell", "/bin/bash"
                    json.field "email", u.email if u.email
                  end
                end
              end
            end
          end
        end

        {payload, sorted_users.size, sorted_groups.size}
      end
    end
  end
end
