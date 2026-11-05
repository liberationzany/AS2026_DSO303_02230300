# Lab 11 notes

## Support path

**Path A — full.** `cicd-support-probe.sh` confirmed `codebuild create-project`
genuinely accepted and the throwaway project deleted cleanly, and
`codepipeline list-pipelines` answers. Also notable: `codedeploy
list-applications` answers too, stronger than the guide's own "very likely
absent" expectation for CodeDeploy — relevant for Lab 12's blue/green design.

## Step 15 compare-block — what if `Resource` were `"*"` but the condition were kept?

If `USMSDeployBase`'s `iam:PassRole` statement named `Resource: "*"` while
keeping `Condition: {StringEquals: {iam:PassedToService: [...]}}`, the
condition alone does not name *which* role may be passed — only *which
service* it may be passed to. An attacker (or a careless later change) could
then pass **any** role in the account — including `usms-deploy-role` itself,
or any future administrator role — to `ec2.amazonaws.com` or
`ecs-tasks.amazonaws.com`, and the condition would still be satisfied. The
specific role an attacker would name: whichever role in the account carries
the broadest permissions and trusts one of the two conditioned services —
on this account, `usms-ecs-task-role` is the obvious target, since passing
it to a new ECS task definition inherits `USMSStudentDataReadWrite`
immediately. `Resource` naming three specific ARNs is what actually closes
the escalation path Lab 09 Step 8 describes; the `Condition` alone only
narrows *where*, never *what*.

## Step 19 "Your turn" — version counts, and why they are not necessarily equal

After rolling to `r5`: `source/usms-enrolment-src.zip` has **3** versions
(`r3`, `r4`, `r5` — confirmed via `list-object-versions`,
`length(Versions)=3`). `usms-enrolment-pipeline/BuildOutput/` has **0**
objects — not "fewer than 3", literally zero, confirmed by listing the
entire bucket. The two numbers are not necessarily equal for the reason the
guide gives (not every source upload triggers an execution, and not every
execution necessarily produces a counted artifact) — but on this build the
reason is sharper than that: **no execution of any kind, standalone or
pipeline-triggered, successful or deliberately broken, ever wrote an
artifact object to this bucket at all.** `UPLOAD_ARTIFACTS` reports
`SUCCEEDED` in every case; the object simply never appears. See Findings
below.

## Findings

### 1. `aws/codebuild/standard:7.0` cannot be pulled — confirmed as a genuine, documented Floci issue

`start-build` against the project as originally configured completed
immediately with `buildStatus: FAULT`, failing at `COMPLETED` with
`Status 404: pull access denied for aws/codebuild/standard, repository does
not exist or may require 'docker login'`. Reproduced identically with a
direct `docker pull aws/codebuild/standard:7.0` on the host, outside Floci
entirely — this is not a Floci wrapping bug, it is simply true that AWS's
documented CodeBuild image name is not a publicly resolvable registry
reference; it exists only inside AWS's own CodeBuild infrastructure. The
course's own Troubleshooting section independently confirms this is a known
issue on "Floci 2.0.1." Fixed by substituting a genuinely public image
(`python:3.12-slim`) via `update-project`, recorded honestly in
`configs/lab-11.env`'s `USMS_BUILD_IMAGE` and in the committed
`templates/lab-11-codebuild-project.json`, rather than left as the
guide's literal (non-working) string.

### 2. Once given a real image, builds genuinely execute every phase for real

With the substituted image, a standalone build completed with all ten
phases (`SUBMITTED` through `COMPLETED`) reporting `SUCCEEDED`, in
well under the normal provisioning delay the guide anticipates — this build
pulls the (small) substitute image fast enough that the "stuck in
PROVISIONING" scenario the guide's own Floci Limitation describes never
materialised.

### 3. A severe, well-isolated finding: CodeBuild's phase status does not reflect the actual exit code of buildspec commands

Step 20's deliberate break (renaming the container in `config/service.json`
so the `pre_build` grep should `exit 1`) was run three different ways —
through the pipeline, and twice directly via the `--source-type-override S3`
escape hatch — and in every case `PRE_BUILD` reported `SUCCEEDED`, with the
overall build `SUCCEEDED`. The identical broken configuration, run through
`usms-buildspec-run.sh` (the local runner, genuine bash execution), correctly
failed at `pre_build` with the exact expected message
(`config/service.json names the wrong container`) and exit code 1. This
proves the buildspec's own logic is correct and that the discrepancy is
specific to how this Floci build reports CodeBuild phase outcomes — it does
not derive phase status from whether the phase's commands actually
succeeded.

### 4. `UPLOAD_ARTIFACTS` always reports `SUCCEEDED` but never writes anything

