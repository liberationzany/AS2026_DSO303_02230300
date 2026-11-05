# Lab 10 notes

## Support path

**Path A on every axis.** Step 4's probe reported all six capabilities
`SUPPORTED`, including `cloudfront (list-distributions)` — stronger than
the guide's own illustrative "your build may report CloudFront as
SUPPORTED" hedge, which treats it as a coin flip. `usms-student-data` did
not exist before Step 5, exactly as the guide expects at this point in the
course.

## Step 9 "Your turn" — the deny path

Invoked `usms-edge-viewer-request` with `templates/lab-10-viewer-request-denied.json`
(same event, `x-usms-student` header removed). Result: Status 200, Error
`None` — the function did not fail, it made a decision — with a response
object carrying `status: "403"`, `x-usms-edge: viewer-request-deny`, and no
`uri` key anywhere, exactly as specified.

## Step 21 "Your turn" — proving the filter rules, structurally

No log group exists on this build for any of the three functions (confirmed
at Step 10 and again here), so delivery cannot be observed directly. Per the
guide's own fallback, reasoned from the filter rules instead: `notes/ignore-me.json`
is excluded by the **prefix** rule (`transcripts/`) — the key does not start
with it. `transcripts/evidence/ignore-me.txt` is excluded by the **suffix**
rule (`.json`) — the key does not end with it. Both objects were uploaded for
real (`list-objects-v2` shows all three keys present), proving the uploads
themselves succeeded; only the notifier's reaction to them is unobservable.

## Findings

### 1. CloudFront genuinely available (Path A), but silently drops nested `DefaultCacheBehavior` structures

`create-distribution` succeeds and the distribution reaches `Status: Deployed`
with `Origins`, `Comment` and `Enabled` all persisting correctly on
read-back — but `DefaultCacheBehavior.LambdaFunctionAssociations` and
`DefaultCacheBehavior.ForwardedValues` both read back as empty/`null`,
despite being accepted without error in the request. This is a more
specific, narrower version of the "accept but drop" pattern seen elsewhere
in this course (permissions boundaries, IMDSv2, ALB health-check grace
periods): here it is confined to complex nested objects within one specific
field, while adjacent simple fields on the same resource persist correctly.
`verify-lab-10.sh` therefore verifies `templates/lab-10-distribution-config.json`
(the submitted configuration) rather than the live distribution's read-back
state — the same honest choice Path B makes on a build with no CloudFront at
all, now shown to be the correct choice even on a build *with* CloudFront.

### 2. `--qualifier` is silently ignored by `get-function-configuration` and by `add-permission`

