require "toml"

module Dirless
  module Syncer
    struct Config
      getter backend_url : String
      getter identity_store_id : String
      getter region : String
      getter syncer_id : String
      getter interval_seconds : Int64
      getter heartbeat_interval_seconds : Int64
      getter cert_path : String
      getter key_path : String
      getter ca_path : String

      def initialize(
        @backend_url : String,
        @identity_store_id : String,
        @region : String,
        @syncer_id : String,
        @interval_seconds : Int64,
        @heartbeat_interval_seconds : Int64,
        @cert_path : String,
        @key_path : String,
        @ca_path : String,
      )
      end

      def self.load(path : String) : Config
        raw = File.read(path)
        toml = TOML.parse(raw)

        new(
          backend_url: toml["backend"]["url"].as_s,
          identity_store_id: toml["identity_center"]["identity_store_id"].as_s,
          region: toml["identity_center"]["region"].as_s,
          syncer_id: toml["syncer"]["id"].as_s,
          interval_seconds: toml["syncer"]["interval_seconds"].as_i.to_i64,
          heartbeat_interval_seconds: toml["syncer"]["heartbeat_interval_seconds"].as_i.to_i64,
          cert_path: toml["tls"]["cert_path"].as_s,
          key_path: toml["tls"]["key_path"].as_s,
          ca_path: toml["tls"]["ca_path"].as_s,
        )
      end
    end
  end
end
