# Lab 09 notes

## Support path

**Path A — full.** Every Step 3 probe answered `SUPPORTED`, including the two
that most builds lack: `iam simulate-principal-policy` returned genuine,
resource-scoped evaluation (`implicitDeny` for an action a role's policy never
granted, `allowed` for one it did, confirmed against `usms-ecs-task-role`'s
real `USMSStudentDataReadWrite` policy), and `sts assume-role --policy` (a
session policy) was accepted and genuinely narrowed the session (Step 9).
Only `accessanalyzer list-analyzers`, `iam get-credential-report` and `iam
get-account-authorization-details` are absent — none of which gate any step
in this lab. Two initial "not available" readings (`iam get-role`, `iam
list-attached-role-policies`) were false negatives from my own mistake, not
genuine gaps: this repo's `configs/lab-01.env` stores `USMS_ROLE_EC2` etc. as
full ARNs, and `--role-name` rejects an ARN — the bare name
(`${USMS_ROLE_EC2##*/}`) resolved them correctly.

`usms-student-data` did not exist when Step 6 ran (`head-bucket` returned
404/`NoSuchBucket`), exactly as the guide anticipates for a build that has not
yet reached Lab 10.

## A naming-convention mismatch worth stating once

This repo's own established env-var names differ from the ones this guide
assumes, because Labs 02/04/05 were built with a slightly different
convention than this later-arriving document expects:

| Guide assumes | This repo actually has |
|---|---|
| `USMS_APP_SG` | `USMS_APP_SG_ID` |
| `USMS_DB_SG` | `USMS_DB_SG_ID` |
| `USMS_S3_ENDPOINT` | `USMS_S3_ENDPOINT_ID` |
| `USMS_PRIVATE_NACL` | `USMS_PRIVATE_NACL_ID` |

Every command in this lab was run with the actual names above substituted in;
`verify-lab-09.sh` uses them too. `USMS_ECS_TASK_ROLE`, `USMS_ALB_SG`,
`USMS_ENROLMENT_SG`, `USMS_WEB_INSTANCE`, `USMS_DB_INSTANCE` and
`USMS_ROLE_DEVELOPER` all matched the guide's own names (the role variables
hold full ARNs rather than bare names, which also needed adapting — see
above).

## Step 4 "Your turn" — the two trust policies, side by side

