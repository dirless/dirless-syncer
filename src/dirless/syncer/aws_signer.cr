require "openssl/hmac"
require "digest/sha256"
require "http/headers"

module Dirless
  module Syncer
    # AWS Signature Version 4 signing for HTTP requests.
    module AWSSigner
      ALGORITHM = "AWS4-HMAC-SHA256"

      def self.sign(
        method : String,
        uri : URI,
        service : String,
        region : String,
        credentials : AWSCredentials,
        headers : HTTP::Headers,
        body : String = "",
      ) : HTTP::Headers
        now = Time.utc
        date_time = now.to_s("%Y%m%dT%H%M%SZ")
        date       = now.to_s("%Y%m%d")

        headers = headers.dup
        headers["Host"]                = uri.host.not_nil!
        headers["X-Amz-Date"]          = date_time
        headers["X-Amz-Security-Token"] = credentials.session_token unless credentials.session_token.empty?

        canonical_headers, signed_headers = build_canonical_headers(headers)
        payload_hash = Digest::SHA256.hexdigest(body)

        canonical_request = String.build do |s|
          s << method << "\n"
          s << uri_encode_path(uri.path) << "\n"
          s << canonical_query(uri.query) << "\n"
          s << canonical_headers << "\n"
          s << signed_headers << "\n"
          s << payload_hash
        end

        credential_scope = "#{date}/#{region}/#{service}/aws4_request"
        string_to_sign = String.build do |s|
          s << ALGORITHM << "\n"
          s << date_time << "\n"
          s << credential_scope << "\n"
          s << Digest::SHA256.hexdigest(canonical_request)
        end

        signing_key = derive_signing_key(credentials.secret_access_key, date, region, service)
        signature   = OpenSSL::HMAC.hexdigest(:sha256, signing_key, string_to_sign)

        headers["Authorization"] = "#{ALGORITHM} " \
          "Credential=#{credentials.access_key_id}/#{credential_scope}, " \
          "SignedHeaders=#{signed_headers}, " \
          "Signature=#{signature}"

        headers
      end

      private def self.build_canonical_headers(headers : HTTP::Headers) : {String, String}
        sorted = headers.map { |k, v| {k.downcase, v.join(",").strip} }.sort_by(&.[0])
        canonical = sorted.map { |k, v| "#{k}:#{v}\n" }.join
        signed    = sorted.map(&.[0]).join(";")
        {canonical, signed}
      end

      private def self.canonical_query(query : String?) : String
        return "" unless query && !query.empty?
        query.split("&")
          .map { |p| p.split("=", 2) }
          .sort_by(&.[0])
          .map { |parts| parts.join("=") }
          .join("&")
      end

      private def self.uri_encode_path(path : String) : String
        path.empty? ? "/" : path
      end

      private def self.derive_signing_key(secret : String, date : String, region : String, service : String) : Bytes
        k_date    = OpenSSL::HMAC.digest(:sha256, "AWS4#{secret}", date)
        k_region  = OpenSSL::HMAC.digest(:sha256, k_date, region)
        k_service = OpenSSL::HMAC.digest(:sha256, k_region, service)
        OpenSSL::HMAC.digest(:sha256, k_service, "aws4_request")
      end
    end
  end
end
