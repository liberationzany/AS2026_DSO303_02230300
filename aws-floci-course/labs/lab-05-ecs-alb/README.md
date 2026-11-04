# AWS Practical Laboratory Report — Lab 05: ECS Behind an Application Load Balancer

## 1. Aim / Objective

To give the USMS enrolment service a stable, internet-facing front door — an
Application Load Balancer, a target group, a listener with a health-check rule — and
to migrate the web tier's access to the enrolment API from a direct security-group
reference to the load balancer, proving the cutover with the old path still present
until the new one is verified, using the AWS CLI against Floci.

## 2. Introduction

Lab 04 left `usms-enrolment-svc` correct but unreachable by name: its two Fargate
tasks have private addresses that change every time a task starts or stops, so
nothing durable could ever be written down as "the enrolment API's address." Elastic
Load Balancing solves this with four objects — a **load balancer** (the DNS name), a
**listener** (one port, one default action), a **rule** (a condition plus an action,
evaluated before the default), and a **target group** (the set of targets plus the
health check that decides which of them are eligible). Crucially, the health check
lives on the target group, not the load balancer or the listener — the single most
common point of confusion this lab is built to prevent.

**Key features used in this practical:**
- An internet-facing Application Load Balancer across two public-subnet Availability
  Zones (a hard API requirement, not a recommendation)
- A target group with `--target-type ip` — the only value a Fargate task can use,
  since an `awsvpc` task has no EC2 instance ID
- A target-group health check, distinct from and independently readable against Lab
  04's container health check
- A listener's single default action, plus a priority-ordered rule for a dedicated
  health-check path
- Attaching an *existing* ECS service to a target group rather than creating a new
  service — the service itself then registers and deregisters every task automatically
- A deliberate, order-sensitive security cutover: add the new path, prove it, then
  remove the old one

## 3. Use Case

| Object | Value |
|---|---|
| `usms-alb-sg` | security group: tcp/80 from `0.0.0.0/0` — the only such rule in this repository |
| `usms-enrolment-alb` | internet-facing ALB, public subnets A and B |
| `usms-enrolment-tg` | target group, `ip`, HTTP/80, health check `GET /`, matcher 200 |
| `usms-enrolment-listener` | HTTP:80, default action forwards to the target group |
| health-check rule | priority 10, path `/alb-health`, fixed-response 200 |
| `usms-enrolment-sg` (updated) | tcp/80 from `usms-alb-sg` only — the direct `usms-app-sg` rule from Lab 04 is removed |
| `usms-enrolment-svc` (recreated) | now carries a `loadBalancers` entry pointing at the target group |

## 4. System Architecture / Design

```
                               Internet
                                   |
                   http://<usms-enrolment-alb DNS name>/
                                   |
                                   v
                            usms-igw
                                   |
======================================================================
|| usms-vpc 10.0.0.0/16                                              ||
||  usms-public-rt  0.0.0.0/0 -> usms-igw                            ||
||  +---------------------------+   +---------------------------+   ||
||  | usms-public-subnet-a       |   | usms-public-subnet-b      |   ||
||  | [ALB node] usms-alb-sg     |   | [ALB node] usms-alb-sg    |   ||
||  | [usms-web-01] usms-app-sg  |   |                            |   ||
||  +---------------------------+   +---------------------------+   ||
||       |                               |                           ||
||       +---------- usms-enrolment-alb (internet-facing, application)
||                          |
||                    listener HTTP:80
||                       |-- rule priority 10: path /alb-health -> fixed-response 200
||                       |-- DEFAULT ACTION -> forward
||                          |
||                    usms-enrolment-tg  (target-type ip, health check GET /)
||                          |
||       tcp/80, source = usms-alb-sg  (ONLY rule now — Step 13 cutover)
||                          |
||  +---------------------------+   +---------------------------+   ||
||  | usms-private-subnet-a      |   | usms-private-subnet-b     |   ||
||  | [task 1] usms-enrolment-sg |   | [task 2] usms-enrolment-sg|   ||
||  +---------------------------+   +---------------------------+   ||
||                                                                    ||
||  ECS: usms-enrolment-svc  loadBalancers[0] -> usms-enrolment-tg   ||
||       >>> the SERVICE registers/deregisters the targets <<<      ||
======================================================================
```

