require "log"
require "socket"
require "./config"
require "./aws_credentials"
require "./identity_store"
require "./backend_client"

module Dirless
  module Syncer
    class SyncLoop
      Log = ::Log.for("dirless.syncer")

      def initialize(@config : Config, @identity_store_id : String, @region : String, @syncer_id : String)
        @backend = BackendClient.new(
          base_url: @config.backend_url,
          cert_path: @config.cert_path,
          key_path: @config.key_path,
          ca_path: @config.ca_path,
        )
      end

      def run : Nil
        Log.info { "Syncer started (id=#{@syncer_id}, interval=#{@config.interval_seconds}s)" }
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
          ips = resolve_backend_ips
          Log.info { "Posting sync payload to #{ips.size} backend node(s): #{ips.join(", ")}" }
          @backend.sync_all(payload, ips)
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
        expires_at = @backend.acquire_lease(@syncer_id)
        Log.info { "Lease acquired (expires_at=#{expires_at})" }
      end

      private def start_heartbeat : Channel(Nil)
        ch = Channel(Nil).new
        spawn do
          consecutive_failures = 0
          loop do
            select
            when ch.receive?
              break
            when timeout(@config.heartbeat_interval_seconds.seconds)
              begin
                @backend.heartbeat(@syncer_id)
                Log.debug { "Heartbeat renewed" }
                consecutive_failures = 0
              rescue ex
                consecutive_failures += 1
                Log.warn { "Heartbeat failed (attempt #{consecutive_failures}): #{ex.message}" }
                if consecutive_failures >= 3
                  Log.error { "Heartbeat failed #{consecutive_failures} times consecutively — lease may have expired, aborting sync" }
                  ch.close
                  break
                end
              end
            end
          end
        end
        ch
      end

      # Returns the list of backend IPs to push the sync payload to.
      #
      # For HTTPS backends (production), resolves all DNS A records so the
      # payload is pushed directly to each node's IP, bypassing the DNS
      # round-robin that would otherwise deliver consecutive syncs to different
      # nodes. For HTTP backends (dev / test), the hostname is used as-is to
      # keep WebMock stubs working and avoid unnecessary DNS lookups.
      private def resolve_backend_ips : Array(String)
        uri = URI.parse(@config.backend_url)
        host = uri.host.not_nil!
        return [host] unless uri.scheme == "https"

        port = uri.port || 443
        addrs = Socket::Addrinfo.resolve(host, port, type: Socket::Type::STREAM)
        ips = addrs.map(&.ip_address.address).uniq!
        Log.debug { "resolved #{host} → #{ips.join(", ")}" }
        ips
      rescue ex
        Log.warn { "DNS resolution failed for #{@config.backend_url}: #{ex.message} — falling back to single host" }
        uri = URI.parse(@config.backend_url)
        [uri.host.not_nil!]
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

        # Assign primary group: the group with the smallest (sorted-first)
        # group_id that the user belongs to.  Sorting makes the assignment
        # deterministic regardless of Hash iteration / AWS API response order.
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
