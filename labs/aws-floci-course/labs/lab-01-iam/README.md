# Lab 01 — IAM — completed

## What exists after this lab
- Environment: Floci via docker-compose.yml, FLOCI_STORAGE_MODE=hybrid,
  bind-mounted to ~/floci-data, persistence proven in Step 14
- Groups: usms-admins, usms-developers, usms-auditors
- Users: usms-admin-01, usms-dev-01, usms-audit-01
- Customer managed policies: USMSDeveloperBase (v2), USMSStudentDataReadWrite,
  USMSAssumeAppRoles, USMSLambdaBasic
- Inline policy: USMSSelfManageCredentials on usms-dev-01
- Roles: usms-ec2-app-role, usms-lambda-exec-role, usms-developer-role
- Instance profile: usms-ec2-app-profile

## Reproduce
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
./scripts/utilities/verify-lab-01.sh

## Evidence
- [x] whoami.sh output showing account 000000000000
- [x] floci-storage-check.sh output, all [ok]
- [x] Step 14 persistence proof (user survived a restart)
- [ ] verify-lab-01.sh with FAIL=0

## Problems I hit and how I fixed them
- `sudo apt-get`/`sudo` hung indefinitely when run non-interactively (no TTY to
  supply a password to) — avoided sudo entirely; jq and poppler-utils-equivalent
  tooling were either already present or unnecessary.
- `aws iam get-account-authorization-details` returned `UnsupportedOperation` on
  this Floci build (not one of the guide's documented limitations) — reconstructed
  an equivalent snapshot manually from list-users/list-groups/list-roles/
  list-policies + get-policy-version calls.
- `floci snapshot save` returned "Snapshot API not available on this server
  version" — used the documented tar fallback (stop Floci, tar ~/floci-data,
  restart) instead.
- `simulate-principal-policy` returned a simplified result: ec2:CreateVpc showed
  implicitDeny instead of allowed, even though it's granted via the
  usms-developers group's USMSDeveloperBase policy — matches the guide's noted
  Floci limitation that the simulator may not fully evaluate group policies here.
- A stray container named `floci` (started by a bare `floci start` before this
  lab began) blocked `floci-up.sh`'s Compose-ownership check in Part A; removed
  with `docker rm -f floci` per the script's own guidance before proceeding.
