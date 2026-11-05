# Lab 11 — Building a CI/CD Pipeline with AWS CodePipeline and CodeBuild

**Support path: A — full.** `codebuild create-project` genuinely accepted
and the throwaway probe project deleted cleanly; `codepipeline
list-pipelines` answers. CodeDeploy also answers (stronger than the guide's
own "very likely absent" expectation), relevant to Lab 12.

## What this lab built

A versioned S3 artifact bucket (`usms-pipeline-artifacts`) with real
two-version proof and cleanup; the enrolment service's source tree
(`labs/lab-11-cicd/app/`) with a four-phase `buildspec.yml`, seven-assertion
smoke tests, and a port-80 validation check added to `pre_build`; scoped
`usms-codebuild-role`/`USMSCodeBuildBase` and
`usms-codepipeline-role`/`USMSCodePipelineBase` with a conditioned
`iam:PassRole`; the `usms-enrolment-build` CodeBuild project and
`usms-enrolment-pipeline` two-stage pipeline; `usms-pack-source.sh` and
`usms-buildspec-run.sh` (the local buildspec runner, adapted with a
`python3`→`python` shim for this host); genuine source-version
create→perturb→read-back proof (`r3`→`r4`→`r5`); a deliberate
`pre_build` failure, diagnosed and fixed.

## Findings worth reading before the verify output

### 1. `aws/codebuild/standard:7.0` cannot be pulled — confirmed outside Floci entirely

The standalone build against the project as originally configured failed
immediately with `buildStatus: FAULT`: `Status 404: pull access denied for
aws/codebuild/standard, repository does not exist`. Reproduced identically
via a direct `docker pull aws/codebuild/standard:7.0` on the host — not a
Floci-specific wrapping bug, simply true that this AWS-documented image name
resolves only inside AWS's own CodeBuild infrastructure, never on a public
registry. The course's own Troubleshooting section independently names this
as a known Floci 2.0.1 issue. Fixed by substituting a genuinely public image
(`python:3.12-slim`) via `update-project`, recorded honestly in
`configs/lab-11.env` and the committed project template rather than left as
the guide's non-working literal string.

### 2. A severe, well-isolated finding: CodeBuild phase status does not reflect actual command exit codes

Step 20's deliberate break (the wrong container name in
`config/service.json`, which the buildspec's own `pre_build` grep should
catch and `exit 1` on) was run three separate ways — through the pipeline,
and twice via the direct `--source-type-override S3` escape hatch — and
every single time `PRE_BUILD` reported `SUCCEEDED`, with the whole build
`SUCCEEDED`. The identical broken config, run through the local buildspec
runner (genuine bash execution, no CodeBuild involved), correctly failed at
`pre_build` with the exact expected message and exit code 1. This proves
the buildspec logic itself is correct, and isolates the discrepancy
precisely to how this build reports CodeBuild phase outcomes.

### 3. `UPLOAD_ARTIFACTS` always reports `SUCCEEDED`, but never writes anything, on any invocation path

Across every build attempted — the first correct standalone run, both
pipeline-triggered runs (`r4`, `r5`), and the deliberately-broken run — the
artifact bucket never once gained an object under `build/` or
`usms-enrolment-pipeline/BuildOutput/`. It held only the source zip
throughout the entire lab. A more severe instance of the "accept but drop"
pattern seen elsewhere in this course (Lab 09's permissions boundaries, Lab
10's CloudFront associations): here the phase meant to produce the artifact
reports success while producing nothing, every time, on every path tried.

### 4. `get-pipeline-state`'s per-stage status never updates; `list-action-executions` does

Every execution's top-level status correctly reported `Succeeded`/`Failed`
within seconds, but `get-pipeline-state`'s `stageStates[].latestExecution.status`
stayed `None` throughout this entire lab. `list-action-executions`, queried
for the same execution, correctly reported both actions' real status every
time. `verify-lab-11.sh` and this report rely on the latter.

### 5. `start-build` on a `CODEPIPELINE`-source project succeeds, where real AWS rejects it

After Step 18's conversion, a plain `start-build` with no override flags
returned a real, `SUCCEEDED` build — rather than the
`InvalidInputException`-shaped rejection the guide documents as the expected
behaviour. Recorded per the guide's own instruction for this outcome.

## What was genuinely observed vs. recorded vs. conceptual

**Observed directly:** genuine S3 versioning (two real versions at one key,
cleaned up); the full source-to-build pipeline wiring; real build execution
with a genuinely-pullable substitute image, all ten CodeBuild phases
completing; the local buildspec runner correctly executing and correctly
failing the same logic CodeBuild's reporting could not be trusted to
reflect; genuine source-version create→perturb→read-back (3 real versions);
`list-action-executions` correctly showing both pipeline stages succeeding
on each real execution.

**Recorded but not enforced/observed:** the scoped `iam:PassRole` and
explicit Deny (Floci enforces no IAM); the artifact's actual contents
(Finding 3 makes this unobservable on this build via live CodeBuild — proven
instead via the local runner); CodeBuild phase failure propagation (Finding
2).

**Conceptual only:** build cost, concurrent-build quotas, cross-region
artifact stores, manual approval actions, EventBridge-triggered executions
— none modelled on this build, as the guide's own comparison table
anticipates.

## Verification

`scripts/utilities/verify-lab-11.sh`: **PASS=46 FAIL=0** — matching the
guide's own Path A target exactly. One of the guide's own check expressions
(`^(install|pre_build|build|post_build):` anchored at column 0) had a bug
that would also fail against the guide's own example buildspec, since phase
names are indented under `phases:`; fixed to `^\s*(...)`.