## 5. Implementation Procedure

All work was performed against **Floci** (Account ID `000000000000`), continuing
directly from Labs 01–04.

0. **Source material note:** the course guide PDF for this lab is genuinely
   truncated at the source (confirmed by opening the PDF directly — it ends on page
   76 of 77, mid-command, inside Step 11; page 77 contains only a page footer).
   Everything through Step 11's target-health check is faithfully reproduced from the
   guide; the cutover (Step 13), the env file, the verify/cleanup scripts, and the
   review questions were built to this repository's own established conventions,
   using the guide's "Created in this lab" inventory as the specification for what
   the final state must contain.
1. **Environment (Step 1):** Resumed Floci, sourced all five env files, confirmed 11
   non-empty values including both public subnets (a hard ALB requirement).
2. **Dependencies intact (Step 2):** Labs 02–04 all `FAIL=0` before starting.
3. **Capability probe (Step 3):** Every ELBv2 and ECS-integration call answered
   correctly (including `describe-listeners` rejecting a non-ARN with a
   validation-shaped error, confirming genuine support rather than a stub) — **Path A**.
4. **ALB security group (Step 4):** Created `usms-alb-sg` with the course's only
   deliberate `0.0.0.0/0` ingress rule, justified by everything behind it.
5. **Load balancer (Step 5):** Created `usms-enrolment-alb` across both public
   subnets, waited for `active`, set `idle_timeout` and
   `drop_invalid_header_fields` attributes.
6. **Target group (Step 6):** Created `usms-enrolment-tg` with `--target-type ip` and
   the five health-check numbers from the guide. Hit and fixed an MSYS path-mangling
   bug on the health check path — see Section 7.
7. **Target group attributes (Step 7):** Set `deregistration_delay.timeout_seconds`
   to 30 and the load-balancing algorithm to `least_outstanding_requests`.
8. **Listener (Step 8):** Created the HTTP:80 listener with a default forward action
   to the target group, then added the health-check rule (priority 10, path
   `/alb-health`, fixed-response 200) using the two template files the guide's own
   directory structure already named for this purpose.
9. **Task-tier ingress (Step 9):** Authorized `usms-enrolment-sg` to admit tcp/80
   from `usms-alb-sg`, alongside the still-present direct rule from `usms-app-sg`.
10. **Attach the service (Step 10):** `update-service --load-balancers ...
    --health-check-grace-period-seconds 60` was accepted with no error but silently
    did not persist either field — see Section 7. Recovered using the guide's own
    documented fallback: deleted and recreated the service with the load balancer
    attached at creation time, which did persist the `loadBalancers` entry.
11. **Watch targets register (Step 11):** Both tasks registered into the target
    group automatically, with no manual `register-targets` call, and both reached
    `healthy` within the configured health-check interval — see Section 7 for what
    this reveals about this build's data plane.
12. **Test the application (Step 12 equivalent):** `curl` against the load
    balancer's DNS name failed to resolve — see Section 7 for exactly why — so ran
    the guide's own prescribed fallback: a six-link control-plane reachability chain,
    all six links confirmed correct.
13. **Cutover (Step 13):** Revoked the `usms-app-sg` ingress rule on
    `usms-enrolment-sg`. The revoke call unexpectedly removed *both* remaining rules
    at once — see Section 7 — re-authorized the legitimate ALB rule immediately
    afterward, leaving exactly the intended single rule.
14. **`configs/lab-05.env` and verification:** Wrote the env file, then
    `scripts/utilities/verify-lab-05.sh` (32/32 pass, 1 documented informational
    gap) and `scripts/cleanup/lab-05-cleanup.sh`, then committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Evidence 1 — Load balancer active across two real Availability Zones (Step 5)**
