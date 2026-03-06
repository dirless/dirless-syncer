require "log"
require "./dirless/syncer/config"
require "./dirless/syncer/sync_loop"

Log.setup_from_env(default_level: :info)

config_path = ENV.fetch("DIRLESS_SYNCER_CONFIG", "/etc/dirless/dirless-syncer.toml")
config = Dirless::Syncer::Config.load(config_path)
Dirless::Syncer::SyncLoop.new(config).run
