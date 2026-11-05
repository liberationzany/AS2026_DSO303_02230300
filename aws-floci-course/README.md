# AWS CLI + Floci — USMS Course Project

Infrastructure for the **University Student Management System (USMS)**, built lab by lab
with the AWS CLI against [Floci](https://floci.io), a local AWS emulator.

## Quick start

```bash
source configs/course.env
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

## Daily workflow

```bash
./scripts/setup/floci-up.sh      # start or resume (idempotent)
# ... lab work ...
./scripts/setup/floci-down.sh    # pause; state is kept
```

## Never run these

| Command | Why |
|---|---|
| `docker compose down -v` | `-v` deletes volumes |
| `docker volume prune` | Unfiltered; use `scripts/cleanup/floci-prune-volumes.sh` |
| `floci start ...` | Bypasses Compose; disables persistence |
| `rm -rf ~/floci-data` | That directory is the IAM state |

## Labs

| Lab | Topic | Status |
|---|---|---|
| 01 | IAM | [x] complete |
| 02 | VPC | [x] complete |
| 03 | EC2 | [x] complete |
| 04 | ECS | [x] complete |
| 05 | ALB | [x] complete |
| 06 | Auto Scaling | [x] complete (Path C - no Application Auto Scaling on this build) |
| 07 | EKS | [x] complete (Path A - real k3s cluster) |
| 08 | EKS Scaling and Service Exposure | [x] complete (Path A) |
| 09 | Security - IAM roles and security groups | [x] complete (Path A) |

## Conventions

- All resources are prefixed `usms-`
- Region: `us-east-1` · Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed
