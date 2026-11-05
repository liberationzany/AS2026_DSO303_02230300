# Lab 12 notes - ECS Pipeline Deploy

## Step 4 - the port range was not uncommented

Uncommenting `5100-5104` in `docker-compose.yml` as Step 4 instructs made `floci-up.sh` fail
with `Bind for 0.0.0.0:5100 failed: port is already allocated`: a separate Floci sidecar
container, `floci-floci-course-ecr-registry`, already self-publishes `0.0.0.0:5100->5000/tcp`
independently of the main `floci` container's compose ports. The edit was reverted (the line
stays commented); `floci-up.sh` then starts cleanly, and the ECR repository's `repositoryUri`
already correctly resolves to `...localhost:5100/usms-enrolment` with no compose change at
all. `docker-compose.yml` is therefore unchanged in this lab's commit.

## Support path

`USMS_CICD_DEPLOY_PATH=A` per `outputs/lab-12-deploy-probe.txt`: Docker, ECR and raw ECS APIs
all answer. The one capability that turned out *not* to be supported, found only once the
pipeline actually ran, was **CodePipeline's own ECS deploy action provider** (Section "Running
it end to end" below). The Step 3 probe cannot catch this: it only checks that `ecs
list-clusters` answers, not that CodePipeline's `provider: ECS` action type is implemented.

## Step 12 "Your turn" - comparing my draft policy with Step 15's real one

My draft (`notes/lab-12-my-pipeline-policy.json`, written before reading Step 15) combined the
four ECS deploy-action calls and the two-role PassRole into two statements, with the ECS
statement scoped to `Resource: "*"`. Step 15's real `USMSCodePipelineBase` v2 splits this
differently, in two ways my draft got wrong:

1. **`ecs:DescribeServices` and `ecs:UpdateService` are scoped to the specific service ARN**
   (`arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc`), not
   `Resource: "*"`. These two actions act on a resource that already exists and already has an
   ARN, so there is no reason to grant them broadly - unlike `RegisterTaskDefinition`.
2. **`ecs:RegisterTaskDefinition` (with `DescribeTaskDefinition` and `ListTaskDefinitions`) is
   its own separate statement**, still on `Resource: "*"`, because `RegisterTaskDefinition`
   creates a new resource that has no ARN to scope against before it exists - the same
   justification Step 12 gives for `ecr:GetAuthorizationToken`. My draft had folded this into
   the same statement as the service calls, which hides the fact that one half of that
   statement *could* be scoped and the other half genuinely cannot.

The `PassRole` statement I wrote matched Step 15's almost exactly (same two role ARNs, same
`iam:PassedToService: ecs-tasks.amazonaws.com` condition) - that part of the "Your turn" hint
was correct.

## Step 16 "Your turn" - what if the Deploy action read `SourceOutput` instead of `BuildOutput`?

`SourceOutput` is the S3 source zip's contents: `.dockerignore`, `Dockerfile`, `VERSION`,
`buildspec.yml`, `config/`, `src/`, `tests/`. It does **not** contain `dist/` or
`imagedefinitions.json` - those are written by the Build stage and only appear in
`BuildOutput`, because `artifacts.base-directory: dist` in the buildspec publishes `dist/`'s
contents (not the source tree) as the Build stage's output artifact.

If the Deploy action's `inputArtifacts` named `SourceOutput`, the action would look for
`imagedefinitions.json` at the root of the *source* archive, not find it, and fail with an
error about the missing file. That failure would appear **in the Deploy stage**, not in Build -
even though the actual mistake (wiring the wrong artifact into the action) was made when the
pipeline document was written, which happens once, long before any execution. A log reader
looking only at which stage failed would wrongly suspect the build broke, when the build never
touched the Deploy stage's configuration at all.

## Step 18 "Your turn" - what to do about the orphaned `usms-enrolment:4`

Revision 4 (this run's r8 attempt) still exists as a task definition and still names
`000000000000.dkr.ecr.us-east-1.localhost:5100/usms-enrolment:r8`, an image that was never
pushed. Decision: **leave it registered, do not deregister it.**

Reasoning: a task definition family is an append-only log by design (Step 18's own text makes
this point about rollback - "there is no undo API"). Deregistering revision 4 would remove the
record that this release was attempted and failed, which is exactly the information an auditor
or a future on-call engineer would want. The service itself is already back on revision 3
(confirmed via `describe-services`), so revision 4 is inert - nothing references it, nothing
can accidentally redeploy it short of someone explicitly naming `usms-enrolment:4`.

How someone would notice six months from now, without being told: `aws ecs
list-task-definitions --family-prefix usms-enrolment` lists every revision, and `describe
-task-definition` on the ones the *service* isn't running would show the gap between the
registered revision count and the service's actual running revision. A periodic audit script
(the kind Section 14 question 7 gestures at, and the kind the course's later monitoring lab
likely builds) that diffs "revisions that exist" against "revisions ever deployed" would flag
revision 4 immediately, with the unpushed image tag `r8` as the tell.

## Running it end to end - the pipeline's ECS deploy provider is unavailable

`start-pipeline-execution` with release `r7` produced `pipelineExecution.status: Failed`, with
`statusSummary`:

```
Action DeployToECS failed: Provider ECS is not available in Floci CodePipeline
```

`get-pipeline-state`'s `latestExecution.status` stayed `None` for every stage (the same gap
Lab 11 found), so the real per-stage outcome came from `list-action-executions`, which showed
Source and Build both `Succeeded` and only Deploy `Failed`. This is a distinct finding from
every other ECS/ECR gap in this course so far: raw `aws ecs` and `aws ecr` calls both work
fine on this build (Path A), and the pipeline's Source and Build stages both genuinely work
(proven across Labs 11-12) - but CodePipeline's `provider: ECS` deploy action specifically is
not implemented here. The pipeline *document* is entirely correct (three stages, right
provider name, right artifact chain, right configuration keys) and would be accepted and run
by real AWS; only this build's execution engine is missing that one action type.

To still produce genuine end-to-end evidence, I reproduced the deploy action's own four
documented steps by hand, against the exact artifacts the real pipeline run had already
produced (the r7 image the Build stage's logic would have required, and the
`imagedefinitions.json` the local buildspec run actually wrote): describe the running task
definition, strip the eight read-only fields, change only the image to `...usms-enrolment:r7`,
register, `update-service`. Full evidence is in `outputs/lab-12-deploy-evidence.txt` (git
-ignored). This is explicitly **not** a claim that the pipeline performed the deploy - it is a
proof that every other link in the chain (source zip -> build -> pushed image ->
imagedefinitions.json naming the right container -> a task definition revision that only
changes the image field -> the service pointing at it) is sound, with the one unavailable link
named precisely.

A second, smaller finding fell out of this: calling `update-service --task-definition
usms-enrolment` (family name only, no revision) left `describe-services`'
`services[0].taskDefinition` holding the literal unresolved string `usms-enrolment`, not a
resolved ARN or even `family:revision`. Supplying the revision explicitly
(`usms-enrolment:3`) produced the shorthand `usms-enrolment:3` rather than the full
`arn:aws:ecs:...:task-definition/usms-enrolment:3` real AWS returns in that field. Neither form
breaks `describe-task-definition` (which resolves both the bare family name and the
`family:revision` shorthand to the latest/named revision correctly), but it means this field
cannot be string-compared against a full ARN the way some of the lab's own example `--query`
output assumes.

## The rollback drill

Registered `usms-enrolment:4` naming `usms-enrolment:r8`, a tag that was never pushed
(confirmed via `ecr describe-images` listing only `r6` and `r7`). After `update-service` to
revision 4 and a 20-second wait: `services[0].deployments` was `null` (not an array - the same
gap `usms-ecs-watch.sh` already defends against from Step 11), `runningCount` stayed at `2`
(not `0`), `status` stayed `ACTIVE`, and `services[0].events` was empty. On real AWS this
sequence would produce `CannotPullContainerError` events, the circuit breaker tripping after a
threshold, and an automatic rollback deployment to revision 3. Here, nothing in the service's
own state ever indicated anything was wrong - the task definition pointed at a nonexistent
image and the service reported itself healthy regardless, which is the sharpest illustration
in this course so far of the "stored, not enforced" pattern: Lab 04 set
`deploymentCircuitBreaker: {enable: true, rollback: true}`, and that setting is accepted and
stored, but nothing here launches a real task, so nothing ever fails to start, so the breaker
has no event to react to. Rolled back by hand to revision 3 via `update-service
--task-definition usms-enrolment:3`, confirmed via `describe-services`.

## Section 14 - Review Questions

**1. Three realistic changes that cannot travel through the ECS deploy action, and how each
would actually be deployed.**

The deploy action only ever changes one field (the named container's `image`) in a copy of
whatever task definition the service is currently running. Three things that therefore cannot
travel through it:

- **A new environment variable or a changed value for an existing one** (e.g. a feature flag,
  a changed log level, a new downstream endpoint URL). This has to be deployed by editing the
  task definition template committed to the repository (`templates/lab-12-taskdef-v3.json` or
  its successor) and running the Step 10 describe-strip-register sequence by hand, or by adding
  a dedicated "update env vars" action to the pipeline that does the same thing the Deploy
  action does but changes a different field.
- **A change to `cpu`/`memory` (a resize)**. Same answer: this is a task-definition-level
  change with no image involved, so it has to go through its own register-and-update-service
  step, typically driven by infrastructure code (CloudFormation/Terraform) rather than the
  application pipeline, since a resize is an infrastructure decision, not a release.
- **A change to the log configuration** (e.g. adding a new log group, changing the log driver,
  or - as this repo's own task definition shows - adding a health check where none exists).
  Same mechanism again: describe, strip, edit the relevant field, register, update-service.
  None of these three is something `imagedefinitions.json` can express, because that file has
  exactly two keys (`name`, `imageUri`) by design.

**2. `ecr:GetAuthorizationToken` on `Resource: "*"` and `ecs:RegisterTaskDefinition`
effectively on `Resource: "*"` - the same kind of exception?**

Argument that they are the same: both actions create or obtain something that has no ARN to
scope against *before the call succeeds* - a registry-wide bearer token in the first case, a
brand-new task definition revision in the second. IAM has no way to write `Resource:
"the-task-definition-this-call-is-about-to-create"`, so in both cases "no scoping is possible,
full stop" is a true statement about the API, not a shortcut taken out of laziness.

Argument that they are different: `GetAuthorizationToken` only ever returns a *credential*; it
cannot create or modify anything by itself, so the blast radius of granting it broadly is
bounded by whatever that credential can later do (which this lab does scope, via
`PushAndPullTheEnrolmentImageOnly`). `RegisterTaskDefinition`, by contrast, can register a task
definition naming *any* image, *any* execution role, *any* log configuration - up to whatever
`iam:PassRole` allows it to pass. Exercise 4 in this lab is built around exactly this
asymmetry: `RegisterTaskDefinition` on `"*"` is bounded only by the PassRole condition, and if
that condition is ever loosened, the "no scoping is possible" argument stops being reassuring,
because the thing that's unscoped can create a resource that reaches much further than a
token can.

Committing to an answer: they belong to the same *category* of IAM exception (API has no prior
ARN) but are not equivalent in risk, because one of them creates new capability-bearing
resources and the other only hands back a password. The policy is right to treat them with the
same `Resource: "*"` pattern, but wrong to treat them as equally safe without the companion
PassRole condition doing real work in the second case.

**3. The case for a digest over a tag, and the strongest case against pinning digests in task
definitions.**

For: a tag is a mutable pointer (`r7` can be repointed by a second push with the same tag,
exactly as the rollback drill in this lab deliberately exploits the mutability of `MUTABLE`
repositories). A digest (`sha256:...`) is derived from the image's content; the same digest can
never resolve to different bytes. A task definition that names a digest deploys exactly the
image that was tested, with no window in which the tag could have moved underneath it between
build and deploy.

Against: pinning digests in task definitions removes the human-readable release history a tag
provides (`r6`, `r7`, `r8` read as a sequence; `sha256:eddc7e5f...` does not), and - more
importantly for an operational pipeline - it defeats exactly the mechanism this lab relies on.
`imagedefinitions.json` is produced by the *build*, which only knows the tag it just pushed; a
pipeline that insists on digest-pinning would need an extra step to resolve that tag back to a
digest immediately after push, which reintroduces a race (another build could retag in
between) unless the registry enforces immutable tags - which brings the argument back to
Exercise 2's immutable-tag proposal as the actual fix, rather than digest-pinning as a
workaround for a mutable registry.

**4. A failure the circuit breaker would *not* catch, and what mechanism would.**

The circuit breaker only watches whether new tasks reach a healthy state at startup
(essentially: does the container start and pass its health checks). It would **not** catch an
application that starts cleanly, passes its health check, and then degrades or misbehaves
*after* traffic arrives - for example a memory leak that eventually OOM-kills the process after
an hour of traffic, or a release that silently returns stale/incorrect data from a working
`/healthz` endpoint while every real business endpoint is broken. The circuit breaker has
already declared the deployment a success by the time either failure mode shows up, because
"deployment is healthy" and "application is correct" are different claims. The mechanism that
would catch this is **application-level and infrastructure-level monitoring with alarms** -
CloudWatch alarms on error rates, latency, or a custom business metric, wired to
`DEPLOYMENT_STOP_ON_ALARM` in a CodeDeploy auto-rollback configuration (exactly the event this
lab's own `lab-12-codedeploy-deployment-group.json` already lists), or a manual approval gate
with a soak-time window before the old task set is torn down.

**5. What `update-pipeline`, `put-bucket-notification-configuration`, `update-assume-role
-policy` and `put-bucket-policy` have in common, and what a merge-based `update-pipeline` would
have to decide that a replace-based one does not.**

All four APIs govern a document that is a *complete declaration of a thing's behaviour*, not a
list of independent settings - a pipeline's stage list, a bucket's notification wiring, a
role's trust policy, a bucket's access policy. For documents like this, "replace the whole
thing" is actually the simpler and safer contract: the caller can read the current document,
reason about it as a whole, and send back something they have fully inspected. A merge API
would instead have to answer questions a replace API never needs to: what does it mean to
"merge" two JSON arrays like `stages` - append, by position, by matching `name`? What happens
if the client's partial document and the server's current document disagree about a field
neither side mentioned explicitly? Does a missing field mean "don't change this" or "set to
default/empty"? Those are genuinely hard, ambiguous questions for a structural document
(unlike, say, an EC2 instance's tags, where "merge my tags into yours" has one obvious
meaning), and a replace-only API sidesteps all of them by making the caller responsible for
producing a complete, correct document every time - which is exactly why Step 16's own "read
before running update-pipeline" warning exists.

**6. Why `create-policy-version` is not `--set-as-default` by default, and the workflow this
protects.**

Making every new version the default immediately would mean there is no way to stage a policy
change for review before it takes effect - the moment the JSON validates, every principal using
that policy would be re-evaluated against it. The two-step design (create, then separately
promote with `--set-as-default` or `set-default-policy-version`) protects a workflow where a
policy change can be authored, reviewed (by a second person, by a linter, by a security team),
and tested against a non-production principal or in a sandbox account, all while production
traffic keeps evaluating the known-good version - and only promoted once that review passes.
It also means a bad version can be deleted outright (`delete-policy-version`) without ever
having affected anyone, rather than requiring an emergency rollback. This lab's own Step 12 and
Step 15 both had to remember the `--set-as-default` flag explicitly, and `verify-lab-12.sh`
checks for it precisely because forgetting it is silent: the version exists, `create
-policy-version` returns success, and nothing is different for any principal until someone
notices the default never moved.

**7. Which of `outputs/lab-12-deploy-evidence.txt`, `outputs/lab-12-image-digest.txt`, and the
pipeline execution history would settle a claim that the enrolment service is running code
that was never reviewed - and what would need to be recorded at build time to settle it in one
command?**

`outputs/lab-12-image-digest.txt` helps partially: it ties a tag to a digest at a point in time,
proving *an* image with that digest existed in the registry, but says nothing about where the
image's *contents* came from. `outputs/lab-12-deploy-evidence.txt` helps more: it ties the
service's current task definition to a specific image URI, so it answers "what is running" -
but in this lab's actual run, it also has to honestly record that the registration was done by
hand because the pipeline's deploy action itself failed, which weakens exactly the kind of
automatic, unbroken chain a reviewer would want. The pipeline execution history (`list-action
-executions`, `get-pipeline-execution`) helps least on its own: it shows which S3 source
version a given execution consumed (an object version ID), but an S3 version ID says nothing
about *review* - it only proves which bytes were built, not that a human looked at them before
they were built.

None of the three, individually or together, proves code review happened, because nothing in
this lab's evidence chain records a review *event* at all - only build and deploy events. To
settle this in one command, the build would need to record, at build time, the identity of the
pull request or commit that triggered it (`CODEBUILD_RESOLVED_SOURCE_VERSION` already captures
a source version, but this lab's source is a hand-packed S3 zip with no commit history behind
it) *and* a reference to that commit's review status from the source control system (e.g. "PR
#142, approved by X, merged by Y") baked into `build-metadata.json` alongside the release and
build ID that are already there. A single command - `aws s3api get-object` on the artifact
plus reading `build-metadata.json`'s review-reference field - could then settle the claim,
provided the thing doing the review-gating (a required PR approval before merge to the branch
this pipeline's source reflects) is enforced upstream of this pipeline, not by this pipeline.
