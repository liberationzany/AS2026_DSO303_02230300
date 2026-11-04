# AWS Practical Laboratory Report — Lab 06: ECS Service Auto Scaling

## 1. Aim / Objective

To hand the USMS enrolment service's capacity to Application Auto Scaling — a
scalable target, target tracking policies on CPU and on requests-per-target, a
step scaling policy driven by a hand-written CloudWatch alarm on a custom metric,
and scheduled actions for a known traffic window — and to determine precisely how
much of that this specific Floci build can actually execute, using the AWS CLI.

## 2. Introduction

Application Auto Scaling changes exactly one thing about an ECS service:
`desiredCount`. It does not start tasks, talk to containers, or know the
application exists; it reads a metric, compares it with a target, and writes an
integer. Everything downstream of that integer — ECS starting a task, the task
getting a network interface in a Lab 02 subnet, the service registering it in
Lab 05's target group, the load balancer health-checking it — is machinery this
course already built. Three objects matter: a **scalable target** (a registration
with a floor and a ceiling, not the resource itself), a **scaling policy** (target
tracking, which keeps a metric near a set point, or step scaling, which applies a
table of adjustments to an alarm it's attached to), and a **scheduled action** (a
calendar entry that moves the floor or ceiling, never the count itself).

**Key features this lab set out to use:**
- A scalable target addressed by a three-part, non-ARN identifier
  (`service namespace`, a constructed `resource ID`, a `scalable dimension`)
- Two target tracking policies on two different metrics, including the
  `ALBRequestCountPerTarget` metric Lab 05's load balancer unlocked
- A step scaling policy whose alarm is written and owned by the operator, not AWS
- Two scheduled actions using six-field cron expressions and IANA time zones
- A deliberate "create, perturb, read back" proof that something other than a
  human changed `desiredCount`

## 3. Use Case, Architecture, and What Actually Happened

This lab's Step 3 capability probe is the use case: **before building anything,
determine which of the three support paths (A — full, B — control plane only, C —
no Application Auto Scaling at all) this build sits on**, because the answer
determines what the rest of the report can honestly claim.

```
probe: aws application-autoscaling describe-scalable-targets --service-namespace ecs
  -> UnknownOperationException: Unknown operation: AnyScaleFrontendService.DescribeScalableTargets

(repeated for put-scaling-policy, describe-scheduled-actions, describe-scaling-activities
 -- identical exception every time)
```

A real Application Auto Scaling backend answers `describe-scalable-targets` with an
**empty list** when nothing is registered — a successful, ordinary call. This
build instead throws an exception naming an unrecognized operation, for every one
of the six Application Auto Scaling operations tested. That is categorically
different from "empty," and it places this build on **Support Path C**.

Per the guide's own, explicit instruction for Path C: *"Stop and tell your
instructor. Do Section 8's interludes, Exercises 4 and 5, and Section 15 —
Exercise 4 is the part of this lab that needs no emulator at all, and it is the
part a real employer would care most about."* This report follows that
instruction rather than fabricating scaling activity that did not happen.

### What this build genuinely can and cannot do

| Capability | This build |
|---|---|
| `aws application-autoscaling` (all six operations tested) | **Absent** — `UnknownOperationException` |
| `aws iam create-service-linked-role` | Rejected with `UnsupportedOperation` — a different, known-but-unimplemented operation |
| `aws cloudwatch put-metric-data` / `list-metrics` | **Works** — genuine custom metric, confirmed by reading it back |
| `aws cloudwatch put-metric-alarm` / `describe-alarms` | **Works** — genuine alarm object, with a real ARN |
| `aws cloudwatch set-alarm-state` | **Works** — genuinely changes `StateValue` |
| `--treat-missing-data` on `put-metric-alarm` | Accepted, not persisted (reads `null`) |

The practical consequence: the scalable target, both target tracking policies, the
step policy, and both scheduled actions could not be created for real anywhere in
this environment. The custom metric and the alarm that would drive the step policy
*could* be, and were. The configuration documents the guide specifies — the two
target tracking configs, the step config, the suspended-state config, and the
`ResourceLabel` string — were all written and validated exactly as Steps 7–10
specify, as designed artefacts, even though none of them could be submitted to a
live policy.