```json
{
    "Name": "usms-enrolment-alb", "State": "active",
    "AZs": [
        {"Zone": "us-east-1a", "Subnet": "subnet-5e1fd5a1"},
        {"Zone": "us-east-1b", "Subnet": "subnet-4950f8b4"}
    ]
}
```

**Evidence 2 — Targets register themselves and reach `healthy` with no manual intervention (Step 11)**
```
attempt 1: targets=2   (both "initial")
... 45s later ...
172.22.0.3  healthy
172.22.0.4  healthy
```

**Evidence 3 — Floci's own logs confirm a genuine, served HTTP response (Step 11/12)**
```
[ecs:usms-enrolment:enrolment-api] 172.22.0.2 - - "GET / HTTP/1.1" 200 896 "-" "Java/25.0.3"
```
(the requester, `172.22.0.2` / `Java/25.0.3`, is Floci's own internal health-checker,
not anything reachable from this machine — see Section 7)

**Evidence 4 — The cutover: `usms-enrolment-sg` down to exactly one rule (Step 13)**
```
Before Step 13: 2 IpPermission entries, port 80 (app-sg + alb-sg sources)
After Step 13:  1 IpPermission entry,  port 80 (alb-sg source only)
```

**Evidence 5 — `verify-lab-05.sh`, end-to-end**
```
PASS=32 FAIL=0 INFO=1
```

### 6.2 Console Verification

| Console page (real AWS) | CLI substitute used here |
|---|---|
| EC2 → Load Balancers | `aws elbv2 describe-load-balancers` |
| EC2 → Target Groups → Health checks | `aws elbv2 describe-target-health` |
| EC2 → Load Balancers → Listeners/Rules | `aws elbv2 describe-listeners` / `describe-rules` |
| EC2 → Security Groups | `aws ec2 describe-security-groups` |

## 7. Analysis and Discussion

`verify-lab-05.sh` passed all 32 checks this build supports, with 1 informational
finding. Every available checkpoint was independently confirmed.

**This build's ELBv2 data plane is genuinely more functional than the guide warns to
expect.** The guide's own Floci Limitation callout says a load balancer "that exists
as an object but forwards no packets is the most likely outcome." That was not what
happened here: both targets transitioned from `initial` to `healthy` within the
configured 30-second interval, and `docker logs floci` showed the Floci process
itself issuing real `GET /` requests (user agent `Java/25.0.3`) against the actual
nginx containers and receiving genuine `200` responses. However — and this is the
precise, important nuance — **this only proves the control plane and Floci's own
internal reconciliation work; it does not prove the load balancer is reachable from
outside Floci.** `docker port floci` shows only `4566/tcp` mapped to the host; `docker
port` on every `floci-floci-course-ecs-*` container shows no ports at all. Unlike
Lab 03's EC2 instances and the port-forwarding sidecars Floci created for them, the
ALB's listener (`"ELBv2 listener port started on 80"` in the logs) runs purely
inside Floci's internal Docker network, with no socat sidecar and no host port
mapping exposing it. `curl` against the ALB's DNS name therefore fails at the first
step — `Could not resolve host` — for a reason more specific than "Floci has no DNS
for it": even with a `/etc/hosts` entry, there is genuinely no host-reachable port to
connect to. The health checks succeed because they originate *inside* the same
Docker network the targets live in; nothing from this machine's own terminal ever
could.

**Three further gaps were found, each confirmed in isolation before being recorded:**

1. **`--health-check-path /` on `create-target-group` was silently rewritten by Git
   Bash's MSYS layer** to `C:/Program Files/Git/`, the same category of bug Lab 04
   hit for a CloudWatch Logs group name. Caught immediately by reading the target
   group back; fixed with `MSYS_NO_PATHCONV=1 aws elbv2 modify-target-group
   --health-check-path /`, which this build did accept and persist correctly.