Across every build attempted in this lab — the first standalone run with the
correct config, the pipeline-triggered runs at `r4` and `r5`, and the
deliberately-broken run — `usms-pipeline-artifacts` never once gained an
object under `build/` or under
`usms-enrolment-pipeline/BuildOutput/`. The bucket held only
`source/usms-enrolment-src.zip` throughout this entire lab. This is a
distinct, more severe instance of the "accept but drop" pattern seen
elsewhere in this course (CloudFront's `LambdaFunctionAssociations` in Lab
10, permissions boundaries in Lab 09): here, the phase that is supposed to
produce the artifact reports success while producing nothing at all, on
every single invocation path tried.

### 5. `get-pipeline-state`'s per-stage status never updates; `list-action-executions` does

`get-pipeline-state --query 'stageStates[].latestExecution.status'` read
`None` for both stages after every execution in this lab, even though the
pipeline's own top-level execution status correctly reported `Succeeded`
(or `Failed`, for the broken run) within seconds. `list-action-executions`,
queried for the same execution ID, correctly reported both actions'
individual status every time. `verify-lab-11.sh` and this report rely on the
latter, not the former.

### 6. `start-build` on a `CODEPIPELINE`-source project does not error, as the guide expects

After Step 18's conversion, `aws codebuild start-build --project-name
usms-enrolment-build` (no override flags) returned a real build object and a
`SUCCEEDED` result, rather than the `InvalidInputException`-shaped rejection
the guide documents as "the expected result" on real AWS. Recorded per the
guide's own instruction for this case ("If it succeeds, note it in Section
11's 'recorded, not observed' list").

### 7. A shell gotcha, not a Floci issue: `aws` inside a `command | while read` loop

Step 6's cleanup loop (`list-object-versions | while read -r key vid; do aws
s3api delete-object ...; done`) silently deleted nothing — the loop appeared
to run but the probe object's two versions were still present afterward.
Resolved by deleting each version with a direct, non-piped `aws` call
instead. This is a known category of bug (a command that itself reads stdin,
invoked inside a `while read` loop fed by a pipe, can consume the loop's own
input stream) rather than anything specific to this course's emulator.

## Review questions

**1. Source and Build both succeed, the application is unchanged — two
explanations, two one-command tests.** First explanation:
`artifacts.base-directory` names a directory the build phase never actually
wrote to (a typo, or a phase that silently skipped its `mkdir`/`cp` because
an earlier `grep` failed without `exit 1`) — the artifact that gets uploaded
is empty or stale, but the upload itself succeeds, so nothing downstream
notices. Test it with: `aws codebuild batch-get-builds --ids <id> --query
'builds[0].artifacts.location'` followed by actually downloading and
listing that object's contents — if the files inside don't match what
`post_build`'s `ls -l dist` printed in the log, the base-directory is wrong.
Second explanation: the source zip itself has an extra top-level directory
(`app/buildspec.yml` instead of `buildspec.yml` at the root), so CodeBuild
is silently building an *old*, previously-cached, correctly-shaped source
version rather than the one just uploaded — Source "succeeds" because the
fetch itself works, it just fetches the wrong shape and CodeBuild may fall
back to a last-known-good interpretation rather than erroring. Test it with:
`unzip -l outputs/usms-enrolment-src.zip | head -1` — if the first real entry
starts with `app/`, that is the entire explanation.

**2. Why does CodePipeline require S3 source versioning — not "so you can
roll back," but what an execution needs to record about itself.** Every
pipeline execution must be traceable to the exact, immutable bytes it
consumed, permanently, even after the object at that key has since been
overwritten a dozen times. Without versioning, "the Source stage for
execution #47 read `source/usms-enrolment-src.zip`" is a statement about a
*key*, which is mutable and tells you nothing once the key has moved on;
with versioning, CodePipeline can record the specific `VersionId` it
fetched, making the statement "execution #47 read version `82dc3602-...`"
permanently and unambiguously true regardless of what the key holds now.
That is a property about the *audit record of a single execution*, not
about operational recovery — rollback is a nice side effect of the same
mechanism, not the reason it exists.

**3. `iam:PassRole` is not redundant with permission to create the project.**
The objection assumes that once you may create something, you must
automatically control everything about what it becomes — but a role's
*identity* is a separate, more dangerous thing than the project's other
settings (image, timeout, compute size), because a role comes with
standing permissions the created resource will exercise as itself, on an
ongoing basis, without further authorization checks. If creating a project
also implicitly authorized passing it any role, then anyone permitted to run
`codebuild:CreateProject` at all — a routine, low-stakes-sounding permission
— could silently also hand an administrator role to a build container they
control, and have that container assume administrator privileges the moment
it starts. `iam:PassRole` is the separate gate specifically on *which*
standing identity a new resource is allowed to inherit, independent of
whatever other configuration you're also allowed to set — which is exactly
why Lab 09's `USMSDeployBase` and this lab's `usms-codepipeline-policy.json`
both scope it to named ARNs rather than leaving it implied by
project-creation permission.

**4. Two roles vs. one role with the union of both policies.** For the
two-role design: blast radius. If `usms-codebuild-role`'s credentials ever
leaked from inside a compromised build container (a realistic threat model —
build containers run arbitrary, often third-party, code), the damage is
bounded to the artifact bucket and that project's own log group; it can
never start a build itself, never touch the pipeline, never pass a role
anywhere. A single merged role would hand that same compromised container
`codebuild:StartBuild` and `iam:PassRole` as well, turning a leaked build
credential into a pipeline-controlling one. The strongest argument against
the two-role design: operational friction without functional benefit on a
system where the two principals are in practice always controlled by the
same team and the same trust boundary — every policy change now needs to be
reasoned about twice, attached twice, and kept in sync twice (as Lab 12's
own "creates version 2 of `USMSCodeBuildBase` ... and sets it default"
handoff note makes concrete), for a separation that only pays off against a
threat (a compromised build container specifically, as opposed to a
compromised pipeline or a compromised human operator) that is real but
narrow.

**5. Three heredoc forms, side by side — what breaks if each were the other,
with no error message.** `<< 'BUILDSPEC'` (Step 8): if this were unquoted,
every `$USMS_RELEASE`, `$ARTIFACT_DIR` and `${CODEBUILD_BUILD_ID:-local}`
would be evaluated *now*, in the authoring shell, against variables that are
either unset or meaningless outside a running build — the file written to
disk would contain empty strings or garbage where live build-time values
belong, and `buildspec.yml` would still be syntactically valid YAML, so
nothing would complain until a real build ran and silently stamped empty
values. `<< META` nested inside it: if this were quoted, the JSON written
into `build-metadata.json` would contain the literal, un-substituted text
`$SERVICE_NAME`, `$USMS_RELEASE` etc. instead of real values — again valid
JSON, again no error, just quietly wrong content discovered only when
something later reads `release` and gets a template string. `<< EOF` in
Step 21 (`configs/lab-11.env`): if this were quoted, every `$(aws ...)` call
would be written into the file as literal, un-executed shell syntax; sourcing
the file would set each variable to that literal text rather than a real
value, and `grep -n 'export .*=$'` wouldn't even catch it, because the lines
aren't empty — they just contain command text instead of its result. In
every case the failure mode is identical: syntactically valid output,
semantically wrong content, and no error at any layer — which is exactly why
this course keeps insisting on the "do I want this expanded now or later"
question asked explicitly, rather than relying on a tool to catch getting it
backwards.

**6. "Remove `pre_build`'s configuration validation because the deploy
stage checks it anyway."** They are right only when the deploy stage's check
runs *before* anything externally visible happens, fails loudly in a way
that is at least as fast and at least as cheap as this `pre_build` check,
and the two checks are genuinely redundant rather than checking different
things at different points in the pipeline's timeline — none of which is
true here. `pre_build` catches the mistake in roughly the time this lab's
own standalone build phases took (seconds), before the build phase has done
any work and before anything is uploaded anywhere; a hypothetical deploy
stage would only discover the same mistake *after* the Source and Build
stages have both already run, an artifact has already been produced and
stored, and (in Lab 12's architecture) possibly after an image has already
been pushed to a registry — catching the same root cause at a strictly more
expensive point in the pipeline. They would be expensively wrong whenever
the deploy stage's check is the *only* remaining check, because then a
`pre_build` mistake is caught only after consuming a build's worth of
compute and storage, and in a design where the deploy stage might run much
later (a manual approval gate, a scheduled deploy window) the feedback loop
for "I named the wrong container" could stretch from seconds to hours.

**7. Proving `r4` was built from a specific, dated source — the evidence
chain, and its weakest link.** The chain: (1) `source/usms-enrolment-src.zip`
version `82dc3602-...` (or whichever `VersionId` was current at upload time)
is the immutable, timestamped source S3 itself records
(`list-object-versions` gives both the ID and `LastModified`); (2) the
pipeline execution that consumed it is recorded by `list-action-executions`,
naming which source version the Source stage fetched; (3) the resulting
`build-metadata.json` — on a build where the artifact genuinely gets
written, which this lab's own investigation shows is not guaranteed on this
specific emulator — would carry `"release": "r4"` and a
`sourceVersion` field that should match link (1)'s `VersionId` if
`CODEBUILD_RESOLVED_SOURCE_VERSION` is populated correctly. The weakest
link, demonstrated directly in this lab: link (3). This build's own
`UPLOAD_ARTIFACTS` phase never actually produces that file at all (Finding
4), so on *this specific emulator* the chain is provably broken at exactly
the step meant to tie the source version to the finished, dated artifact —
on real AWS the weakest link would instead be whichever human process put
the *right* bytes into the source zip before upload, since nothing in this
chain can attest to what a developer's laptop actually contained before
`usms-pack-source.sh` ran.