`usms-developer-role`'s trust policy names `Principal.AWS:
arn:aws:iam::000000000000:user/usms-dev-01` — an AWS identity. Only that one
named IAM user, authenticating with their own long-lived credentials, can ever
call `sts:AssumeRole` against it; obtaining those credentials requires
compromising `usms-dev-01` specifically (their access key, or whatever signs
in as them). `usms-ec2-app-role`'s trust policy names `Principal.Service:
ec2.amazonaws.com` — a service, not an identity. Any EC2 instance in the
account that carries the matching instance profile is handed temporary
credentials for this role automatically by the platform itself, with no
credential ever typed or stored by a human; obtaining them means compromising
*any* process running on *any* instance wearing that profile, a far larger
and less personal attack surface than a single named user's key.

## Step 6 "Your turn" — two action lists, one action apart

The enrolment API, to display a transcript, needs exactly:
`s3:ListBucket` (so a missing key returns a clean 404 rather than an
ambiguous empty response) and `s3:GetObject`. The registry's upload workflow,
to store one, needs those same two actions plus `s3:PutObject` — the one
action that appears in the second list and not the first. `s3:DeleteObject`
appears in neither list; nothing in this architecture's described workflow
ever deletes a transcript, which is exactly why `USMSStudentDataReadWrite`
granting it to `usms-ec2-app-role` was itself worth noting as a finding, not
because anything exploits it on this build, but because it is a verb neither
real consumer uses.

## Step 11 "Your turn" — usms-db-01's metadata options

`usms-db-01` has no instance profile at all (Lab 03 Step 16 left it that way
deliberately), so there is nothing an SSRF bug could steal from its metadata
service even with IMDSv1 wide open — the stronger setting available to it
that is not available to `usms-web-01` is `--http-endpoint disabled`,
switching the metadata service off entirely rather than merely requiring a
token to reach it. Attempted via `aws ec2 modify-instance-metadata-options
--instance-id $USMS_DB_INSTANCE --http-endpoint disabled`; failed with the
same `UnsupportedOperation` as every other call to this operation on this
build (see Findings below), so this is recorded as the conceptually-correct
answer rather than an observed one. What would break if `usms-web-01` got the
same stronger setting: its own instance profile credentials would become
unreachable to the application that legitimately needs them (the enrolment
health check or any AWS SDK call the web tier itself makes), which is exactly
why `usms-web-01` gets `required` tokens rather than a disabled endpoint — it
has a role to protect, not none to deny access to.

## Findings

### 1. Genuine Path A: `simulate-principal-policy` performs real, resource-scoped policy evaluation

Confirmed with two independent tests: `s3:GetObject` against
`usms-ec2-app-role` (which does not carry a grant for it) returned
`implicitDeny`; the identical action against `usms-ecs-task-role`'s real
`USMSStudentDataReadWrite`-granted ARN returned `allowed`. This is the
strongest IAM-evaluation capability found anywhere in this course so far —
stronger than the guide's own "typical" expectation (Path B, no simulation).
One sub-gap: `MatchedStatements` is always empty even on an `allowed`
decision, so the *which statement matched* half of the feature is not
implemented, only the yes/no decision.

### 2. Permissions boundaries are accepted but never persisted

`aws iam create-role --permissions-boundary <arn>` and a subsequent
`put-role-permissions-boundary` both return success with no error, but
`get-role --query Role.PermissionsBoundary` reads back `null` every time.
Matches the guide's own documented "known benign failure" exactly.

### 3. A new, severe finding: `revoke-security-group-egress` and `revoke-security-group-ingress` are complete no-ops on this build

Both calls always return `Return: true` and never remove the targeted rule,
confirmed independently four times: the enrolment-sg default egress rule (via
an `--ip-permissions` document match, then again via precise
`--security-group-rule-ids`), the ALB-sg default egress rule, the DB-sg
default egress rule, and the app-sg's old `10.0.0.0/16` SSH ingress rule. In
every case the *authorize* half of the authorize-then-revoke cutover
succeeded genuinely (the new, correct rule is present and real), but the old
rule is never actually removed — meaning the account ends every "narrow this
rule" step in this lab with BOTH the new restriction and the old exposure
simultaneously present, rather than just the new one.

This is a different, more severe category than anything found before it in
this course: not `UnknownOperationException` (unrecognised), not
`UnsupportedOperation` (named but unimplemented, and honestly reported as an
error), not a silent accept-then-drop-one-field (grace periods, boundaries).
Here the call reports unambiguous success while doing nothing at all.

A second, compounding discovery: `describe-security-groups`'s
`IpPermissionsEgress` field **silently omits** the stale `-1` rule from its
response entirely on at least one group (`usms-enrolment-sg`), while the
granular `describe-security-group-rules` API correctly lists it. This means
the guide's own prescribed verification method (`length(IpPermissionsEgress[?
IpProtocol=='-1'])` via `describe-security-groups`) would give a **false
pass** on this build — it would report `0` even though the rule is still
genuinely there. `verify-lab-09.sh` and `usms-sg-audit.sh` were both built to
query the granular, accurate API instead, and both still report the rule
honestly as present (marked `FAIL(documented)` rather than hidden).

### 4. `Instances[].PublicIpAddress` is a non-functional placeholder; `describe-addresses --filters` does not filter

`describe-instances`'s top-level `PublicIpAddress` field returns the literal
string `127.0.0.1` for *every* instance on this build, including
`usms-web-01` (which has a real, genuinely-associated Elastic IP,
`54.96.140.123`, confirmed via `describe-addresses`) and `usms-db-01` (which
has none) — making the field useless for Step 17's negative-proof control 1
exactly as the guide's own example output specifies it. Worse,
`describe-addresses --filters Name=instance-id,Values=<id>` does not actually
filter: it returns every allocated address in the account regardless of the
filter given. The only reliable method found: fetch the unfiltered list and
match `InstanceId` client-side (`Addresses[?InstanceId=='<id>']`), which
correctly returns an empty list for `usms-db-01` and the real address for
`usms-web-01`. `verify-lab-09.sh`'s negative-proof check uses this corrected
method.

### 5. The pre-existing group-reference persistence gap (Labs 02/04/05) recurs throughout this lab

Every new rule in this lab that names another security group as its source or
destination (`usms-alb-sg`'s new egress → `usms-enrolment-sg`, `usms-app-sg`'s
new SSH ingress → `usms-bastion-sg`) reads back with `UserIdGroupPairs: []` —
the reference is accepted at write time but not retained. This is the same
root cause documented in Lab 05's report, now confirmed independently across
two more rule types in Lab 09, and it is why `usms-sg-audit.sh`'s and
`usms-reachability-matrix.sh`'s own output shows these rules as sourceless
(`<none>` / absent from the matrix) rather than correctly attributed.

### 6. A Windows/Git-Bash finding distinct from the earlier MSYS path-mangling bugs

A path embedded **inside** a `python -c "..."` string is never touched by
MSYS's automatic argv path-conversion (that conversion only rewrites
standalone argv tokens), so a plain, non-MSYS-aware `python.exe` resolves a
POSIX-style `/tmp/...` path using its own Windows semantics — as
`C:\tmp\...`, a directory that does not exist — and fails with
`FileNotFoundError`, deterministically, every time. Passing the same path as
its own argv argument (`sys.argv[1]`) instead lets MSYS's conversion do its
job correctly. This is the *opposite* failure mode from the earlier
`MSYS_NO_PATHCONV` bugs (Labs 05/07/08), where unwanted conversion had to be
suppressed; here, wanted conversion simply never triggers. Fixed in
`usms-sg-audit.sh` by passing the temp-file path as an argument rather than
interpolating it into the Python source string.

## Review questions

**1. Step 18 proved five pre-existing verification scripts report exactly
what they did before. Why is that strong, what plausible Lab 09 change would
have broken one, and what would you have done?** It is strong because none of
those five scripts were written with this lab in mind — they assert
properties of Labs 02–06's own resources, so an unchanged result is evidence
that this review genuinely touched only identity and network *configuration*,
not application behaviour, state, or resource existence. A plausible break:
if Step 13's enrolment-sg egress rewrite had been written too narrowly (say,
omitting the CloudWatch Logs destination entirely rather than leaving a broad
443 rule), nothing in *this* lab's own checks would catch it — Floci carries
no traffic — but `verify-lab-04.sh`'s existence/configuration checks on the
task definition's `awslogs` driver would still pass regardless, because
Floci's security groups don't enforce anything either direction; the actual
break that WOULD show up is more subtle: if Step 7's `update-assume-role-policy`
call had been malformed enough to leave the ECS task role's trust policy
rejecting `ecs-tasks.amazonaws.com` entirely (a typo in the principal, say), a
real-AWS system would stop launching new tasks and `verify-lab-04.sh`'s
service-ACTIVE check would eventually fail. On Floci, which doesn't enforce
trust policies either, it would not — which is itself the honest limitation
this course keeps returning to: on this build, only reading the document
(Step 7's own before/after JSON diff) proves the change was correct, not a
downstream functional check.

**2. A colleague attaches `USMSPermissionsBoundary` to `usms-deploy-role` with
`attach-role-policy`, reasoning it allows the same actions. What changes, in
both directions, and when does it become dangerous?** Attaching it as an
ordinary identity policy ADDS its Allow statement's actions
(`ec2:Describe*`, `ecs:*`, etc., listed in its first statement) to whatever
`usms-deploy-role` already has from `USMSDeployBase` — a boundary's Allow
block is not a magic "no-op" grant, it is an ordinary Allow block the moment
it's attached as a policy rather than referenced as a boundary. It does NOT
remove the Deny statements' effect (an explicit Deny is unconditional
regardless of which slot a document is attached from), so
`NoIdentityChangesUnderAnyCircumstances` still blocks `iam:CreateUser` etc.
either way. It becomes dangerous specifically if someone later attaches a
*different*, broader identity policy to the same role expecting the boundary
to still cap it — the boundary is no longer sitting in the boundary slot
doing any capping at all, it is just one more identity policy among several,
and the role's effective permissions become the union of everything attached,
not the intersection the designer intended. `verify-lab-09.sh`'s own
`"the boundary is attached to NOTHING as an ordinary policy"` check, reading
`AttachmentCount` from `list-policies`, is exactly the catch for this.

**3. An incident where every ingress rule is correct and the outcome is still
a data breach.** A compromised dependency inside an enrolment task (a
poisoned npm package in the application image, say) exfiltrates transcript
data over HTTPS to an attacker-controlled domain — no ingress rule is
involved at all, because the attacker never connects inward; the task
initiates the connection outward, and Step 13's actual egress rule
(`tcp/443 to 0.0.0.0/0`, kept broad specifically because the registry pull and
the awslogs driver both need unpredictable destinations) does not distinguish
that traffic from a legitimate container pull. Steps 13–15 narrow this only
by protocol and port, not narrowed at all by how much: Step 13 would have
narrowed it from "anything" to "only 443", which stops a huge class of other
exfiltration channels (DNS tunnelling, a raw TCP port, SMTP) but does nothing
to an HTTPS POST specifically, which the rule's own comment admits
(`"HTTPS out ... - narrow this to interface endpoints on real AWS"`). What
would have prevented it entirely is hostname-aware egress filtering — AWS
Network Firewall with a domain allow-list, or an explicit HTTPS proxy — which
this course cannot build because Floci models security groups and NACLs as
objects but carries no actual traffic for either to filter, so there is
nothing for a firewall rule to be tested against even if one were configured.

**4. Three roles, three trust shapes — what happens if `sts:AssumeRole` is
callable from an attacker's own machine, and why do the answers differ?**
`usms-ecs-task-role` and `usms-transcripts-reader-role` share the identical
scoped trust policy (`ecs-tasks.amazonaws.com`, conditioned on
`aws:SourceAccount`/`aws:SourceArn`) but carry different permissions
(`USMSStudentDataReadWrite` vs `USMSStudentDataReadOnly`) — an attacker who
could somehow call `sts:AssumeRole` directly from their own machine (not
through ECS) would be refused by the condition on *either* role, on real AWS,
because neither `aws:SourceAccount` nor `aws:SourceArn` would match an
external caller; the two roles differ only in what the attacker would gain
*if* the condition were somehow satisfied (read-write vs read-only transcript
access), not in whether the attack described even reaches that question.
`usms-deploy-role`'s trust names a specific IAM user
(`arn:...user/usms-admin-01`), which is a fundamentally different defence: it
isn't a *service*-trust condition at all, so there is no `SourceAccount`/
`SourceArn` to misconfigure, but it is also not proof against credential theft
— if the attacker's "own machine" means they have stolen `usms-admin-01`'s own
long-lived credentials, this trust policy grants them `usms-deploy-role`
immediately and the permissions boundary is the only thing left standing
between them and `USMSDeployBase`'s full grant. The answers differ because
the first two defend against a confused-deputy misuse of a *legitimate*
service, while the third defends against nothing but impersonation of a
specific named identity — it assumes the user's own credentials are the
perimeter, which is exactly the gap Exercise 2's MFA-and-ExternalId
break-glass role is designed to close.

**5. Why is "five controls" on `usms-db-01` not simply five times better than
"one control" on `usms-enrolment-sg`, and are the enrolment tasks genuinely
less protected?** The five controls on `usms-db-01` are independent across
*different layers* of the stack (public addressing, subnet auto-assignment,
routing, security group, NACL) — each one failing is a different kind of
operator mistake, in a different API, often made by a different person at a
different time, so the *conjunction* of all five failing simultaneously by
accident is genuinely much less likely than any one of them failing alone.
`usms-enrolment-sg`'s "one control" is a single security-group rule, but
Step 17 says explicitly it models only one axis — the enrolment tasks also
sit in a private subnet with no public address and no route to an internet
gateway, which are exactly controls 1–3 from the `usms-db-01` list, just not
restated because the matrix tool doesn't compute them. So the tasks are not
nearly as under-protected as "one control" suggests; what is genuinely true,
and worth stating precisely rather than softening, is that the *security
group layer specifically* — the layer this course's tooling can actually
audit mechanically — has only one rule standing between `usms-alb-sg` and the
tasks, where the data tier has a second, independent security-group-level
control (no CIDR source permitted at all) layered on top of the same shared
network-level protections.

**6. What do the two extra rotation steps in Step 10 protect against, and
why is a long-lived key a compromise?** Deactivating before deleting protects
against an incomplete cutover: if some forgotten consumer still used the old
key (a script, a CI job, a second laptop), deactivation breaks it in a way
that is instantly, safely reversible (`update-access-key --status Active`)
the moment someone notices, where deletion of a key still in silent use would
be discovered only when that unknown consumer fails, possibly much later and
with no easy path back since AWS never re-issues a deleted key's secret.
Creating the replacement before moving any consumer over is what makes the
whole rotation zero-downtime: at every single moment, at least one valid key
exists, so no window exists in which the profile has no working credential at
all. A long-lived key is a compromise because its blast radius is unbounded in
time — if it leaks today and nobody rotates it, it remains valid until
someone notices, which could be months; a human would be better served by
IAM Identity Center or federated SSO issuing short-lived credentials per
session, and a workload (as every other principal in this entire course
already demonstrates) by an IAM role with no stored credential at all, just
temporary ones minted per instance or per task.

**7. Is Section 11's review-by-reading methodology an adequate substitute for
testing?** Not a substitute — a different, complementary proof for a
different class of claim. A defect reading catches that testing would not:
Step 8's `iam:PassRole` scoping to three named ARNs is provably safe against
every input, including ones nobody has thought to test yet, because the
document itself is the complete specification of what it permits; no finite
set of test calls could establish that absence as confidently as reading the
`Resource` array once. A defect testing catches that reading would not: this
lab's own headline finding — that `revoke-security-group-egress` silently
does nothing — is invisible to a document review entirely, because the
*document* describing the intended rule change (`policies/usms-*-egress.json`,
the authorize call, the revoke call) is completely correct; only running the
commands and reading the state back afterward revealed the gap between intent
and reality. For student transcripts specifically, I would want the document
review first and treat it as necessary but not sufficient — a correct policy
document is a precondition for anything else being meaningful, but this
lab's own revoke-no-op finding is the concrete proof that a correct
*intention*, faithfully executed, can still fail silently in a way only
observation catches.
