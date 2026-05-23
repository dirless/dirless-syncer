# dirless-syncer

Crystal daemon that syncs users, groups, and memberships from AWS IAM Identity Center to the Dirless backend. Runs on customer infrastructure — the Dirless backend never reaches into the customer's AWS account.

## What it does

1. Fetches temporary AWS credentials from EC2 IMDS (IMDSv2)
2. Calls AWS Identity Store API: lists users, groups, memberships
3. Acquires the singleton syncer lease from the backend (one syncer per tenant)
4. POSTs the sync payload to the backend over mTLS
5. Renews the lease via heartbeat during sync
6. Sleeps until next interval

## Language / stack

- Crystal >= 1.9.0
- TOML config
- mTLS for backend communication (certs from `/etc/dirless/`)
- AWS SigV4 signing for Identity Store API calls

## Key entry points

| File | Purpose |
|------|---------|
| `src/dirless_syncer.cr` | Entry point — loads config, starts sync loop |
| `src/dirless/syncer/sync_loop.cr` | Main loop: acquire lease → sync → heartbeat → sleep |
| `src/dirless/syncer/identity_store.cr` | AWS Identity Store API client (list users/groups/memberships) |
| `src/dirless/syncer/backend_client.cr` | mTLS HTTP client for Dirless backend |
| `src/dirless/syncer/aws_credentials.cr` | IMDSv2 credential fetching |
| `src/dirless/syncer/aws_signer.cr` | AWS SigV4 request signing |
| `src/dirless/syncer/config.cr` | TOML config struct |
| `config/dirless-syncer.example.toml` | Config reference |

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

## Prerequisites

- Must run on an EC2 instance with the above IAM role
- `dirless-cli enroll` must have run first — mTLS certs must exist at `/etc/dirless/`

## Config

Copy `config/dirless-syncer.example.toml` to `/etc/dirless/dirless-syncer.toml`. Override path with `DIRLESS_SYNCER_CONFIG` env var.

## Build & test

```sh
shards install
crystal spec
crystal build src/dirless_syncer.cr -o dirless-syncer
DIRLESS_SYNCER_CONFIG=/etc/dirless/dirless-syncer.toml ./dirless-syncer
```
