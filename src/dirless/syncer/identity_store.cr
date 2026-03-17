require "http/client"
require "json"
require "uri"
require "./aws_credentials"
require "./aws_signer"

module Dirless
  module Syncer
    record ISUser,
      user_id : String,
      username : String,
      display_name : String

    record ISGroup,
      group_id : String,
      display_name : String

    # Client for the AWS IAM Identity Center Identity Store API.
    class IdentityStoreClient
      SERVICE = "identitystore"

      def initialize(
        @identity_store_id : String,
        @region : String,
        @credentials : AWSCredentials,
      )
        @endpoint = "https://identitystore.#{@region}.amazonaws.com"
      end

      def list_users : Array(ISUser)
        paginate("AWSIdentityStore.ListUsers", {} of String => String, "Users") do |item|
          ISUser.new(
            user_id:      item["UserId"].as_s,
            username:     item["UserName"].as_s,
            display_name: item["DisplayName"]?.try(&.as_s) || item["UserName"].as_s,
          )
        end
      end

      def list_groups : Array(ISGroup)
        paginate("AWSIdentityStore.ListGroups", {} of String => String, "Groups") do |item|
          ISGroup.new(
            group_id:     item["GroupId"].as_s,
            display_name: item["DisplayName"].as_s,
          )
        end
      end

      # Returns a map of group_id => Array(user_id)
      def list_group_memberships(groups : Array(ISGroup)) : Hash(String, Array(String))
        result = {} of String => Array(String)
        groups.each do |group|
          members = paginate(
            "AWSIdentityStore.ListGroupMemberships",
            {"GroupId" => group.group_id},
            "GroupMemberships",
          ) do |item|
            item["MemberId"].as_h["UserId"].as_s
          end
          result[group.group_id] = members
        end
        result
      end

      MAX_RETRIES = 3

      # AWS Identity Store uses the JSON 1.1 RPC protocol: all operations POST
      # to the root path with X-Amz-Target and a JSON body.
      private def paginate(target : String, extra_params : Hash(String, String), key : String, & : JSON::Any -> T) : Array(T) forall T
        results = [] of T
        next_token : String? = nil
        uri = URI.parse("#{@endpoint}/")
        retries = 0

        loop do
          body_hash = {"IdentityStoreId" => @identity_store_id}.merge(extra_params)
          body_hash["NextToken"] = next_token if next_token
          body = body_hash.to_json

          base_headers = HTTP::Headers{
            "Content-Type" => "application/x-amz-json-1.1",
            "X-Amz-Target" => target,
          }
          headers = AWSSigner.sign("POST", uri, SERVICE, @region, @credentials, base_headers, body)

          client = HTTP::Client.new(uri)
          client.connect_timeout = 10.seconds
          client.read_timeout = 30.seconds
          begin
            response = client.post(uri.request_target, headers: headers, body: body)
          ensure
            client.close
          end

          if response.status_code == 200
            retries = 0
            parsed = JSON.parse(response.body)
            (parsed[key]?.try(&.as_a) || [] of JSON::Any).each do |item|
              results << yield item
            end

            next_token = parsed["NextToken"]?.try(&.as_s)
            break unless next_token
          elsif response.status_code == 429 || response.status_code >= 500
            retries += 1
            raise "Identity Store API error after #{MAX_RETRIES} retries (HTTP #{response.status_code}): #{response.body}" if retries > MAX_RETRIES
            delay = Math.min(2.0 ** retries, 30.0)
            Log.warn { "Identity Store returned #{response.status_code}, retry #{retries}/#{MAX_RETRIES} in #{delay}s" }
            sleep delay.seconds
            next
          else
            raise "Identity Store API error (HTTP #{response.status_code}): #{response.body}"
          end
        end

        results
      end

      private Log = ::Log.for("dirless.syncer.identity_store")
    end
  end
end