## 4. Implementation Procedure

0. **Dependencies confirmed (Steps 1–2):** sourced all six env files (14 non-empty
   values), confirmed the service at its baseline (desired 2, running 2, one
   deployment, one load-balancer entry) before touching anything.
1. **Capability probe (Step 3):** determined Path C as above, by distinguishing
   `UnknownOperationException` from the empty-list response a working build gives.
2. **Service-linked role attempt (Step 4):** `create-service-linked-role` rejected
   with `UnsupportedOperation` — confirmed as a different failure mode from the
   Application Auto Scaling absence (a known IAM operation simply not implemented,
   rather than an entire backend missing).
3. **Configuration documents written (Steps 7, 9, 10, 13):**
   `templates/lab-06-target-tracking-cpu.json`,
   `templates/lab-06-target-tracking-requests.json` (with the `ResourceLabel`
   genuinely constructed from the Lab 05 ALB and target group ARNs and validated at
   six segments), `templates/lab-06-step-scaling-out.json`, and
   `templates/lab-06-suspended-state.json` — all valid JSON, all exactly matching
   the guide's specified values, none submittable to a policy API that doesn't
   exist on this build.
4. **The custom metric and the alarm, built for real (Steps 10, 12):** published
   `USMS/Enrolment` `EnrolmentQueueDepth` datapoints, created
   `usms-enrolment-queue-high` (threshold 100, `GreaterThanOrEqualToThreshold`),
   and confirmed `set-alarm-state` genuinely changes `StateValue` to `ALARM` and
   back to `OK` — the alarm mechanism works right up to the exact point where it
   would hand off to a policy that cannot exist here.
5. **`configs/lab-06.env`:** written with every genuinely real value populated,
   and every Application-Auto-Scaling-dependent value recorded as `"not-created"`
   rather than a fabricated ARN or a bare `None`.
6. **Verification and commit:** `scripts/utilities/verify-lab-06.sh` (20/20 pass,
   2 documented informational findings) and `scripts/cleanup/lab-06-cleanup.sh`
   (reduced to deleting only the one real object, the alarm), then committed.
7. **The conceptual and paper work Path C calls for:** all seven review questions
   and Exercise 4's full capacity plan, in `notes/lab-06-notes.md` — the part of
   this lab explicitly least dependent on the emulator and, per the guide's own
   framing, the part most resembling the actual job.

## 5. Results and Evidence

**Evidence 1 — the Path C determination itself**
```
describe-scalable-targets   -> UnknownOperationException
put-scaling-policy          -> UnknownOperationException
describe-scheduled-actions  -> UnknownOperationException
describe-scaling-activities -> UnknownOperationException
create-service-linked-role  -> UnsupportedOperation   (a DIFFERENT error — a real,
                                                          known IAM operation, just
                                                          not implemented)
```

**Evidence 2 — the `ResourceLabel`, genuinely constructed from two real ARNs**
```
RESOURCE_LABEL = app/usms-enrolment-alb/d060f0a29d434392/targetgroup/usms-enrolment-tg/f1d1fdd422d54fb5
segments=6 first=app fourth=targetgroup
OK
```

