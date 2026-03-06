require "log"
require "./config"
require "./aws_credentials"
require "./identity_store"
require "./backend_client"

module Dirless
  module Syncer
    class SyncLoop
      Log = ::Log.for("dirless.syncer")

      def initialize(@config : Config)
        @backend = BackendClient.new(
          base_url:  @config.backend_url,
          cert_path: @config.cert_path,
          key_path:  @config.key_path,
          ca_path:   @config.ca_path,
        )
      end

      def run : Nil
        Log.info { "Syncer started (id=#{@config.syncer_id}, interval=#{@config.interval_seconds}s)" }
        loop do
          run_once
          Log.info { "Sleeping #{@config.interval_seconds}s until next sync" }
          sleep @config.interval_seconds.seconds
        end
      end

      def run_once : Nil
        acquire_lease
        heartbeat_channel = start_heartbeat
        begin
          payload = build_payload
          Log.info { "Posting sync payload to backend" }
          @backend.sync(payload)
          Log.info { "Sync complete" }
        ensure
          heartbeat_channel.close
        end
      rescue ex : LeaseConflictError
        Log.warn { "Lease held by another syncer (expires_at=#{ex.expires_at}) — skipping this cycle" }
      rescue ex : Exception
        Log.error { "Sync failed: #{ex.message}" }
      end

      private def acquire_lease : Nil
        Log.info { "Acquiring lease" }
        expires_at = @backend.acquire_lease(@config.syncer_id)
        Log.info { "Lease acquired (expires_at=#{expires_at})" }
      end

      private def start_heartbeat : Channel(Nil)
        ch = Channel(Nil).new
        spawn do
          loop do
            select
            when ch.receive?
              break
            when timeout(@config.heartbeat_interval_seconds.seconds)
              begin
                @backend.heartbeat(@config.syncer_id)
                Log.debug { "Heartbeat renewed" }
              rescue ex
                Log.warn { "Heartbeat failed: #{ex.message}" }
              end
            end
          end
        end
        ch
      end

      private def build_payload : String
        credentials = IMDSCredentials.fetch
        client = IdentityStoreClient.new(@config.identity_store_id, @config.region, credentials)

        Log.info { "Fetching users and groups from Identity Store" }
        users  = client.list_users
        groups = client.list_groups
        memberships = client.list_group_memberships(groups)

        Log.info { "Fetched #{users.size} users, #{groups.size} groups" }

        # Build a user_id => username map for membership resolution
        user_index = users.each_with_object({} of String => ISUser) { |u, h| h[u.user_id] = u }

        payload_groups = groups.map do |group|
          member_usernames = (memberships[group.group_id]? || [] of String)
            .compact_map { |uid| user_index[uid]?.try(&.username) }
          {
            "name"        => group.display_name,
            "external_id" => group.group_id,
            "members"     => member_usernames,
          }
        end

        # Assign primary group: first group the user is a member of
        user_primary_group = {} of String => String
        memberships.each do |group_id, user_ids|
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
