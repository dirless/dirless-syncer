# dirless-syncer

Syncs users, groups, and memberships from AWS IAM Identity Center to the Dirless backend. Runs on customer infrastructure — the backend never reaches into your AWS account.

## How it works

1. Fetches temporary AWS credentials from EC2 IMDS (IMDSv2)
2. Fetches the AWS account ID from the IMDS identity document
3. Calls the Identity Store API to list users, groups, and memberships
4. Encrypts the payload with age using the enrolled public key
5. PUTs the encrypted snapshot to the backend (`PUT /v1/snapshot/aws-identity-center`)
6. Sleeps until the next interval

The backend receives only the encrypted blob — it never sees plaintext user data.

## Requirements

- Must run on an EC2 instance with an IAM role that has Identity Store read permissions
- `dirless-cli enroll` must have run first to generate mTLS certificates

## IAM permissions required

```json
{
  "Effect": "Allow",
  "Action": [
    "identitystore:ListUsers",
    "identitystore:ListGroups",
    "identitystore:ListGroupMemberships"
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

Create `/etc/dirless/dirless-syncer.toml`:

```toml
[backend]
url              = "https://yourname.dirless.com"  # your Dirless subdomain
enrollment_token = "your-token-here"               # from your portal dashboard

# [identity_center]               # normally auto-detected — uncomment only to override
# identity_store_id = "d-1234567890"
# region = "us-east-1"

[syncer]
interval_seconds = 300  # sync every 5 minutes
```

On first start, the syncer uses `enrollment_token` to generate mTLS certificates and register with the backend. The token can be removed from the config afterwards.

Config path can be overridden with `DIRLESS_SYNCER_CONFIG`.

## Running

```sh
# If installed via RPM (systemd unit included):
systemctl enable --now dirless-syncer

# Or run directly:
dirless-syncer
```

## UID/GID assignment

UIDs and GIDs are assigned deterministically based on the sorted order of Identity Store object IDs — the same user always gets the same UID across every node in the fleet, without any central coordination.

- Groups: GIDs starting at 60001
- Users: UIDs starting at `60001 + number_of_groups`

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
