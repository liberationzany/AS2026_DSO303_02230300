# AWS Practical Laboratory Report — Lab 01: Identity and Access Management (IAM)

## 1. Aim / Objective

To create and manage IAM users, groups, roles, and policies for the University Student
Management System (USMS) using the AWS CLI against a local AWS emulator (Floci), and to
verify identity, isolation, persistence, and access permissions throughout.

## 2. Introduction

AWS Identity and Access Management (IAM) is a global AWS service that controls
authentication ("who are you?") and authorization ("what are you allowed to do?") for
every other AWS service. IAM has no regional scope — a user, group, role, or policy
created in IAM is visible and effective account-wide.

**Key features used in this practical:**
- Users — permanent identities with long-lived credentials
- Groups — containers that apply policies to every member at once
- Roles — identities with no permanent credentials, assumed to obtain short-lived
  (1-hour) temporary credentials via AWS STS
- Policies — JSON documents that ALLOW or DENY specific API actions on specific
  resource ARNs, attached as AWS-managed, customer-managed, or inline
- Policy versioning — up to 5 versions per customer-managed policy, with one active
  ("default") version at a time

IAM costs nothing extra to use and is considered the foundational security layer of
every AWS account — nothing else in AWS can be protected until identity is set up
correctly.

## 3. Use Case

USMS employs administrators, developers, and auditors, each needing different access:

| Group | Purpose |
|---|---|
| `usms-admins` | Full developer permissions + role assumption |
| `usms-developers` | Build VPC networking (Lab 2), read infrastructure, cannot touch identity |
| `usms-auditors` | Read-only access across the account, cannot change anything |

Rather than granting permissions to each person individually, every permission in this
lab is attached to a **group**, and users are placed into the group matching their job
function — the standard real-world pattern for managing access at scale, and the
pattern this whole lab is built to demonstrate.

## 4. System Architecture / Design

```
                         AWS Account (000000000000)
                                    │
                 ┌──────────────────┼──────────────────┐
                 │                  │                   │
            usms-admins      usms-developers      usms-auditors
           (USMSDeveloperBase (USMSDeveloperBase    (ReadOnlyAccess)
            USMSAssumeAppRoles) USMSAssumeAppRoles)
                 │                  │                   │
           usms-admin-01       usms-dev-01         usms-audit-01
                              (+ inline policy:
                            USMSSelfManageCredentials)
                                    │
                          sts:AssumeRole (1hr, ASIA...)
                                    ▼
                          usms-developer-role
                         (USMSDeveloperBase)

  Service-trusted roles (assumed by AWS services, not people):

  ec2.amazonaws.com ──assumes──> usms-ec2-app-role ──> USMSStudentDataReadWrite
        (via usms-ec2-app-profile, the instance-profile wrapper)

  lambda.amazonaws.com ──assumes──> usms-lambda-exec-role ──> USMSLambdaBasic
```

Data flow: a human authenticates as an IAM user (permanent credentials) → is placed in
a group (permissions by job function) → may temporarily assume an elevated role via STS
(temporary credentials, auto-expiring) to perform build tasks. Separately, AWS services
(EC2, Lambda) assume their own service roles directly — no human credentials are ever
embedded in server or function code.

## 5. Implementation Procedure

All work was performed against **Floci**, a local Docker-based AWS emulator, so every
step below is real AWS CLI usage with zero cost and zero risk to a real account
(verified — Account ID `000000000000`, never `amazonaws.com`).

1. **Environment (Part A):** Installed and pinned Floci via `docker-compose.yml` with
   `FLOCI_STORAGE_MODE=hybrid` and an absolute host bind mount (`~/floci-data`), because
   `floci start --persist` alone does **not** enable durable storage. Wrote
   `floci-up.sh`/`floci-down.sh` to manage the container safely, `whoami.sh` to print
   the active identity, and proved persistence by creating an IAM user, fully
   restarting the container, and confirming the user survived.