**Evidence 3 — the one real control loop boundary this build supports**
```
set-alarm-state --state-value ALARM  ->  StateValue: ALARM   (genuinely changed)
set-alarm-state --state-value OK     ->  StateValue: OK      (genuinely changed)
```
(With no scaling policy existing to be an `AlarmActions` target, nothing downstream
of this state change could happen — which is the precise, confirmed boundary of
this build's capability, not an assumption about it.)

**Evidence 4 — `verify-lab-06.sh`**
```
PASS=20 FAIL=0 INFO=2
```

## 6. Analysis and Discussion

The single most important finding of this lab is not a configuration detail; it is
the distinction between "empty" and "absent." A naive read of
`describe-scalable-targets` returning nothing could be mistaken for "no targets
registered yet," which is a perfectly normal, successful state. Reading the actual
exception type — `UnknownOperationException`, naming an operation the server does
not recognize at all — is what correctly identifies this as Path C rather than a
quiet Path B. This is the same discipline Lab 04's own Step 3 probe taught: a
command's apparent failure or success is not evidence of *why* it failed or
succeeded until the actual error text has been read.

**The service-linked role attempt produced a second, independently useful data
point.** `UnsupportedOperation` is a different exception from
`UnknownOperationException` — it means this build recognizes
`create-service-linked-role` as a real IAM operation and has simply chosen not to
implement it, which is a narrower, more specific gap than "the entire Application
Auto Scaling service does not exist." Distinguishing the two matters for anyone
debugging a similar build later: one finding says "don't bother with this service at
all here," the other says "this one call is unimplemented; everything else in IAM
may still work."

**CloudWatch's independence from Application Auto Scaling turned out to be the
most pedagogically useful boundary in this lab.** Because `put-metric-data`,
`put-metric-alarm`, and `set-alarm-state` are all genuinely implemented, it was
possible to build the entire alarm side of Step 10 — the custom metric, the
threshold, the comparison operator — and to prove that the alarm's own state
machine works correctly, right up to the single step (`AlarmActions` naming a
scaling policy) that this build cannot support. That is a cleaner and more precise
finding than "auto scaling doesn't work here": it identifies exactly which service
boundary the gap sits on.

**One further gap, consistent with a pattern this course has now seen several
times:** `--treat-missing-data notBreaching` on `put-metric-alarm` was accepted with
no error and is not persisted — `describe-alarms` reads `null` for
`TreatMissingData` afterward. This is the same "accepted but silently dropped"
failure mode already found for Lab 05's `healthCheckGracePeriodSeconds` and for
`containerInsights` in Lab 04 — a recurring category on this build, not an
isolated incident, and worth stating as a pattern rather than three unrelated bugs.

None of the above required inventing scaling behaviour that did not happen. Every
claim in this report about what works and what doesn't is backed by a specific,
reproducible command and its actual output.

## 7. Reflection

**1. What did you learn about this AWS service?**
That verifying a service's *absence* correctly is as much a skill as verifying its
presence — an empty result and an unrecognized-operation exception look similar at
a glance but mean opposite things, and conflating them would have produced a report
claiming Path B (control plane only) when the truth was Path C (nothing at all).
I also learned, concretely rather than abstractly, that Application Auto Scaling's
entire contribution really is one integer: having to describe what this lab adds
without being able to demonstrate any of it working forced the explanation down to
its irreducible core.

**2. What challenges did you encounter?**
Resisting the urge to fabricate a plausible-looking scaling activity or a policy ARN
that would have made the report look more complete than the environment actually
supported. The honest path — probe precisely, confirm the exact error type, build
what genuinely can be built, and write the rest as explicitly conceptual — took
more care than simply following the guide's happy path would have, but it is the
only version of this report that is actually true.

**3. How would you apply this service in a real-world cloud environment?**
Exactly as designed here: a floor sized to availability-zone redundancy rather than
cost, an asymmetric cooldown favoring eager scale-out and reluctant scale-in,
request-count-per-target preferred over CPU for a web API, a hand-owned alarm for
the one requirement (queue depth) target tracking cannot express, and scheduled
actions for the load that is already on the calendar rather than waiting for a
reactive policy to notice it two minutes late.

**4. What additional concepts or features would you like to explore?**
Predictive scaling on the EC2 Auto Scaling side (explicitly unavailable for ECS
services, per this lab's own interlude), and running this exact configuration
against a Floci build or real AWS account where the full loop closes, so that
Step 12's `Cause` string — "the single most valuable output in this document,"
per the guide — could actually be observed rather than reasoned about.

## 8. Conclusion

This practical's objective — determine what Application Auto Scaling would add to
the USMS enrolment service, and build as much of it as this environment allows —
was achieved by first establishing, precisely and reproducibly, that this specific
Floci build implements none of the Application Auto Scaling API at all (Path C,
confirmed via `UnknownOperationException` across all six operations tested, and
distinguished from a merely-unimplemented single IAM call returning a different
exception). Every configuration document the guide specifies was written and
validated, the `ResourceLabel` was genuinely constructed from two real ARNs, and
the one object that could be built for real — a CloudWatch custom metric and its
alarm — was built, tested, and shown to work correctly up to the exact boundary
where this build's capability ends. The conceptual material and Exercise 4's full
paper capacity plan, which the guide itself identifies as the part of this lab
needing no emulator and most resembling real work, were completed in full. Five
labs into this course, the discipline remains the same: a command's result is not
evidence until its exact content has been read, and that discipline is what turned
an apparently incomplete lab into a precisely characterized one.

## 9. Appendix

**Reproduce the verification:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
source ~/aws-floci-course/configs/lab-02.env
source ~/aws-floci-course/configs/lab-03.env
source ~/aws-floci-course/configs/lab-04.env
source ~/aws-floci-course/configs/lab-05.env
source ~/aws-floci-course/configs/lab-06.env
./scripts/utilities/verify-lab-06.sh
```

**What actually exists (also in `configs/lab-06.env`):**

| Object | Status |
|---|---|
| Scalable target, both target tracking policies, step policy, both scheduled actions | Not created — Application Auto Scaling absent on this build |
| `usms-enrolment-queue-high` (CloudWatch alarm) | Real |
| `USMS/Enrolment` / `EnrolmentQueueDepth` (custom metric) | Real |
| `ResourceLabel` | Constructed and validated, unused by any live policy |
| `templates/lab-06-*.json` (4 documents) | Real files, valid JSON, never submitted to a live API |

**Supplementary files:**
- Templates: [`templates/lab-06-target-tracking-cpu.json`](../../templates/lab-06-target-tracking-cpu.json),
  [`templates/lab-06-target-tracking-requests.json`](../../templates/lab-06-target-tracking-requests.json),
  [`templates/lab-06-step-scaling-out.json`](../../templates/lab-06-step-scaling-out.json),
  [`templates/lab-06-suspended-state.json`](../../templates/lab-06-suspended-state.json)
- Scripts: [`scripts/utilities/verify-lab-06.sh`](../../scripts/utilities/verify-lab-06.sh),
  [`scripts/cleanup/lab-06-cleanup.sh`](../../scripts/cleanup/lab-06-cleanup.sh)
- Environment config: [`configs/lab-06.env`](../../configs/lab-06.env)
- Review questions and Exercise 4's capacity plan: [`notes/lab-06-notes.md`](../../notes/lab-06-notes.md)

---

### Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described (reframed as the Path C determination, per the guide's own instruction for this outcome)
- [x] System architecture included
- [x] All implementation steps documented, including what could not be executed and why
- [x] CLI output captured as evidence
- [x] Console verification — *N/A for Floci*
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached

---

## Problems I hit and how I fixed them

- **`describe-scalable-targets` returning no error at all could have been
  misread as "Path B" (empty list, control plane only).** Reading the actual
  response showed it was not an empty list but an exception —
  `UnknownOperationException` — which is the basis for correctly recording Path C
  instead. The lesson, again: the shape of a failure matters as much as the fact of
  one.
- **Tempted to fabricate a scaling policy ARN or a plausible `Cause` string** to
  make Step 12 look complete. Did not — recorded precisely what could and could not
  be built, which is the only version of this report that is actually true and the
  explicit instruction the guide gives for a Path C build.
- **`--treat-missing-data notBreaching` on `put-metric-alarm` is accepted but not
  persisted**, the same accepted-but-dropped pattern already found for Lab 05's
  grace period and Lab 04's `containerInsights` setting — confirmed by reading the
  alarm back immediately rather than trusting the create call's success.
- **`create-service-linked-role` returned `UnsupportedOperation`, not
  `UnknownOperationException`.** Recognized this as a meaningfully different, more
  specific finding (one unimplemented call vs. an entire absent backend) rather than
  lumping it in with the Application Auto Scaling findings.
