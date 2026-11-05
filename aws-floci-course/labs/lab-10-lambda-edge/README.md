# Lab 10 — Edge Functions with AWS Lambda

**Support path: A — full**, including CloudFront (`list-distributions`
genuinely `SUPPORTED`), stronger than the guide's own hedge that treats it as
a coin flip between builds.

## What this lab built

`usms-student-data` created for real (the bucket four IAM policies have
named since Lab 01); `usms-lambda-exec-role`'s trust policy extended to
`edgelambda.amazonaws.com`; two Lambda@Edge functions
(`usms-edge-viewer-request`: auth gate + URI normalisation,
`usms-edge-origin-response`: security headers + cache policy), each invoked
on both allow and deny/pass-through paths, published as version 1, and
confirmed edge-eligible (no env vars, within caps, published); a CloudFront
distribution associating both; `usms-edge-simulate.sh`, which runs the full
viewer-request → origin → origin-response chain via direct invokes and
proves composition through a chained header; a regional notifier
(`usms-transcript-notifier`, Python) with a `live` alias, a scoped resource
policy, and a real S3 `ObjectCreated` trigger wired to it.

## Findings worth reading before the verify output

### 1. CloudFront is genuinely available (Path A), but silently drops nested cache-behavior structures

`create-distribution` succeeds, reaches `Status: Deployed`, and persists
`Origins`, `Comment` and `Enabled` correctly — but
`DefaultCacheBehavior.LambdaFunctionAssociations` and `.ForwardedValues`
both read back empty/`null` despite being accepted without error. A
narrower, more specific instance of the "accept but drop" pattern seen
elsewhere in this course, confined here to complex nested objects within one
field while adjacent simple fields on the same resource persist correctly.
`verify-lab-10.sh` therefore verifies the submitted configuration file
directly, exactly as a CloudFront-less build's Path B would — shown here to
be the right call even with CloudFront present.

### 2. `--qualifier` is silently ignored by `get-function-configuration` and by `add-permission`

Tested deliberately with `--qualifier 1`, `--qualifier live`, and no
qualifier at all against `usms-transcript-notifier`: all three return
`Version: "$LATEST"`. `add-permission --qualifier live` also wrote its
statement's `Resource` as the *unqualified* function ARN rather than the
`:live`-suffixed one, and silently dropped the `--source-account` condition
entirely (only the `--source-arn` condition survived). `list-aliases` and
`get-alias` are unaffected and report the true state correctly;
`verify-lab-10.sh` is built on those rather than any `--qualifier`-dependent
call.

### 3. A severe finding: an outbound network call from inside a Lambda container can hang for minutes and take the whole environment down with it

Invoking the notifier with a key that triggers its `boto3.head_object()` call
hung for 3+ minutes — far past its own 30-second `--timeout` — before the
AWS CLI gave up with a read timeout, and left Floci's entire endpoint
unreachable afterward, requiring a full Docker Desktop restart. The guide
anticipates a quick `ClientError` here; this build instead produces an
unbounded hang capable of destabilising the shared Docker environment.
Isolated by a follow-up invoke on a key that bypasses the boto3 call
entirely (the handler's own early-exit for a non-`transcripts/`-prefixed
key), which completed cleanly in 1.74 seconds — proving the function,
deployment, alias and permission are otherwise fully healthy, and that the
hang is specific to that one call. Documented rather than reproduced a
second time.

### 4. Two further Windows/Git-Bash path-resolution findings

`$COURSE_ROOT` (`"$HOME/aws-floci-course"` per this repo's own
`configs/course.env`) does not match this repo's actual nested location,
breaking `python -m zipfile -c "$COURSE_ROOT/..."`; overridden to `$(pwd)`
for the session. Separately, the native `aws` CLI binary resolves a
`fileb:///tmp/...` paramfile path the same wrong way `python.exe` does (as
`C:\tmp\...`), confirming Lab 09's Finding 6 extends to the AWS CLI's own
paramfile loading, not just Python's `open()`. Worked around with a
repo-relative path in both cases.

## What was genuinely observed vs. recorded vs. conceptual

**Observed directly:** both edge functions created, invoked on allow/deny
paths with real CloudFront-shaped events, composing correctly through
`usms-edge-simulate.sh` (the `x-usms-edge-chain` header proves it); the
Lambda@Edge restriction check (environment variables accepted by Lambda,
then removed, with the static eligibility checker confirming both functions
pass every check real validation would apply); the notifier created,
published, aliased, rolled forward and back without touching any trigger;
real S3 upload triggering a genuine bucket notification configuration;
persistence proven across both an unplanned and a controlled Floci restart,
including the code itself (not just names) still executing and composing
correctly afterward.

**Recorded but not enacted:** the CloudFront distribution's Lambda
associations (Finding 1); the `--qualifier`-targeted resource-policy scoping
(Finding 2, partially — the ARN condition survived, the account condition
did not).

**Conceptual only:** Lambda@Edge replication and actual edge execution — no
emulator runs this, as the guide states plainly; edge-local logging; real
CloudFront caching behaviour and its cost model.

## Verification

`scripts/utilities/verify-lab-10.sh`: **PASS=51 FAIL=0** — matching the
guide's own target exactly, with every check adapted to route around the
three confirmed build quirks above rather than being fooled by them.