2. **Groups:** Created `usms-admins`, `usms-developers`, `usms-auditors`.
3. **Users:** Created `usms-admin-01`, `usms-dev-01`, `usms-audit-01`, each tagged with
   `Project=USMS` and a `Role` tag, and captured their ARNs into shell variables rather
   than copying by hand.
4. **Memberships:** Added each user to its matching group; verified from both
   directions (`get-group` and `list-groups-for-user`).
5. **Read-only access:** Attached the AWS-managed `ReadOnlyAccess` policy to
   `usms-auditors` (Floci's build shipped this policy, so the customer-managed
   fallback described in the lab guide was not needed).
6. **Customer-managed policy (`USMSDeveloperBase`):** Wrote a three-statement policy —
   broad read access, narrowly-scoped VPC-build permissions restricted to
   `us-east-1`, and an explicit `Deny` on identity-escalation actions (creating users,
   creating access keys, attaching policies to users) so that even an accidental
   over-grant elsewhere could never let a developer make themselves an admin. Attached
   to both `usms-developers` and `usms-admins`.
7. **S3 policy (`USMSStudentDataReadWrite`):** Wrote a policy with separate statements
   for the *bucket* ARN (`s3:ListBucket`) and the *object* ARN (`s3:GetObject`/
   `PutObject`/`DeleteObject`) — the single most common S3 policy mistake is
   conflating these two ARNs.
8. **`--generate-cli-skeleton`:** Used to discover every parameter `create-role`
   accepts without contacting Floci at all.
9. **Inline policy:** Attached `USMSSelfManageCredentials` directly to `usms-dev-01`
   using the `${aws:username}` policy variable, so the one document scopes correctly
   to whichever user it's attached to. Used a *quoted* heredoc (`<< 'EOF'`) so the
   shell did not expand the variable before it reached the policy file.
10. **Inspection:** Queried every angle of `usms-dev-01`'s effective permissions
    (group policies, attached policies, inline policies, access keys) and captured a
    full account snapshot to `outputs/lab-01-iam-snapshot.json` (git-ignored).
11. **Policy versioning:** Added two more allowed actions to `USMSDeveloperBase` via a
    new policy version (`v2`), set as the default, without editing the original in
    place — v1 remains available for rollback.
12. **Service roles:** Created `usms-ec2-app-role` (trusted by `ec2.amazonaws.com`,
    wrapped in an instance profile) and `usms-lambda-exec-role` (trusted by
    `lambda.amazonaws.com`, with its own log-writing + S3-read policy).
13. **Human-assumable role + STS:** Created `usms-developer-role`, trusted by
    `usms-dev-01` specifically, and a separate `USMSAssumeAppRoles` policy granting
    the *permission* to call `sts:AssumeRole` on it — the "two-sided handshake"
    required for role assumption. Assumed the role, obtained temporary `ASIA...`
    credentials with a session token and 1-hour expiry, used them for one API call,
    then explicitly reverted to the root identity.
14. **Access keys:** Created a real (Floci-dummy) access key pair for `usms-dev-01`,
    redirected straight to a `chmod 600` file so the secret never touched the
    terminal, and confirmed three ways that Git would never commit it.
15. **Policy simulation:** Ran `simulate-principal-policy` to test three actions
    against `usms-dev-01` without actually performing them.
16. **Lab state saved:** Wrote `configs/lab-01.env` with every resource ARN (no
    secrets), archived `~/floci-data` as a fallback snapshot, wrote this report, and
    committed everything with `.gitignore` as the very first commit in the repo's
    history — proof no secret could ever have been committed.
17. **End-to-end verification:** Wrote and ran `verify-lab-01.sh`, a 34-point
    automated check covering environment health, persistence configuration, every
    group/user/policy/role, and Git hygiene.

## 6. Results and Evidence

### 6.1 CLI Output