2. **`aws ecs update-service --load-balancers ... --health-check-grace-period-seconds
   60` is accepted with no error, but neither field is persisted** — confirmed by an
   immediate `describe-services` showing both `null`. This is a different failure mode
   than the guide's own anticipated one (`InvalidParameterException` /
   `UnsupportedFeatureException`, a loud rejection); here the call succeeds and
   silently does nothing. The guide's own documented fallback (delete and recreate the
   service with the load balancer attached at creation) worked for the `loadBalancers`
   field — `describe-services` afterward showed the entry correctly. `
   healthCheckGracePeriodSeconds`, however, stayed `null` even when passed to
   `create-service` directly, which narrows the gap specifically to that one field,
   independent of which call sets it.
3. **`revoke-security-group-ingress` with an explicit `UserIdGroupPairs` specification
   removed every matching protocol/port rule, not only the one naming that group.**
   Both rules on `usms-enrolment-sg` read back with empty `UserIdGroupPairs` arrays
   (the same persistence gap Lab 02 and Lab 04 already documented for group
   references), and revoking "the rule sourced from `usms-app-sg`" by specifying that
   group ID in the request body removed *both* tcp/80 rules at once — including the
   legitimate `usms-alb-sg` rule just added in Step 9. This is a direct, previously
   unobserved consequence of the already-known gap: because the group-reference
   metadata was never stored distinctly in the first place, there was nothing for the
   revoke call to match against *except* protocol and port, which both rules shared.
   Caught immediately by reading `usms-enrolment-sg` back empty; fixed by
   re-authorizing the ALB rule. The cutover's *end state* — exactly one rule,
   sourced from the load balancer — is correct; getting there took one extra,
   corrective step.

**The guide's own anticipated Lab 04 regression did not manifest as a new hard
failure here**, for a reason worth recording precisely rather than copying the
guide's claim uncritically: the guide's hypothetical `verify-lab-04.sh` would report
`FAIL usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)` after this lab's
cutover. This repository's own `verify-lab-04.sh`, however, already treats that exact
check as informational rather than a hard failure, because Lab 04's own build already
discovered that security-group-to-security-group references are not persisted on this
Floci build at all — so the check was already reading `None` before this lab ever
touched anything, and remains `None` afterward. Re-running `verify-lab-04.sh` after
the cutover shows no change: `PASS=37 FAIL=0 INFO=1`.

## 8. Reflection

**1. What did you learn about this AWS service?**
That a load balancer's four objects map cleanly onto a question each one answers —
where is it (the load balancer), what port does a client use (the listener), which
request goes where (the rule), and which specific backends are currently eligible
(the target group, via its health check) — and that the health check belonging to
the target group rather than the load balancer is not a quirk but the reason one
target group can serve several listeners with one consistent opinion about health.

**2. What challenges did you encounter?**
Distinguishing "this build genuinely doesn't support X" from "this build accepts X
but silently drops it" was the dominant theme — both the load-balancer-attachment gap
and the grace-period gap looked, from the command's own exit code, like total
success. The security-group revoke incident was the most instructive: a gap already
known (lost group-reference metadata) had a second, worse consequence I hadn't
anticipated (imprecise revoke matching), which only surfaced because I read the
group back immediately rather than trusting the `{"Return": true}` response.

**3. How would you apply this service in a real-world cloud environment?**
Exactly this pattern — ALB in front of an ECS service, group-referenced security
rules on both sides, a deliberate prove-then-cutover migration — plus HTTPS on 443
with an ACM certificate (the Step 4 "Your turn" gestures at exactly this), and
genuinely exercising `least_outstanding_requests` under uneven request durations,
which this build's lack of a reachable data plane made impossible to observe.

**4. What additional concepts or features would you like to explore?**
Weighted target groups for blue/green deployment, sticky sessions and when they are
actually the wrong fix for a stateful-feeling symptom, and AWS WAF attached directly
to an ALB — none of which this lab's scope or this build's reachability gap gave room
to exercise.

## 9. Conclusion

