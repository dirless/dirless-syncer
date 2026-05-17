# dirless-syncer

Syncs users, groups, and memberships from AWS IAM Identity Center to the
Dirless backend. Runs on customer infrastructure — the backend never reaches
into your AWS account.

## How it works

1. Fetches temporary AWS credentials from EC2 IMDS (IMDSv2)
2. Calls the Identity Store API to list users, groups, and memberships
3. Acquires a sync lease from the Dirless backend (one syncer per tenant at a time)
4. POSTs the sync payload to the backend over mTLS
5. Renews the lease via heartbeat while the sync is in progress
6. Sleeps until the next interval

## Requirements

- Must run on an EC2 instance with an IAM role that has Identity Store read permissions

## IAM permissions required

```json
{
  "Effect": "Allow",
  "Action": [
    "identitystore:ListUsers",
    "identitystore:ListGroups",
    "identitystore:ListGroupMemberships",
    "sso:ListInstances"
  ],
  "Resource": "*"
}
```

## Installation

### Option 1 — RPM (RHEL / Amazon Linux 2023)

```sh
curl -fsSL https://dirless.com/rpm/dirless.repo \
  -o /etc/yum.repos.d/dirless.repo
dnf install -y dirless-syncer
```

### Option 2 — Direct binary (Linux x86_64)

```sh
curl -fsSL https://github.com/dirless/dirless-syncer/releases/latest/download/dirless-syncer-x86_64 \
  -o /usr/local/bin/dirless-syncer
chmod +x /usr/local/bin/dirless-syncer
```

## Configuration

Copy the example config and fill in your values:

```sh
cp /usr/share/doc/dirless-syncer/dirless-syncer.example.toml /etc/dirless/dirless-syncer.toml
```

Or create `/etc/dirless/dirless-syncer.toml` manually:

```toml
[backend]
url              = "https://yourname.dirless.com"  # your Dirless subdomain
enrollment_token = "your-token-here"               # from your portal dashboard

# [identity_center]               # normally auto-detected — uncomment only to override
# identity_store_id = "d-1234567890"
# region = "us-east-1"

[syncer]
id = "syncer-01"               # unique, stable name for this syncer instance
interval_seconds = 300         # sync every 5 minutes
```

On first start, the syncer uses `enrollment_token` to generate mTLS certificates and register
with the backend automatically. The token can be removed from the config afterwards — the
certificates handle authentication from that point on.

The config path can be overridden with the `DIRLESS_SYNCER_CONFIG` environment variable.

## Running

```sh
# If installed via RPM (service file included):
systemctl enable --now dirless-syncer

# Or run directly:
dirless-syncer
```

## Building from source

```sh
shards install
crystal build src/dirless_syncer.cr -o dirless-syncer --release
```

## Testing

```sh
shards install
crystal spec
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
