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

- Crystal >= 1.9.0
- Must run on an EC2 instance with an IAM role that has Identity Store read permissions
- Enrollment must be completed first (`dirless-cli enroll`) — mTLS certs must exist at `/etc/dirless/`

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

## Configuration

Copy `config/dirless-syncer.example.toml` to `/etc/dirless/dirless-syncer.toml`
and fill in your values. The config path can be overridden with the
`DIRLESS_SYNCER_CONFIG` environment variable.

## Building

```sh
shards install
crystal build src/dirless_syncer.cr -o dirless-syncer
```

## Running

```sh
DIRLESS_SYNCER_CONFIG=/etc/dirless/dirless-syncer.toml ./dirless-syncer
```

## Testing

```sh
shards install
crystal spec
```
