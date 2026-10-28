# AWS Practical Laboratory Report — Lab 04: Elastic Container Service (ECS)

## 1. Aim / Objective

To containerise the USMS enrolment service onto Amazon ECS running on AWS Fargate —
a cluster, an immutable task definition with two distinct IAM roles, a security
group sourced from the web tier's own group, and a service holding a fixed desired
count of 2 across both private subnets — using the AWS CLI against a local AWS
emulator (Floci), consuming Lab 01's IAM foundation and Lab 02's network, and to
verify every object's configuration and permission chain independently.

## 2. Introduction

Amazon ECS (Elastic Container Service) runs containers as managed workloads. Four
objects matter, and keeping them conceptually separate is the entire point of this
lab: a **cluster** is a namespace with no capacity of its own; a **task definition**
is a versioned, immutable blueprint (images, CPU/memory, roles, logging); a **task**
is one running instantiation of that blueprint; a **service** is the controller
whose only job is to keep `runningCount` equal to `desiredCount`. Nothing in this
lab ever changes `desiredCount` except a human typing a number by hand — that is
deliberate, since handing that number to Application Auto Scaling is Lab 06's job,
not this one.

**Key features used in this practical:**
- ECS clusters, Fargate launch type, `awsvpc` network mode
- Task definitions: families, immutable revisions, Fargate CPU/memory pairs
- Two distinct IAM roles per task — the task **execution** role (pulls the image,
  opens the log stream) and the task **role** (the application's own identity) —
  sharing an identical trust policy but serving entirely different purposes
- CloudWatch Logs groups with an explicit retention policy
- A security group sourced from another security group, not a CIDR block — a
  requirement that becomes close to mandatory once task counts can move on their own
- ECS's own `--tags` casing convention, distinct from EC2's and IAM's

Lab 01's IAM foundation and Lab 02's VPC are both prerequisites this lab consumes
rather than builds: the same `USMSStudentDataReadWrite` policy Lab 03 attached to an
EC2 instance profile is attached here, unchanged, to a completely different kind of
compute via a task role — proving the permission chain is a property of the policy
and the ARN it names, not of any one compute service.

## 3. Use Case

The USMS enrolment service is the endpoint the student portal calls on "Register for
this module." Today (post Lab 03) it runs as a single, fixed-size EC2 instance with
no failover. This lab moves it onto ECS:

| Object | Value |
|---|---|
| Cluster | `usms-ecs-cluster`, Fargate, Container Insights requested |
| Task definition | `usms-enrolment:1` — `awsvpc`, FARGATE, 256 CPU / 512 MiB |
| Execution role | `usms-ecs-exec-role` — pulls the image, writes the log stream |
| Task role | `usms-ecs-task-role` — reuses Lab 01's `USMSStudentDataReadWrite` |
| Security group | `usms-enrolment-sg` — tcp/80 from `usms-app-sg` only |
| Service | `usms-enrolment-svc` — desired count 2, both private subnets, no public IP |

No scalable target, no scaling policy, no scheduled action — `desiredCount` is set
once, by hand, and stays fixed for the rest of this lab. Lab 06 is the document that
owns capacity planning.

## 4. System Architecture / Design

```
                              Internet
                                 │
                            usms-igw
                                 │
   ============================ usms-vpc 10.0.0.0/16 ============================
   │  usms-public-rt  0.0.0.0/0 -> usms-igw                                      │
   │     │                                                                       │
   │  usms-public-subnet-a (10.0.1.0/24, AZ a)                                   │
   │     [usms-web-01]  usms-app-sg        [usms-nat]  Elastic IP (Lab 02)       │
   │     │                                                                       │
   │     │ tcp/80, source = usms-app-sg                                         │
   │     ▼                                                                       │
   │  usms-enrolment-sg  (in: tcp/80 from usms-app-sg ONLY)                      │
   │     │                                                                       │
   │  ┌──────────────────────────┐   ┌──────────────────────────┐              │
   │  │ usms-private-subnet-a     │   │ usms-private-subnet-b     │              │
   │  │ 10.0.3.0/24  AZ a         │   │ 10.0.4.0/24  AZ b          │              │
   │  │ [task 1]  [usms-db-01]    │   │ [task 2]                   │              │
   │  └──────────────────────────┘   └──────────────────────────┘              │
   │                                                                             │
   │  ECS control plane:                                                        │
   │    usms-ecs-cluster                                                        │
   │      usms-enrolment-svc   desiredCount = 2 (fixed in this lab)             │
   │        task definition usms-enrolment:1                                    │
   │          executionRoleArn -> usms-ecs-exec-role -> USMSECSTaskExecution    │
   │          taskRoleArn      -> usms-ecs-task-role -> USMSStudentDataReadWrite │
   =================================================================================

Image pull path (private subnet has no IGW route):
  task ENI -> usms-enrolment-sg (allow-all egress, unwritten)
           -> usms-private-rt -> usms-nat (Lab 02) -> usms-igw -> public.ecr.aws
           -> usms-s3-endpoint (Lab 02) for layer data stored in S3
```

`desiredCount` is the only field any future auto-scaling mechanism will ever touch;
every other object above is static for the rest of this lab.

## 5. Implementation Procedure

All work was performed against **Floci** (Account ID `000000000000`), continuing
directly from Labs 01–03.

0. **Pre-requisite catch-up:** Lab 04's prerequisites require both private subnets
   from Lab 02 "Exercise 5," which the original Lab 02 session never built. Created
   `usms-private-subnet-b` (`10.0.4.0/24`, `us-east-1b`) and associated it with the
   existing `usms-private-rt`, then updated `verify-lab-02.sh` for the new subnet
   count (committed separately, before this lab).
1. **Environment (Step 1):** Resumed Floci, sourced all four prior env files,
   confirmed eight non-empty values including both private subnets.
2. **Dependencies intact (Step 2):** Re-ran `verify-lab-02.sh` (52/52) and
   `verify-lab-03.sh` (30/30 + 5 informational) — both clean before building.
3. **Capability probe (Step 3):** Determined this build's support path by
   distinguishing a "bad arguments" error from a "service doesn't exist" error —
   see Section 7. Result: **Path B — ECS fully supported, Application Auto Scaling
   absent entirely.**
4. **Cluster (Step 4):** Assumed `usms-developer-role` via STS, created
   `usms-ecs-cluster` with Container Insights requested, restored root identity.
5. **Log group (Step 5):** Created `/usms/ecs/enrolment` with a 7-day retention
   policy — hit and fixed a Git-Bash path-mangling bug along the way (Section 7).
6. **Task execution role (Step 6):** Wrote `policies/trust-ecs-tasks.json` and
   `policies/usms-ecs-task-execution-policy.json` (ECR pull + scoped log-write),
   created `usms-ecs-exec-role`, attached the new `USMSECSTaskExecution` policy.
7. **Task role (Step 7):** Created `usms-ecs-task-role` with the same trust policy,
   attached Lab 01's `USMSStudentDataReadWrite` **unchanged** — the exact same
   document already attached to `usms-ec2-app-role` in Lab 03.
8. **Enrolment security group (Step 8):** Created `usms-enrolment-sg`, authorized
   tcp/80 sourced from `usms-app-sg`'s group ID (not a CIDR), via
   `policies/usms-enrolment-sg-ingress.json`.
9. **Task definition (Step 9):** Wrote `templates/lab-04-taskdef.json` — `awsvpc`,
   FARGATE, 256/512, both role ARNs, `awslogs` to the Step 5 log group — and
   registered it as `usms-enrolment:1`.
10. **Service (Step 10):** Created `usms-enrolment-svc`, desired count 2, both
    private subnets, `usms-enrolment-sg`, `assignPublicIp=DISABLED`.
11. **Read-back and hand-operated scaling (Step 11):** Read the four health fields;
    performed the "Your Turn" exercise — moved `desiredCount` 2 → 3 → 2 by hand with
    `update-service`, confirmed both transitions independently.
12. **`configs/lab-04.env` (Step 12):** Captured all 17 values by API lookup.
13. **Verification and commit (Step 13):** Wrote `scripts/utilities/verify-lab-04.sh`
    (37/37 pass, 1 documented informational finding) and
    `scripts/cleanup/lab-04-cleanup.sh`, cleaned up the expired assumed-role output
    per the guide's own KEEP/CLEAN UP table, then committed.

## 6. Results and Evidence

### 6.1 CLI Output

As in Lab 03, there is no terminal window in this environment to screenshot; the
evidence below is the literal, unedited CLI output captured while each command ran.

**Evidence 1 — Support path determined correctly, not guessed (Step 3)**
```
aws ecs describe-services --cluster probe --services probe
  -> ClusterNotFoundException: Cluster not found: probe        (SUPPORTED - bad args)

aws application-autoscaling describe-scalable-targets --service-namespace ecs
  -> UnknownOperationException: Unknown operation: AnyScaleFrontendService.DescribeScalableTargets
                                                                 (NOT SUPPORTED)
```

**Evidence 2 — Cluster created, task definition registered with two different roles (Steps 4, 9)**
```json
{
    "Family": "usms-enrolment", "Revision": 1, "Status": "ACTIVE",
    "Network": "awsvpc",
    "Exec": "arn:aws:iam::000000000000:role/usms-ecs-exec-role",
    "Task": "arn:aws:iam::000000000000:role/usms-ecs-task-role"
}
```

**Evidence 3 — Service created across both private subnets, no public IP (Step 10)**
```
SERVICE_ARN = arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc
```

**Evidence 4 — Hand-operated capacity change, the "Your Turn" proof (Step 11)**
```
update-service --desired-count 3  ->  desiredCount: 3
describe-services                 ->  desiredCount: 3   (confirmed independently)
update-service --desired-count 2  ->  desiredCount: 2
describe-services                 ->  Desired: 2  Running: 0  Pending: 0   (immediately afterward)
```

**Evidence 5 — Fargate tasks eventually converge to real running containers (re-checked later, Step 13)**
```
describe-services  ->  Desired: 2  Running: 2  Pending: 0
docker ps          ->  floci-floci-course-ecs-6d4699ed...-enrolment-api   Up
                       floci-floci-course-ecs-514f40c3...-enrolment-api   Up
```
(ten-plus minutes after Step 10's `create-service`; the task present at Evidence 4's
moment had since transitioned to `STOPPED` and been replaced by the service's own
reconciliation — see Section 7)

**Evidence 6 — `verify-lab-04.sh`, end-to-end (Step 13)**
```
PASS=37 FAIL=0 INFO=1
```

### 6.2 Console Verification

Floci has no AWS Management Console. The CLI-substitute table:

| Console page (real AWS) | CLI substitute used here |
|---|---|
| ECS → Clusters | `aws ecs describe-clusters` |
| ECS → Task Definitions | `aws ecs describe-task-definition` |
| ECS → Services → Health and metrics | `aws ecs describe-services` (the four counts) |
| ECS → Service → Logs | `aws logs describe-log-groups` |
| EC2 → Security Groups | `aws ec2 describe-security-groups` |

## 7. Analysis and Discussion

`verify-lab-04.sh` passed all 37 checks this build can support, with 1 informational
findings recorded rather than hidden. Every checkpoint in the guide was
independently confirmed against real command output.

**The Step 3 capability probe required reading past a naive pass/fail result.**
Running the probe script literally as written marked `ecs describe-services` as "not
available," because its exit code was non-zero — but the guide explicitly warns that
`describe-services --cluster probe` is *supposed* to fail, on its arguments, if the
service genuinely exists. Checking the actual error text distinguished
`ClusterNotFoundException` (ECS is there, the cluster name is just made up) from
`UnknownOperationException` (Application Auto Scaling is not there at all) —
confirming this build sits on **Path B**, which the guide explicitly anticipates as
a real, valid outcome and gives a documented fallback for in Lab 06.

**Several genuine Floci gaps were found, each independently confirmed before being
recorded as a limitation rather than a mistake:**

1. **`aws logs create-log-group --log-group-name "/usms/ecs/enrolment"` was silently
   rewritten by Git Bash's MSYS path-conversion layer** into
   `C:/Program Files/Git/usms/ecs/enrolment` before `aws.exe` ever saw it — a
   platform artefact, not a Floci one, caused by MSYS treating any argument starting
   with `/` as a POSIX path needing Windows translation. Caught immediately by
   reading the log group name back (`describe-log-groups` showed the mangled path),
   deleted the wrongly-named group, and re-ran every subsequent command touching a
   leading-slash value (the log group name, in `delete-log-group`) with
   `MSYS_NO_PATHCONV=1` set, which disables that conversion for the single command.
2. **`--settings name=containerInsights,value=enabled` on `create-cluster` is
   accepted with no error but never persisted** — `describe-clusters --include
   SETTINGS` returns `Settings: null`. This is exactly the specific consequence the
   guide warns about: Lab 06's target tracking policy, if this build ever supported
   Application Auto Scaling, would have no CPU metric to read. Moot in combination
   with the Path B finding above, but independently true and worth recording on its
   own.
3. **`aws ecs wait services-stable` fails with its own internal error** —
   `In function length(), invalid type for value: None, expected one of: ['string',
   'array', 'object'], received: "null"` — rather than timing out cleanly. The
   waiter's built-in JMESPath expression expects an array field in the
   `describe-services` response that this build returns as `null`. Worked around
   immediately with the guide's own documented manual polling loop, which the guide
   anticipated might be necessary for a different reason (a hanging, not an erroring,
   waiter).
4. **The ECS service's `events` list is permanently empty**, even immediately after
   an `update-service` call that visibly and correctly changed `desiredCount` twice
   in the same minute. Real AWS narrates every service action in this list; this
   build never populates it at all.
5. **Fargate task provisioning is real but very slow on this build — not "instant
   or never" as the guide's own comparison table claims.** Immediately after
   `create-service`, `runningCount` read `0` for well over ten minutes, and
   `list-tasks` showed only one task object for a `desiredCount` of 2, stuck at
   `lastStatus: PENDING` with `containers: []`. At that point `docker logs floci`
   confirmed the build was genuinely attempting the work — `Pulling image:
   public.ecr.aws/nginx/nginx:stable-alpine` — and `docker images` showed the image
   really had been pulled and cached (`nginx:1.31.3-alpine`, 93.6 MB). Revisiting the
   same service later, after writing the rest of this report, `describe-services`
   showed `Running: 2` against `Desired: 2`, and `docker ps` confirmed **two real
   Docker containers actually running** (`floci-floci-course-ecs-<task-id>-enrolment-api`,
   mirroring the one-container-per-EC2-instance pattern Lab 03 found). The original
   stuck task had transitioned to `STOPPED` on its own, and the service's own
   reconciliation had replaced it — exactly the self-healing behaviour Section 2's
   "a service is the thing that brings it back" description predicts, just visible
   here on a multi-minute timescale rather than the guide's assumption of instant
   or permanent failure. The corrected lesson is not "containers never run here," it
   is "checking once, ten minutes in, and concluding permanence was premature" — the
   same mistake the course has warned against since Lab 01, caught here by re-checking
   rather than by getting it right the first time.
6. **The security-group-to-security-group reference on `usms-enrolment-sg` was not
   persisted** — the same exact gap Lab 02 documented for `usms-db-sg`.
   `authorize-security-group-ingress --ip-permissions ...` with a `UserIdGroupPairs`
   source accepted the request and returned a rule ID, but reading the rule back
   shows an empty `UserIdGroupPairs` array. The port/protocol (80/tcp) is correctly
   stored and would be enforced; only the source metadata is lost. Recorded as the
   same known, already-documented emulator limitation rather than a new one.

None of the above required changing the actual ECS design — every fix was either a
platform-level workaround (the MSYS path issue), a substitution the guide itself
anticipated (the manual polling loop), or a documented, independently-confirmed
limitation of this specific Floci build.

## 8. Reflection

**1. What did you learn about this AWS service?**
That ECS's real complexity is not in running a container at all — it is in the
indirection between four objects, each with a different lifetime: a cluster that
outlives everything, a task definition revision that is permanently immutable once
registered, a task that can die at any moment, and a service whose only job is
noticing when that happens and fixing it. Every later scaling mechanism this course
will introduce does exactly one thing to exactly one of those four objects, and
understanding that now is what makes Lab 06 legible later rather than confusing.

**2. What challenges did you encounter?**
Distinguishing "this failed because the feature doesn't exist" from "this failed
because I gave it a nonsense argument" was the recurring theme — both the Step 3
capability probe and the task-count investigation required reading the actual error
text or the actual task object rather than trusting a summary field. The MSYS
path-mangling bug was the single most time-costly individual mistake: a perfectly
correct AWS CLI invocation was silently rewritten by the shell before the API ever
saw it, and the only way to catch it was to read the resource back immediately
rather than trusting the create call's exit code.

**3. How would you apply this service in a real-world cloud environment?**
Exactly as built here, plus the parts this build could not exercise: real Fargate
tasks reaching `RUNNING` within the 20–60 second window the guide describes,
Container Insights metrics actually populating the `AWS/ECS` namespace for Lab 06's
target tracking policy to read, and `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`
genuinely delivering rotating credentials to the task role inside a running
container rather than the association existing only as a describable configuration.

**4. What additional concepts or features would you like to explore?**
ECS capacity providers and Fargate Spot, blue/green deployments via CodeDeploy for
ECS, and how a task's `stoppedReason` differs across the specific failure modes this
build could not reproduce (a genuine `AccessDenied` from the task role, a real image
pull failure, a failed health check) — none of which this emulator's task-start gap
left room to exercise.

## 9. Conclusion

This practical's objectives were achieved within the real limits of this specific
Floci build: the USMS enrolment service was containerised onto ECS Fargate — one
cluster, one immutable task definition revision with two distinct and correctly
differentiated IAM roles, one group-referenced security group, and one service
spanning both private subnets with no public address — entirely via the AWS CLI,
with Lab 01's `USMSStudentDataReadWrite` policy proven to attach unchanged to a
second, completely different kind of compute. The Step 3 capability probe correctly
identified this build as ECS-only (no Application Auto Scaling), a platform-specific
MSYS path bug was caught and fixed rather than silently corrupting a resource name,
and an initial, premature "permanently stuck" conclusion about Fargate task
provisioning was itself caught and corrected by re-checking later rather than left
standing — reinforcing, a fourth lab in, that a command's exit code is never itself the
evidence; only an independent read of the actual resulting state is.

## 10. Appendix

**Reproduce this lab:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
source ~/aws-floci-course/configs/lab-02.env
source ~/aws-floci-course/configs/lab-03.env
source ~/aws-floci-course/configs/lab-04.env
./scripts/utilities/verify-lab-04.sh
```

**Resource identifiers (also in `configs/lab-04.env`):**

| Resource | Value |
|---|---|
| Cluster | `usms-ecs-cluster` |
| Task definition | `usms-enrolment:1` (256 CPU / 512 MiB, `awsvpc`, FARGATE) |
| Execution role | `usms-ecs-exec-role` + `USMSECSTaskExecution` |
| Task role | `usms-ecs-task-role` + `USMSStudentDataReadWrite` (Lab 01's, unchanged) |
| Security group | `usms-enrolment-sg` (tcp/80 from `usms-app-sg`) |
| Service | `usms-enrolment-svc` (desired count 2, both private subnets) |
| Log group | `/usms/ecs/enrolment` (7-day retention) |

**Supplementary files (all in this repository):**
- Policy documents: [`policies/trust-ecs-tasks.json`](../../policies/trust-ecs-tasks.json),
  [`policies/usms-ecs-task-execution-policy.json`](../../policies/usms-ecs-task-execution-policy.json),
  [`policies/usms-enrolment-sg-ingress.json`](../../policies/usms-enrolment-sg-ingress.json)
- Task definition template: [`templates/lab-04-taskdef.json`](../../templates/lab-04-taskdef.json)
- Scripts: [`scripts/utilities/verify-lab-04.sh`](../../scripts/utilities/verify-lab-04.sh),
  [`scripts/cleanup/lab-04-cleanup.sh`](../../scripts/cleanup/lab-04-cleanup.sh)
- Environment config: [`configs/lab-04.env`](../../configs/lab-04.env)
- Review-question answers: [`notes/lab-04-notes.md`](../../notes/lab-04-notes.md)

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

- **`aws logs create-log-group --log-group-name "/usms/ecs/enrolment"` was silently
  rewritten to a Windows filesystem path** (`C:/Program Files/Git/usms/ecs/enrolment`)
  by Git Bash's MSYS path-conversion layer, which treats any leading-slash argument as
  a POSIX path needing translation. Caught by reading the log group straight back
  with `describe-log-groups`; fixed by deleting the wrongly-named group and
  re-running every command that takes a leading-slash value with
  `MSYS_NO_PATHCONV=1` set for that command.
- **`aws ecs wait services-stable` crashed with an internal JMESPath type error**
  instead of polling or timing out cleanly — worked around with the guide's own
  documented manual polling loop.
- **The Step 3 capability probe's own simplistic pass/fail check mis-reported `ecs
  describe-services` as unsupported** because it only checked the exit code; reading
  the actual error text (`ClusterNotFoundException` vs. `UnknownOperationException`)
  gave the correct, and different, answer.
- **`containerInsights` on `create-cluster` is accepted but never stored** —
  confirmed by an explicit `--include SETTINGS` read rather than assumed from the
  create call's success.
- **The ECS task-level security-group reference (`UserIdGroupPairs`) was not
  persisted**, the same gap already documented for Lab 02's `usms-db-sg` — recognised
  immediately as the same category of issue rather than investigated as new.
- **Concluded "permanently stuck" after one check, which was premature.** An hour
  into the lab, only one of two desired tasks had materialised and it was stuck in
  `PENDING`. Revisiting the same service later (while writing this report) showed
  both tasks `RUNNING` with real Docker containers behind them (`docker ps`
  confirmed it) and the originally-stuck task cleanly `STOPPED` and replaced by the
  service's own reconciliation. Corrected the report rather than leaving the first,
  wrong conclusion in it — Fargate provisioning on this build is merely very slow
  (multi-minute), not broken.
- **`verify-lab-02.sh`'s "security groups tagged" check broke the moment this lab
  created a third `Project=USMS`-tagged security group**, because the original
  check counted every security group with that tag account-wide instead of the two
  specific groups Lab 02 actually created. Fixed by scoping the check to
  `$USMS_APP_SG_ID` and `$USMS_DB_SG_ID` by ID, the same pattern every other
  per-resource check in that script already uses.