`aws lambda get-function-configuration --function-name usms-transcript-notifier
--qualifier live` (and `--qualifier 1`) both return `Version: "$LATEST"` —
identical to passing no qualifier at all. Confirmed deliberately, trying all
three qualifier forms side by side. Separately, `add-permission --qualifier
live` wrote its resulting resource-policy statement's `Resource` field as the
*unqualified* function ARN, not the `:live`-suffixed one the guide's own
expected output shows, and silently dropped the `--source-account` condition
entirely (only `ArnLike.AWS:SourceArn` survived; the `StringEquals.AWS:SourceAccount`
clause the guide's expected output also shows is simply absent). `list-aliases`
and `get-alias` themselves work correctly and report the true version;
`verify-lab-10.sh` is built on those rather than on any `--qualifier`-dependent
call.

### 3. A severe finding: an outbound network call from inside a Lambda container can hang for minutes and destabilise the whole environment

Invoking `usms-transcript-notifier` with a key that triggers its
`boto3.client("s3").head_object()` call hung for over three minutes before
the AWS CLI itself gave up with a read timeout — far past the function's own
configured 30-second `--timeout` — and left the entire Floci endpoint
unreachable afterward, requiring a full Docker Desktop restart to recover.
This is a materially worse outcome than the guide's own anticipated "a quick
`ClientError`" — the guide's own built-in try/except in `notifier.py`
correctly catches a *raised* exception, but nothing in the handler or in
Floci's own timeout enforcement bounds a *hung* one. Isolated and confirmed
by a follow-up invoke on a key that bypasses the boto3 call entirely (via the
handler's own early-exit on a non-`transcripts/`-prefixed key), which
completed in 1.74 seconds — proving the function, deployment, alias and
permission are all otherwise healthy, and that the hang is specific to that
one outbound call. Documented rather than reproduced a second time, given the
cost of the first occurrence.

### 4. Two new Windows/Git-Bash path-resolution findings, both distinct from the earlier MSYS bugs

`$COURSE_ROOT`, as set by this repo's own `configs/course.env`
(`"$HOME/aws-floci-course"`), does not match this repo's actual location
(nested under `OneDrive/Desktop/AS2026_DSO303_02230300/`), causing
`python -m zipfile -c "$COURSE_ROOT/outputs/..."` to fail with
`FileNotFoundError` against a path that was never going to exist. Worked
around by overriding `COURSE_ROOT` to `$(pwd)` for the session. Separately,
the plain native `aws` CLI binary on this machine resolves a `fileb:///tmp/...`
path argument the same wrong way `python.exe` does (as `C:\tmp\...`, not the
Git-Bash `/tmp` mount) — the same root cause identified in Lab 09's Finding
6, now confirmed to affect the `aws` CLI's own paramfile loading as well as
Python's `open()`. Worked around, as in Lab 09, by using a repo-relative path
instead of `/tmp`.

## Review questions

**1. Moving the whole enrolment API to Lambda@Edge "because it will be
faster for everyone" — the two strongest arguments against, and when they'd
be right.** First: environment variables are forbidden at the edge (Step
14), so every piece of configuration the enrolment API currently reads from
its ECS task definition's environment (database connection details, feature
flags, the campus identifier Lab 04's notes mention) would have to be baked
into deployed code, turning every configuration change into a code deploy and
version publish. Second: Lambda@Edge's memory and timeout caps depend on
trigger point — 128 MB/5 s at viewer-request, 10,240 MB/30 s at
origin-request — and an enrolment API doing real work (a database write, a
transaction) is far more likely to need the regional Lambda or ECS shape than
either edge ceiling, especially since real AWS enforces these and Floci's
non-enforcement here would hide the mismatch until production. The one
situation where they'd be right: a genuinely stateless, read-only, low-latency
decision that needs no per-call configuration beyond constants — exactly
what Step 7's auth gate and Step 12's header injection already are. The
enrolment API's actual write path is the opposite of that shape.

**2. CloudFront Functions vs. Lambda@Edge.** CloudFront Functions run a
restricted JavaScript subset, viewer-request and viewer-response only, with
sub-millisecond execution and no network access, at a fraction of Lambda@Edge's
cost; Lambda@Edge runs full Node.js or Python at all four trigger points,
with higher latency and cost but the ability to make network calls (subject
to its own timeout) and use more of the language. Adding `/index.html` to a
URI: CloudFront Functions — pure string manipulation, viewer-request, no
external call, the cheapest and fastest tool for the job. Checking a JWT
signature: also CloudFront Functions if the key material can be embedded or
fetched via its limited KeyValueStore — no external network call is needed to
verify a signature against a known public key, and Step 7's own auth-gate
precedent (checking a header, not calling out anywhere) suggests this course's
JWT check would be shaped the same way. Fetching a per-user redirect from
DynamoDB: Lambda@Edge, specifically at origin-request or viewer-request
depending on whether the origin should ever see the original request — a
network call to DynamoDB is categorically outside what CloudFront Functions
can do at all.

**3. Security headers at origin-response, not viewer-response — same output,
different cache cost.** A header added at origin-response is computed once
per cache miss and then stored as part of the cached object; every
subsequent cache hit serves it for free, with the origin-response function
never invoked again for that object until the TTL expires. The identical
header added at viewer-response would be recomputed on literally every
request, cache hits included, since viewer-response fires after the cache
regardless of whether the response came from cache or the origin — for a
function this cheap the extra invocations are a cost difference, not a
correctness one, but it is real: Step 12's choice amortizes the work across
every request sharing one cache entry, where viewer-response would not. A
requirement that would force viewer-response despite the cost: anything that
must differ per *request* rather than per cached *object* — e.g., echoing
back the actual client IP in a response header for request tracing, which a
cached origin-response value could never do correctly for the next client
that hits the same cache entry.

**4. The notifier's execution role vs. its resource policy — not redundant,
answering different questions.** The execution role (`s3:GetObject` via
`USMSLambdaBasic`) governs what the notifier's *own code* may do when it
calls AWS APIs as itself — specifically, `head_object` reading the uploaded
transcript back. The resource policy (`s3.amazonaws.com` may
`lambda:InvokeFunction`) governs who may *invoke the function at all* — here,
the S3 service acting on the bucket's behalf. Delete the execution role's
grant and the function still gets invoked correctly on every upload, but
every `head_object` call inside it starts failing with `AccessDenied` (on
real AWS; on this build, `read_error` either way, since nothing is enforced).
Delete the resource-policy statement instead, and S3 can no longer invoke the
function at all — the notification configuration remains valid-looking, the
upload still succeeds, and nothing anywhere reports an error, because from
S3's side an unauthorized invocation attempt and a successful-but-silent one
look identical without CloudTrail. The two controls answer "what can this
code do" and "who may run this code," which is exactly Lab 09's
identity-versus-resource-policy distinction, reapplied to Lambda instead of
IAM roles.

**5. `--source-arn`/`--source-account` and Lab 09's confused-deputy
conditions — the same idea, concretely.** Without them, the statement reads
"any S3 bucket in any AWS account may invoke this function" — a bucket
owned by someone else entirely, in another account, naming the exact same
service principal, could invoke `usms-transcript-notifier` and have it run
arbitrary S3 reads using *this* function's execution role, exactly the
confused-deputy shape Lab 09 Step 7 fixed on `usms-ecs-task-role`'s trust
policy with `aws:SourceAccount`/`aws:SourceArn` conditions. The mechanism is
identical — pin the request to a specific resource in a specific account,
so the service principal's broad grant narrows to "only when acting on
behalf of the one thing I actually trust" — expressed as a trust-policy
`Condition` block in Lab 09 and as `add-permission` flags here, because one
is a sts:AssumeRole statement and the other is a resource-policy statement,
but the underlying defence is the same sentence: a service principal alone
is never enough; it must be scoped to the one caller that legitimately uses
it.

**6. Environment variables on an edge function — the call succeeds, the
configuration is invalid, and what that implies.** `update-function-configuration`
validates against *Lambda's* rules alone — environment variables are a
completely ordinary, legal Lambda feature, so the call has nothing to object
to. The Lambda@Edge-specific restriction is enforced by a *different* service,
at a *different* API call: CloudFront's `create-distribution`/`update-distribution`,
which checks the function it is about to associate and rejects the whole
operation with `InvalidLambdaFunctionAssociation` if environment variables
are present. On this build neither enforcement happens, so Step 14's
deliberate mistake succeeded with no error at either layer, and the only way
to have caught it is to check statically rather than wait for a rejection
that will never come here. This is the same rule the course has stated
since its first lab, now demonstrated at the boundary between two separate
AWS services rather than within one: a command that reports success is
evidence it ran, never evidence it did what you meant — and when the
real check lives in a different service's different API call entirely, "it
succeeded" tells you even less than usual.
