# Lab 04 notes

## Step 3 support path

**Path B — ECS supported, Application Auto Scaling not supported.**

`aws ecs describe-services --cluster probe --services probe` returned
`ClusterNotFoundException` — the service answered, it just didn't like the made-up
cluster name, exactly the "failed on arguments, not on support" distinction the guide
warns about. `aws application-autoscaling describe-scalable-targets` returned
`UnknownOperationException: Unknown operation: AnyScaleFrontendService.DescribeScalableTargets`
instead — a categorically different error, confirming the service itself does not
exist on this build. Every step in this lab is unaffected; the limitation only
surfaces in Lab 06, which will need the documented fallback the guide promises for
exactly this situation.

## Review questions

**1. "I put auto scaling on the task definition." Every way that's wrong.**

A task definition is an immutable, versioned blueprint — it has no running state for
anything to scale, and you cannot attach anything to it that would change over time
without registering a new revision, which defeats the point. What Lab 06 will
actually attach a scalable target to is the **service** (`usms-enrolment-svc`), not
the task definition, because the service is the object that holds `desiredCount` —
the one number auto scaling is capable of changing. Auto scaling does not touch
`runningCount`, `pendingCount`, or anything inside a container; it writes exactly one
integer into exactly one object, and the **service** is the thing that reconciles
that integer into reality by starting or stopping tasks. The observable consequence
of "ECS itself will know nothing about the scalable target" is that nothing in
`describe-task-definition` or `describe-services`'s own output ever mentions Lab 06's
scaling policy at all — the relationship is recorded entirely on the Application Auto
Scaling side (`describe-scalable-targets`), as a target that merely points at this
service's ARN. ECS is a passive recipient of a number; it has no concept of what
decided that number.

**2. The same policy, two different compute types, two different delivery mechanisms — explain fully.**

An EC2 instance's instance profile and a Fargate task's task role both do the same
job through different plumbing. For the EC2 instance (Lab 03), AWS's Instance
Metadata Service exposes temporary, auto-rotating credentials at a well-known
link-local address once the instance has an instance profile attached; any SDK on
the box asks IMDS and gets back a session. For the Fargate task (this lab), the
mechanism is the `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` environment variable,
injected automatically into the container by Fargate's infrastructure the moment the
task has a `taskRoleArn`; the SDK inside the container reads that path from a
link-local credentials endpoint instead. Neither mechanism needs a static access key
anywhere on disk or in an environment file, because both are *delivered*
credentials, scoped to the lifetime of the thing that's running — terminate the
instance or stop the task, and the credentials simply stop being issued. Right now,
`USMSStudentDataReadWrite` names `arn:aws:s3:::usms-student-data`, a bucket that does
not exist, so both the EC2 role and the task role hold a grant with nothing to act
on. The instant a later lab runs `s3 create-bucket --bucket usms-student-data`,
nothing about either policy or either role changes — the ARN they already named
starts resolving to a real object, and both `usms-web-01` and every task in
`usms-enrolment-svc` simultaneously gain the ability to read and write it, with zero
additional configuration and zero credentials ever having touched a disk.

**3. Execution role vs. task role: one-sentence symptoms, and why the same trust policy.**

The task execution role's failure symptom is "my task never starts, and
`stoppedReason` mentions the image or the log driver"; the task role's failure
symptom is "my task starts fine and then my application code gets `AccessDenied`."
Both roles share the identical trust policy (`{"Service":
"ecs-tasks.amazonaws.com"}`) because the *trust* question — who is allowed to assume
this role at all — is the same for both: the ECS/Fargate infrastructure itself. What
differs is not who may assume the role but **when** it's assumed and **what it's
used for** afterward: the execution role is assumed before your container exists, to
pull the image and open the log stream; the task role is assumed for the lifetime of
the running container, by your application code, to do whatever the application
actually does.

**4. Why source the enrolment SG rule from `usms-app-sg`, and why does scaling make it near-mandatory?**

