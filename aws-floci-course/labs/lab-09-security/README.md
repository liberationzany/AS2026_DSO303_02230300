# Lab 09 — Securing the USMS Application with IAM Roles and Security Groups

**Support path: A — full.** Every Step 3 capability probe answered
`SUPPORTED`, including `iam:simulate-principal-policy`, which genuinely
evaluates real policy documents (confirmed with both `implicitDeny` and
`allowed` verdicts, matched independently against a hand-computed
intersection) — a materially stronger emulation than the guide's own
"typical" (Path B) expectation.

## What this lab built

A review of the identity and network posture Labs 01–06 left behind, adding
rather than replacing: `USMSStudentDataReadOnly` (the read-only half of the
shared transcripts policy) and `usms-transcripts-reader-role`; a rewritten,
confused-deputy-conditioned trust policy on `usms-ecs-task-role`;
`USMSPermissionsBoundary` and a scoped `iam:PassRole` (`USMSDeployBase`) on
the new `usms-deploy-role`; a genuine access-key rotation for `usms-dev-01`;
an IMDSv2 requirement on `usms-web-01`; written egress rules on
`usms-alb-sg`, `usms-enrolment-sg` and `usms-db-sg`; a bastion-sourced SSH
rule replacing the VPC-wide one on `usms-app-sg`; and three new read-only
audit tools (`usms-iam-audit.sh`, `usms-sg-audit.sh`,
`usms-reachability-matrix.sh`).

## Findings worth reading before the verify output

### 1. A headline finding: `revoke-security-group-egress`/`-ingress` are complete no-ops on this build

Every "replace the old rule, then remove it" cutover in this lab (Steps
13–16) succeeded at the *authorize* half — the new, correct rule is
genuinely present every time — but the *revoke* half never removes anything,
despite reporting `Return: true` every single call. Confirmed four separate
times, including via precise `--security-group-rule-ids` (not just a
document-shape match), across both egress and ingress. This is a materially
different, more severe category than any Floci gap found earlier in the
course: not an unrecognised operation, not a named-but-unimplemented one
honestly erroring out — here the call claims success while doing nothing.

Compounding it: `describe-security-groups`'s `IpPermissionsEgress` field
silently *omits* the stale rule from its response on at least one group,
while the granular `describe-security-group-rules` API correctly shows it
still present. The guide's own prescribed verification method uses the
former and would give a false pass here. `verify-lab-09.sh` queries the
granular API instead and reports the true state, marked as a documented,
investigated limitation rather than hidden.

### 2. `Instances[].PublicIpAddress` is a non-functional constant; `describe-addresses --filters` does not filter

Both `usms-web-01` (genuinely holding a real, associated Elastic IP,
`54.96.140.123`, per `describe-addresses`) and `usms-db-01` (holding none)
report the identical, meaningless `PublicIpAddress: "127.0.0.1"` from
`describe-instances` — making Step 17's prescribed negative-proof check
unusable as written. Separately, `describe-addresses --filters
Name=instance-id,...` returns every address in the account regardless of the
filter given. The reliable method, used throughout this report: fetch the
unfiltered address list and match `InstanceId` client-side.

### 3. Permissions boundaries: accepted, never persisted (confirmed, matches the guide's own documented benign failure)

`--permissions-boundary` on `create-role` and a subsequent
`put-role-permissions-boundary` both return success; `get-role` always reads
back `null`.

### 4. The pre-existing group-reference persistence gap (Labs 02/04/05) recurs on every new group-sourced rule this lab wrote

`usms-alb-sg`'s new egress rule naming `usms-enrolment-sg`, and `usms-app-sg`'s
new SSH rule naming `usms-bastion-sg`, both read back with an empty
`UserIdGroupPairs` — the same root cause documented in Lab 05, now confirmed
on two further rule types.

### 5. A new Windows/Git-Bash finding, the inverse of the earlier MSYS path-mangling bugs

A POSIX path embedded *inside* a `python -c "..."` string is never rewritten
by MSYS's automatic argv path-conversion (which only touches standalone argv
tokens), so a plain `python.exe` resolves it using native Windows semantics —
`/tmp/...` becomes `C:\tmp\...`, a directory that doesn't exist — and fails
deterministically. Passing the same path as its own argument lets the
correct conversion happen. Fixed in `usms-sg-audit.sh`.

### 6. Two of my own JMESPath/variable mistakes, caught and corrected before they reached the record

An ARN-vs-bare-name mismatch in this repo's own `lab-01.env` (`USMS_ROLE_EC2`
etc. store full ARNs, not names, unlike the guide's assumption) produced two
false "not available" probe readings in Step 3, corrected by stripping the
ARN prefix. A backtick numeric literal (`` IpProtocol==`-1` ``) against a
string-typed API field silently failed to match where a quoted string
literal (`IpProtocol=='-1'`) succeeded — caught by directly cross-checking
against a raw, unfiltered table before trusting the filtered count.

## What was genuinely observed vs. recorded vs. conceptual

**Observed directly:** the full IAM audit (6 HIGH / 29 MED findings across 7
roles, scaled correctly for this account's EKS-era role set); the read-only
policy split with a genuine explicit Deny; the trust-policy rewrite's
same-principal-new-condition proof; `simulate-principal-policy`'s real,
correct evaluation (both directions); the session-policy intersection,
cross-checked by both hand computation and live simulation, agreeing
exactly; the access-key rotation (adapted — see below); the full security
group audit and reachability matrix; the five-control negative proof on
`usms-db-01` (4 of 5 clean; the fifth weakened by Finding 4 above); full
persistence across a real Floci restart, including the honestly-reproduced
Floci-limitation state itself.

**Recorded but not enacted:** the permissions boundary; IMDSv2 enforcement
(`modify-instance-metadata-options` is `UnsupportedOperation` outright on
this build, not silently dropped); the revoked rules (Finding 1).

**Conceptual only:** every claim about real-AWS enforcement of any of the
above — Floci authorises no API call and carries no traffic for a security
group to filter, exactly as Section 11 states.

## A genuine deviation from the guide's assumed state: `usms-dev-01` had zero IAM-registered access keys

Step 10 expects exactly one pre-existing key to rotate. `list-access-keys`
showed zero. Investigation: the locally-configured `~/.aws/credentials`
profile held a key pair that authenticated successfully (Floci accepts any
credentials, per Section 11) but had never actually been created via `aws iam
create-access-key` — confirmed decisively when `update-access-key` on that
key ID returned `NoSuchEntity`. Handled by creating the first genuinely
IAM-registered key and moving the profile onto it; the four-step
create→move→deactivate→delete sequence correctly collapses to
create→move when there is no real key to deactivate or delete.

## Verification

`scripts/utilities/verify-lab-09.sh`: **PASS=43 FAIL=0 DOCUMENTED_FAIL=6** —
every genuine check passes; the six documented failures are the permissions
boundary, IMDSv2, and the three un-revoked allow-all egress rules plus the
un-revoked SSH CIDR, all investigated above, none a gap in this lab's own
work.
