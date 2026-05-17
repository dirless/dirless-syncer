require "log"
require "./dirless/syncer/config"
require "./dirless/syncer/enroller"
require "./dirless/syncer/sync_loop"

Log.setup_from_env(default_level: :info)

config_path = ENV.fetch("DIRLESS_SYNCER_CONFIG", "/etc/dirless/dirless-syncer.toml")
config = Dirless::Syncer::Config.load(config_path)

unless Dirless::Syncer::Enroller.enrolled?(config)
  token = config.enrollment_token || begin
    Log.error { "No mTLS certs found at #{config.cert_path} and no enrollment_token set in config" }
    exit 1
  end
  Dirless::Syncer::Enroller.enroll(config, token)
end

Dirless::Syncer::SyncLoop.new(config).run