This practical's objectives were achieved within the real limits of both the
(genuinely truncated) source guide and this specific Floci build: an internet-facing
Application Load Balancer, a correctly-configured target group whose targets
self-registered and reached `healthy`, a health-check rule, and a completed security
cutover — the direct web-tier path removed, the load-balancer path the sole
remaining one — were all built and independently verified via the AWS CLI. Three
gaps were found and precisely characterized: a platform-level MSYS path bug, a
silent (not loud) failure to persist two `update-service` fields, and a revoke call
whose over-broad match was a direct, newly-observed consequence of an
already-documented persistence gap rather than a new root cause. The health checks
succeeding while `curl` from this machine could not connect is this lab's sharpest
finding: proof that a system's internal reconciliation working is not the same claim
as a system being reachable from outside it — the same distinction, one layer up,
that this lab's Section 7 interlude already drew between a container's own health
check and a load balancer's.

## 10. Appendix

**Reproduce this lab:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
source ~/aws-floci-course/configs/lab-02.env
source ~/aws-floci-course/configs/lab-03.env
source ~/aws-floci-course/configs/lab-04.env
source ~/aws-floci-course/configs/lab-05.env
./scripts/utilities/verify-lab-05.sh
```

**Supplementary files (all in this repository):**
- Policy documents: [`policies/usms-alb-sg-ingress.json`](../../policies/usms-alb-sg-ingress.json),
  [`policies/usms-enrolment-sg-ingress-alb.json`](../../policies/usms-enrolment-sg-ingress-alb.json)
- Templates: [`templates/lab-05-listener-default-actions.json`](../../templates/lab-05-listener-default-actions.json),
  [`templates/lab-05-rule-conditions.json`](../../templates/lab-05-rule-conditions.json),
  [`templates/lab-05-rule-actions.json`](../../templates/lab-05-rule-actions.json),
  [`templates/lab-05-service-load-balancers.json`](../../templates/lab-05-service-load-balancers.json)
- Scripts: [`scripts/utilities/verify-lab-05.sh`](../../scripts/utilities/verify-lab-05.sh),
  [`scripts/cleanup/lab-05-cleanup.sh`](../../scripts/cleanup/lab-05-cleanup.sh)
- Environment config: [`configs/lab-05.env`](../../configs/lab-05.env)
- Review-question answers: [`notes/lab-05-notes.md`](../../notes/lab-05-notes.md)

---

### Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture included
- [x] All implementation steps documented
- [x] CLI output captured as evidence — screenshots are not applicable; see Section 6.1
- [x] Console verification — *N/A for Floci; CLI-substitute table provided*
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached

---

## Problems I hit and how I fixed them

- **The source PDF is genuinely truncated** (ends mid-command on page 76/77).
  Confirmed by opening the PDF directly rather than assuming a transcription error;
  built the remaining steps, scripts and review questions to this repository's own
  established conventions instead.
- **`--health-check-path /` was silently rewritten to a Windows path** by Git Bash's
  MSYS layer, the same bug class as Lab 04's log-group name. Fixed with
  `MSYS_NO_PATHCONV=1` on the corrective `modify-target-group` call.
- **`update-service --load-balancers ...
  --health-check-grace-period-seconds 60` accepted both flags and silently applied
  neither.** Confirmed by an immediate independent `describe-services`, not assumed
  from the update call's own success. Fixed the `loadBalancers` half with the guide's
  documented delete-and-recreate fallback; `healthCheckGracePeriodSeconds` stayed
  unset even then and is recorded as a narrower, separate gap.
- **`revoke-security-group-ingress` removed both port-80 rules on
  `usms-enrolment-sg` when only one was named**, because the group-reference metadata
  that would have let it distinguish them was never persisted in the first place (the
  same gap already found in Labs 02 and 04). Caught by reading the group back
  immediately; fixed by re-authorizing the one rule that should have remained.
- **`curl` against the load balancer's DNS name failed to resolve**, and
  investigating *why* (rather than accepting the guide's generic "may not work")
  found a specific, confirmable cause: no host port mapping exists for the ALB's
  listener at all (`docker port floci` and every ECS task container both confirmed
  this), even though the targets themselves are genuinely healthy and genuinely
  serving requests from inside Floci's own network.
