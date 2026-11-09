# USMS - Gaps, Checkpoint 1

## 1. Observed, recorded, unavailable

Applying the three-category scheme across the whole system, grouped by where the boundary falls.

### Observed - watched happen, with evidence that can be re-run

- Identity: users, groups, roles, instance profiles, inline and managed policies, policy
  versioning (Lab 01, `verify-lab-01.sh` PASS=34/34).
- Network: VPC, 4 subnets across 2 AZs, IGW, NAT, route tables, 6 security groups, S3 gateway
  endpoint (Lab 02, PASS=52/52).
- Compute: two EC2 instances genuinely running; the ECS service genuinely running 2/2 tasks
  behind a real ALB; the EKS (k3s) cluster genuinely reachable via `kubectl`, with the HPA drill
  genuinely scaling pods under load (Labs 03-05, 07-08).
- Storage and triggering: `usms-student-data` holds real objects under `transcripts/`; its event
  notification genuinely invokes `usms-transcript-notifier` on upload (proven repeatedly, most
  recently in `evidence/end-to-end.txt` stage 5-6).
- Pipeline: a real Docker image was built, tagged, pushed to a real ECR repository, and pulled
  back by digest after deleting the local copy (Lab 12's create-perturb-read-back proof).
- Logs/metrics/alarms: real log groups with retention, real custom metrics with and without
  dimensions, real metric alarms genuinely transitioned via a forced state change (Lab 13).
- Security: `simulate-principal-policy` genuinely ran the real evaluation engine and returned
  `allowed`/`explicitDeny`/`implicitDeny` correctly for real statements (Lab 09).

### Recorded - correctly configured, accepted by the control plane, never executed by the emulator

- IAM authorization itself: every policy here is written as if it were enforced, but Floci
  accepts any non-empty credentials and does not evaluate requests against them by default
  (Lab 01 Section 11, Lab 09's permissions-boundary and IMDSv2 findings).
- `sts:AssumeRole` always succeeds, trust policy or no trust policy (Lab 01 Step 30).
- ECS/Auto Scaling: `PutScheduledAction` is unsupported and forcing an alarm does not change the
  ECS service's desired count - Lab 06's alarm-driven scaling is configuration only, proven
  instead by a manual `update-service --desired-count` convergence test.
- EKS node-group resizing: `update-nodegroup-config` fails on this build (confirmed, matches the
  course's own Known Issues list); real autoscaling was instead demonstrated at the pod level via
  the HPA (`verify-lab-08.sh`'s one remaining `FAIL` is exactly this, pre-documented by the lab
  guide itself, not a defect introduced here).
- CodePipeline's ECS Deploy stage: the stage exists, is correctly configured (provider `ECS`,
  correct cluster/service/filename), and `start-pipeline-execution` genuinely ran Source and
  Build to completion - but the Deploy action itself returns
  `Provider ECS is not available in Floci CodePipeline`. The deploy mechanism (describe, strip,
  register, update-service) was reproduced by hand against the pipeline's own real artifacts to
  prove the chain, recorded in `outputs/lab-12-deploy-evidence.txt`.
- CloudWatch alarm fields: `put-metric-alarm` accepts `--treat-missing-data`,
  `--datapoints-to-alarm`, `--unit`, `--dimensions` and `--tags` without error, but
  `describe-alarms` never echoes them back - the intended configuration is recorded in
  `templates/lab-13-alarms.json` since the live API cannot prove it.
- Lambda version immutability: `publish-version` does not freeze a distinct code snapshot on this
  build (`CodeSha256` was identical across versions 1, 3 and 4 after a code update) - the
  alias-repointing *mechanics* work and were exercised repeatedly, but the rollback *guarantee*
  they are supposed to provide does not fully hold here.

### Unavailable - no path to demonstrate at all on this build

- Metric filters (`put-metric-filter`, `describe-metric-filters`, even the read-only
  `test-metric-filter`): `UnsupportedOperation`. The two filters this project needed were written
  as documents (`templates/lab-13-metric-filters.json`) and their target metrics populated
  directly instead.
- Logs Insights (`start-query`/`describe-queries`): `UnsupportedOperation`. Used
  `filter-log-events` plus local Python aggregation instead (Lab 13 Step 23, Path B).
- CloudWatch dashboards and composite alarms (`put-dashboard`, `put-composite-alarm`,
  `describe-alarm-history`): all `UnsupportedOperation`. Written and JSON-validated as documents
  only (`templates/lab-13-dashboard.json`, `templates/lab-13-composite-alarm.json`).
- X-Ray, the entire service: every `xray:*` call returns `UnknownOperationException` - the routes
  are not implemented at all, not merely storage-only. Segments, subsegments and the sampling
  rule were built and structurally validated (11/11 checks) but never sent.
- CodeDeploy / blue-green: `deploy list-applications` does not answer. The appspec and deployment
  group documents (Lab 12 Step 19) are written and YAML/JSON-validated, never executed.
- A rendered AWS Management Console, specifically: Floci has no console to render, so no
  console screenshot exists anywhere in this repository, consistent with the checkpoint's own
  "no screenshots of green ticks" instruction. This is distinct from CLI/SDK terminal
  screenshots, which do exist for Labs 01-02 (`labs/lab-01-iam/assets/`,
  `labs/lab-02-vpc/assets/`, 37 images total, embedded in those labs' own READMEs) - those two
  labs were built under an earlier evidentiary standard, before Lab 03 explicitly switched to
  disclosed CLI transcripts in place of screenshots ("there is no terminal window in this
  environment to screenshot" - `labs/lab-03-ec2/README.md`). Labs 03 through 13 all follow that
  later, transcript-based standard; none of them carry screenshot images.

## 2. Known failures

Every check that currently fails in any verify script, with the reason and the evidence the
underlying configuration is nonetheless correct.

| Script | Failing check(s) | Reason | Evidence the config is correct |
|---|---|---|---|
| `verify-lab-08.sh` | `node group maxSize was raised to 6` (1 of 34) | `aws eks update-nodegroup-config` fails on this Floci build - a documented, course-wide known issue (see "Lab 08" row in the official Known Issues page), not something introduced in this repository | The HPA drill in the same lab genuinely scales pods under load, proving the autoscaling *concept* at the layer this build actually supports; `kubectl -n usms get hpa` shows real replica changes |
| `verify-lab-11.sh` | `pipeline has 2 stages` (1 of 46) | Lab 12 correctly and deliberately added a third stage (`Deploy`) to `usms-enrolment-pipeline`. Lab 11's own check predates that and was never meant to be "fixed" afterward - the course's own Known Issues page says explicitly: *"After Lab 12 adds a Deploy stage, do not delete it to satisfy Lab 11's two-stage check"* | `verify-lab-12.sh`'s own `pipeline has 3 stages` check passes; `aws codepipeline get-pipeline` shows Source → Build → Deploy with the correct artifact chain |
| `verify-lab-07.sh`, `verify-lab-08.sh` | (fixed during this checkpoint) all EKS-dependent checks | The k3s sidecar container's persisted node-IP state (`172.17.0.3`) did not match the IP Docker's bridge network reassigned after an earlier restart, so the container crash-looped (`"failed to find interface with specified node ip"`). This is an environment-recovery issue this repository has hit and fixed before, not a configuration defect | Recovered using the documented IP-reservation-placeholder trick (start a disposable container to claim `.2`, forcing the EKS container onto its expected `.3`); both verify scripts now report `PASS=32/32` and `PASS=33/34` respectively, the latter's one remaining failure being the pre-documented node-group row above |
| `verify-lab-09.sh` | 6 `DOCUMENTED_FAIL` entries (0 real `FAIL`) | Permissions boundaries and IMDSv2 `HttpTokens` are accepted by the control plane but not reflected on readback (another instance of the "accept but drop" pattern); the script itself distinguishes these from genuine failures and counts them separately | `simulate-principal-policy` was used as the substitute enforcement check and genuinely runs the real evaluation engine for everything else in that lab |

No other verify script currently reports a `FAIL` of any kind: `verify-lab-01.sh` through
`verify-lab-13.sh` (excluding the two rows above) are all clean. `inventory.txt` was regenerated
immediately before this submission and the full sweep is in `inventory.txt`'s own `verification`
section.

A third item, not a verify-script failure but found the same way (building `inventory.txt`
surfaced it via a `cleanup scripts: 12` count against `verify scripts: 13`): Lab 01 was missing
its own `scripts/cleanup/lab-01-cleanup.sh`, which every other lab has. Fixed during this
checkpoint using the exact content the Lab 01 guide's own Step 8.2 specifies.

## 3. What I would build next, and why that order

1. **Separate execution roles per Lambda function**, splitting `usms-lambda-exec-role`'s
   `USMSObservabilityWrite` grant away from the two edge functions that do not use it (see
   `architecture.md`'s "one decision I would now make differently"). This is first because it is
   the one concrete, specific finding from this checkpoint's own architecture review that is
   still sitting unaddressed in the live system, and because it is cheap to do now while the
   function count is still three - the cost of this kind of refactor only grows as more functions
   are added.
2. **A real alerting lab**, attaching SNS actions to `usms-transcript-lag-high` and
   `usms-notify-silence` (the composite alarm rule and the draft action document already exist as
   written artefacts, per `templates/lab-13-composite-alarm.json` and the project's `Required for
   future labs` note in Lab 13). This is second rather than first because, unlike item 1, nothing
   currently depends on it being done - the alarms already work and are already proven to
   transition - whereas item 1's IAM over-permission is a live, if low-severity, security gap
   *right now*.
3. **Reconstructing the Lab 01/02 documentation to the same depth as Labs 09-13** - full review
   question answers and the five independent exercises for the two earliest labs, which were
   built before this project's documentation rigor had settled (see the honest disclosure below).
   This is third, last, because it changes nothing about the running system - it is pure
   documentation debt, valuable for the record but with no technical consequence, unlike items 1
   and 2.

## An honest disclosure about documentation depth across labs

Labs 01 and 02 (`notes/lab-01-notes.md`, and the absence of `notes/lab-02-notes.md` or either
lab's `exercises.md`) are noticeably thinner than Labs 09 through 13's notes, which answer every
review question in full prose and record adapted "Your turn" reasoning inline. This is an honest
gap, not an oversight hidden until the assessor found it: this project's documentation rigor
increased visibly over its own history, and the earliest two labs were built before that
standard existed. The *system* those two labs produced is not thinner - `verify-lab-01.sh` and
`verify-lab-02.sh` both report a clean `PASS` with zero failures, and every resource Section 2 of
this checkpoint's brief requires from those two labs is present in `inventory.txt` - only the
written reflection is. Per item 3 above, closing this gap is planned but deliberately placed last,
because it is documentation debt with no effect on whether the system works.
