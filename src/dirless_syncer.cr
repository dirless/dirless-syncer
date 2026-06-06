require "log"
require "./dirless/syncer/config"
require "./dirless/syncer/enroller"
require "./dirless/syncer/aws_credentials"
require "./dirless/syncer/aws_detector"
require "./dirless/syncer/sync_loop"

Log.setup_from_env(default_level: :info)

config_path = ENV.fetch("DIRLESS_SYNCER_CONFIG", "/etc/dirless/dirless-syncer.toml")
config = Dirless::Syncer::Config.load(config_path)

unless Dirless::Syncer::Enroller.enrolled?
  token = config.enrollment_token || begin
    Log.error { "Not enrolled and no enrollment_token set in config" }
    exit 1
  end
  Dirless::Syncer::Enroller.enroll(config, token)
end

hmac_secret    = Dirless::Syncer::Enroller.read_hmac_secret
tenant_id      = Dirless::Syncer::Enroller.read_tenant_id
age_public_key = Dirless::Syncer::Enroller.read_age_public_key

region = config.region || begin
  Log.info { "region not set in config - auto-detecting from IMDS" }
  Dirless::Syncer::AWSDetector.detect_region
end

identity_store_id = config.identity_store_id || begin
  Log.info { "identity_store_id not set in config - auto-detecting via SSO Admin API" }
  credentials = Dirless::Syncer::IMDSCredentials.fetch
  Dirless::Syncer::AWSDetector.detect_identity_store_id(region, credentials)
end

Log.info { "Using tenant_id=#{tenant_id} region=#{region} identity_store_id=#{identity_store_id}" }

Dirless::Syncer::SyncLoop.new(
  config,
  identity_store_id: identity_store_id,
  region: region,
  hmac_secret: hmac_secret,
  tenant_id: tenant_id,
  age_public_key: age_public_key,
).run
