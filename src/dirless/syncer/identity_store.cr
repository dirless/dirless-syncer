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
        @base_url = "https://identitystore.#{@region}.amazonaws.com"
      end

      def list_users : Array(ISUser)
        paginate("/identitystores/#{@identity_store_id}/users", "Users") do |item|
          ISUser.new(
            user_id:      item["UserId"].as_s,
            username:     item["UserName"].as_s,
            display_name: item["DisplayName"]?.try(&.as_s) || item["UserName"].as_s,
          )
        end
      end

      def list_groups : Array(ISGroup)
        paginate("/identitystores/#{@identity_store_id}/groups", "Groups") do |item|
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
            "/identitystores/#{@identity_store_id}/groups/#{group.group_id}/memberships",
            "GroupMemberships",
          ) do |item|
            item["MemberId"].as_h["UserId"].as_s
          end
          result[group.group_id] = members
        end
        result
      end

      private def paginate(path : String, key : String, & : JSON::Any -> T) : Array(T) forall T
        results = [] of T
        next_token : String? = nil

        loop do
          query = next_token ? "nextToken=#{URI.encode_www_form(next_token)}" : nil
          uri   = URI.parse("#{@base_url}#{path}#{query ? "?#{query}" : ""}")
          headers = AWSSigner.sign("GET", uri, SERVICE, @region, @credentials, HTTP::Headers.new)

          response = HTTP::Client.get(uri, headers: headers)
          raise "Identity Store API error (HTTP #{response.status_code}): #{response.body}" unless response.status_code == 200

          parsed = JSON.parse(response.body)
          (parsed[key]?.try(&.as_a) || [] of JSON::Any).each do |item|
            results << yield item
          end

          next_token = parsed["nextToken"]?.try(&.as_s)
          break unless next_token
        end

        results
      end
    end
  end
end
