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

      # AWS Identity Store uses the JSON 1.1 RPC protocol: all operations POST
      # to the root path with X-Amz-Target and a JSON body.
      private def paginate(target : String, extra_params : Hash(String, String), key : String, & : JSON::Any -> T) : Array(T) forall T
        results = [] of T
        next_token : String? = nil
        uri = URI.parse("#{@endpoint}/")

        loop do
          body_hash = {"IdentityStoreId" => @identity_store_id}.merge(extra_params)
          body_hash["NextToken"] = next_token if next_token
          body = body_hash.to_json

          base_headers = HTTP::Headers{
            "Content-Type" => "application/x-amz-json-1.1",
            "X-Amz-Target" => target,
          }
          headers = AWSSigner.sign("POST", uri, SERVICE, @region, @credentials, base_headers, body)

          response = HTTP::Client.post(uri, headers: headers, body: body)
          raise "Identity Store API error (HTTP #{response.status_code}): #{response.body}" unless response.status_code == 200

          parsed = JSON.parse(response.body)
          (parsed[key]?.try(&.as_a) || [] of JSON::Any).each do |item|
            results << yield item
          end

          next_token = parsed["NextToken"]?.try(&.as_s)
          break unless next_token
        end

        results
      end
    end
  end
end