**Identity check — proves Floci, not real AWS:**
```
$ aws sts get-caller-identity --profile floci
{
    "UserId": "000000000000",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

**Groups created:**
```
$ aws iam list-groups --query 'Groups[*].[GroupName,Arn]' --output table
------------------------------------------------------------------------
|                              ListGroups                              |
+------------------+---------------------------------------------------+
|  usms-developers |  arn:aws:iam::000000000000:group/usms-developers  |
|  usms-auditors   |  arn:aws:iam::000000000000:group/usms-auditors    |
|  usms-admins     |  arn:aws:iam::000000000000:group/usms-admins      |
+------------------+---------------------------------------------------+
```

**STS assume-role — temporary credentials (secret truncated):**
```
$ aws sts assume-role --role-arn arn:aws:iam::000000000000:role/usms-developer-role \
    --role-session-name usms-dev-01-lab01 --duration-seconds 3600
{
    "Credentials": {
        "AccessKeyId": "ASIAOTQBM2JQO00TLCXG",
        "SecretAccessKey": "***redacted***",
        "SessionToken": "***redacted, 200+ chars***",
        "Expiration": "2026-08-23T16:57:11+00:00"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "AROAKN1OIWXFQXFSJYE9:usms-dev-01-lab01",
        "Arn": "arn:aws:sts::000000000000:assumed-role/usms-developer-role/usms-dev-01-lab01"
    }
}
```
Note the access key begins `ASIA` (temporary), not `AKIA` (permanent) — visible proof
these credentials expire on their own.

**End-to-end verification (34/34 passing):**
```
$ ./scripts/utilities/verify-lab-01.sh
== Environment ==
 ✓ Docker daemon reachable
 ✓ Compose v2 present
 ✓ Floci container running
 ✓ Container owned by Compose
 ✓ Health endpoint responds
 ✓ AWS CLI reaches Floci
 ✓ Account is 000000000000
== Persistence configuration ==
 ✓ Storage mode is NOT memory
 ✓ /app/data is a host bind mount
 ✓ state directory is non-empty
== Groups ==            (3/3)   == Users ==             (3/3)
== Memberships ==       (1/1)   == Policies ==          (6/6)
== Roles ==              (4/4)  == Files and Git hygiene == (7/7)

