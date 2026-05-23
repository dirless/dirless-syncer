require "toml"

module Dirless
  module Syncer
    struct Config
      getter backend_url : String
      getter enrollment_token : String?
      getter identity_store_id : String?
      getter region : String?
      getter interval_seconds : Int64

      def initialize(
        @backend_url : String,
        @enrollment_token : String?,
        @identity_store_id : String?,
        @region : String?,
        @interval_seconds : Int64,
      )
      end

      def self.load(path : String) : Config
        raw = File.read(path)
        toml = TOML.parse(raw)

        config = new(
          backend_url: toml["backend"]["url"].as_s,
          enrollment_token: toml["backend"]["enrollment_token"]?.try(&.as_s),
          identity_store_id: toml["identity_center"]?.try(&.["identity_store_id"]?).try(&.as_s),
          region: toml["identity_center"]?.try(&.["region"]?).try(&.as_s),
          interval_seconds: toml["syncer"]["interval_seconds"].as_i.to_i64,
        )
        config.validate!
        config
      end

      protected def validate!
        raise "Config error: backend_url must not be empty" if @backend_url.empty?
        unless @backend_url.starts_with?("http://") || @backend_url.starts_with?("https://")
          raise "Config error: backend_url must start with http:// or https://"
        end
        raise "Config error: interval_seconds must be positive" if @interval_seconds <= 0
      end
    end
  end
end