Even if the task count never changed, naming `usms-app-sg` as the source is already
the correct choice for the same reason Lab 02 Step 15 gave: a security-group
reference describes "whatever currently carries this identity," not a frozen address
range, so it stays correct if the web tier is re-addressed, moved to a new subnet, or
scaled to more instances later — none of which would require touching the enrolment
rule. The additional, close-to-mandatory reason once Lab 06 lets the task count move
on its own: a Fargate task has no stable address at all. Every scale-out event
creates a brand-new elastic network interface with a brand-new private IP, and every
scale-in event destroys one. A CIDR-based rule on the caller's side would have to be
hand-edited every time capacity changed on either side of the relationship — which is
not a maintenance inconvenience so much as a rule that is *structurally* unable to
express "the current web tier" once that tier's membership is no longer fixed. A
group reference is the only form of this requirement that survives scaling at all.

**5. What Fargate removes from the EC2 model, and what it explicitly keeps — made concrete.**

Fargate removes the server: there is no EC2 instance to patch, no instance type to
right-size for the *host*, no capacity to pre-provision, and billing is per task per
second rather than per instance per hour. What it does not remove is anything from
Lab 2's networking model. A Fargate task launched in `awsvpc` mode gets its own
elastic network interface, with a real private address drawn from the subnet it's
placed in, and — concretely, as built in Step 8 — its own security group
(`usms-enrolment-sg`) that is evaluated exactly like an EC2 instance's security group
would be. The task also obeys the subnet's route table exactly as `usms-db-01` does
in Lab 03: placed in a private subnet with no route to an internet gateway, the only
way it reaches the public internet (to pull its container image from
`public.ecr.aws`) is via Lab 02's NAT gateway, and the only way anything could call
*it* directly from outside the VPC is `None`, for the same routing reason. Fargate
changed who manages the compute; it did not change, and could not change, the
network law Lab 02 wrote.

**6. One command that would look identical in memory mode vs. hybrid mode, and one that would not — and why.**

`aws sts get-caller-identity` would look identical either way: the root ARN
(`arn:aws:iam::000000000000:root`) is a constant of the Floci account itself, derived
from configuration, not from anything written to the state directory — exactly Lab
01 Step 14's original point, reapplied here. By contrast,
`aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc`
would *not* look the same: in `memory` mode, a Floci restart discards the entire ECS
state, and the call would return nothing — no cluster, no service, a hard failure —
whereas in `hybrid` mode (what this course actually runs under) the service, its
desired count, its task definition reference and its network configuration all
survive the restart unchanged, because they were written to the bind-mounted state
directory rather than held only in the running process's memory. The difference is
precisely whether the thing the command reads was ever durably written anywhere, and
the identity call is the control case that proves *nothing* interesting is being
tested by itself.

## Floci findings worth flagging beyond the guide's own anticipated gaps

- `aws ecs wait services-stable` throws an internal JMESPath error
  (`In function length(), invalid type for value: None`) rather than timing out or
  succeeding — the waiter's own built-in query breaks against this build's
  `describe-services` response shape. Worked around with the guide's manual polling
  loop, as anticipated.
- `--settings name=containerInsights,value=enabled` on `create-cluster` is accepted
  with no error but never read back (`describe-clusters --include SETTINGS` returns
  `Settings: null`) — exactly the specific limitation the guide warns Lab 06's target
  tracking policy would need a CPU metric for.
- The ECS service's `events` list is permanently empty (`events[0:4]` returns `None`)
  even after an `update-service` call that visibly changed `desiredCount` — unlike
  real AWS, where the service narrates every action it takes.
- "runningCount stays at 0" is real on this build immediately after `create-service`,
  but is **not permanent** — this build genuinely runs Fargate tasks as real Docker
  containers (confirmed with `docker ps`), it just takes well over ten minutes to
  converge, far slower than the guide's "instant or never" framing suggests. An
  early check concluded the one task that existed was permanently stuck in
  `lastStatus: PENDING`; re-checking later (while writing the report) showed that
  task had since `STOPPED` and the service had replaced it with two genuinely
  `RUNNING` tasks, matching `desiredCount`. The corrected lesson: a finding of
  "stuck" needs the same re-check discipline as a finding of "working" before it is
  written down as permanent.