PASS=34 FAIL=0
```

*Insert your own terminal screenshots of the above commands here for submission —
these are the actual captured outputs from the session, reproduced as text.*

### 6.2 Console Verification

Floci is a CLI-only emulator with **no AWS Management Console** to screenshot. In its
place, the equivalent verification was performed entirely through the CLI's own
read/inspect operations, which serve the same evidentiary purpose:

| Console page (real AWS) | CLI substitute used here |
|---|---|
| IAM → Users | `aws iam list-users`, `get-user` |
| IAM → User groups | `aws iam list-groups`, `get-group` |
| IAM → Roles | `aws iam list-roles`, `get-role` |
| IAM → Policies | `aws iam list-policies --scope Local`, `get-policy-version` |
| Account authorization report | Reconstructed manually into
  `outputs/lab-01-iam-snapshot.json` (`get-account-authorization-details` is
  `UnsupportedOperation` on this Floci build) |

*Insert a screenshot of `docker compose ps` / `floci status` here if your submission
requires visual proof of the running emulator.*

## 7. Analysis and Discussion

All 34 automated checks in `verify-lab-01.sh` passed, and every guide checkpoint
(Steps 17–33) was independently confirmed against real command output rather than
assumed from success codes alone. The IAM structure enforces least privilege as
designed: `usms-auditors` can read but not write, `usms-developers` can build the
specific VPC resources Lab 2 needs but is explicitly denied identity-escalation
actions even if a broader policy were mistakenly added later, and both service roles
(`usms-ec2-app-role`, `usms-lambda-exec-role`) hold only the permissions their
respective AWS service actually needs.

Several results diverged from the guide's literal expected output, all attributable to
this specific Floci build rather than to configuration errors:

- `aws iam get-account-authorization-details` returned `UnsupportedOperation`. Worked
  around by reconstructing an equivalent snapshot from individual `list-*`/`get-*`
  calls.
- `floci snapshot save` returned "Snapshot API not available on this server version."
  Used the guide's documented fallback instead: stop Floci, `tar` the state
  directory, restart.
- `simulate-principal-policy` returned `implicitDeny` for `ec2:CreateVpc` on
  `usms-dev-01`, even though that action is genuinely granted via the
  `usms-developers` group's `USMSDeveloperBase` policy — the simulator on this build
  appears not to evaluate group-attached policies, only user-attached ones. This
  matches the guide's own documented warning that the simulator may return a
  simplified result on Floci.
- A container named `floci`, left over from an earlier manual `floci start` (not
  Compose), blocked the very first `floci-up.sh` run in Part A. Diagnosed via the
  script's own ownership check and resolved with `docker rm -f floci`, exactly the
  fix the script suggests.

None of these required changing the actual IAM design — only the verification method
for a small number of steps.

## 8. Reflection

**1. What did you learn about this AWS service?**
IAM's real complexity is not in any single command but in how users, groups, roles,
and three different policy-attachment types (managed, customer-managed, inline)
combine to produce one *effective* permission set — and that auditing permissions
correctly means checking every one of those layers, not just one.

**2. What challenges did you encounter?**
The two-sided trust/permission handshake for role assumption was the trickiest
concept: a role's trust policy and the caller's own `sts:AssumeRole` permission are
two independent documents, and missing either produces the same generic
`AccessDenied`. Separately, several Floci emulator gaps (listed in Section 7) required
finding CLI-only workarounds rather than relying on the guide's literal expected
output.

**3. How would you apply this service in a real-world cloud environment?**
Exactly as built here: group-based permissions instead of per-user grants, roles
(not embedded access keys) for anything a server or function does automatically, an
explicit `Deny` guardrail against privilege escalation, and access keys treated as
sensitive from the moment they're created — redirected straight to a file, never
displayed, and verified to be excluded from version control.

**4. What additional concepts or features would you like to explore?**
Permission boundaries, Service Control Policies (SCPs) for multi-account
organizations, IAM Identity Center for federated human access, and how policy
evaluation changes once a real `AccessDenied` is actually enforced rather than
theoretical (Floci accepts any non-empty credentials and does not enforce IAM
authorization by default).

## 9. Conclusion

This practical's objectives were fully achieved: a complete IAM foundation for USMS —
3 groups, 3 tagged users, 4 customer-managed policies (one versioned to v2), 1 inline
policy, 3 roles, 1 instance profile — was built entirely via the AWS CLI, verified by
a 34-point automated script, and committed to version control with proof (a
`.gitignore` first commit, plus a live secret-blocking test) that no credential could
ever have leaked into Git. This lab reinforced that IAM is the foundation every other
AWS service depends on for security, and that "it worked" is not evidence — only a
command's actual output, checked directly, is.

## 10. Appendix

**Reproduce this lab:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
./scripts/utilities/verify-lab-01.sh
```

**Supplementary files (all in this repository):**
- Policy documents: [`policies/`](../../policies/) — `usms-developer-base-policy.json`
  (+ `-v2.json`), `usms-student-data-rw-policy.json`,
  `usms-self-manage-credentials.json`, `usms-assume-app-roles-policy.json`,
  `usms-lambda-basic-policy.json`, `trust-ec2.json`, `trust-lambda.json`,
  `trust-account-developers.json`
- Scripts: [`scripts/setup/`](../../scripts/setup/), [`scripts/utilities/`](../../scripts/utilities/),
  [`scripts/cleanup/`](../../scripts/cleanup/)
- Environment config: [`configs/course.env`](../../configs/course.env),
  [`configs/lab-01.env`](../../configs/lab-01.env)
- Storage-mode notes: [`notes/lab-01-notes.md`](../../notes/lab-01-notes.md)
- `docker-compose.yml` (repo root)

---

### Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture included
- [x] All implementation steps documented
- [ ] CLI/SDK screenshots included — *text evidence included above; paste your own
  terminal screenshots before submitting*
- [x] Console verification — *N/A for Floci; CLI-substitute table provided*
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached

---

## Problems I hit and how I fixed them

- `sudo apt-get`/`sudo` hung indefinitely when run non-interactively (no TTY to
  supply a password to) — avoided sudo entirely; `jq` was already present on this
  system, so no install was needed.
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
