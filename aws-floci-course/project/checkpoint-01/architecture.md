# USMS - Architecture, Checkpoint 1

## The system as it stands

```text
IDENTITY (Lab 01)                              NETWORK (Lab 02)
├── groups: usms-admins, usms-developers,       ├── usms-vpc (10.0.0.0/16), 4 subnets / 2 AZs
│           usms-auditors                       ├── IGW, NAT, route tables
├── users:  usms-admin-01, usms-dev-01,          └── security groups (app, db, bastion, ALB)
│           usms-audit-01
├── roles:  usms-ec2-app-role, usms-lambda-                      │
│           exec-role, usms-developer-role,                      │
│           usms-ecs-exec-role, usms-ecs-task-role,               v
│           usms-codebuild-role, usms-codepipeline-role,   COMPUTE (Labs 03-05, 07-08, 12)
│           usms-eks-cluster-role, usms-eks-node-role,     ├── usms-web-01, usms-db-01 (EC2)
│           usms-deploy-role, usms-transcripts-reader-role ├── usms-ecs-cluster
├── policies: USMSDeveloperBase, USMSStudentData-          │   └── usms-enrolment-svc (2 tasks)
│   ReadWrite, USMSStudentDataReadOnly,                     │       behind usms-enrolment-alb
│   USMSAssumeAppRoles, USMSLambdaBasic,                    └── usms-eks-cluster (k3s)
│   USMSECSTaskExecution, USMSEKSClusterPolicy,                 └── usms-enrolment-hpa (pod autoscaling)
│   USMSEKSNodePolicy, USMSDeployBase,
│   USMSCodeBuildBase (v2), USMSCodePipelineBase (v2),
│   USMSObservabilityWrite, USMSPermissionsBoundary
└── instance profile: usms-ec2-app-profile

STORAGE + FUNCTIONS (Labs 06, 09, 10)                PIPELINE (Labs 11-12)
├── usms-student-data (S3)                           ├── usms-enrolment-pipeline
│   ├── transcripts/*  ──notification──┐              │   Source(S3) -> Build(CodeBuild) -> Deploy(ECS)
│   └── bucket policy draft (Lab 09,                  │     (Deploy stage's ECS provider is UNSUPPORTED
│       never applied - see gaps.md)   │              │      on this build - deployed by hand instead)
├── usms-pipeline-artifacts (S3)        │              ├── usms-enrolment-build (CodeBuild)
└── 3 Lambda functions                  v              └── usms-enrolment (ECR), images r6/r7
    ├── usms-edge-viewer-request:1      │
    ├── usms-edge-origin-response:1     │
    └── usms-transcript-notifier  <─────┘
        alias "live" -> version 4 (instrumented + active tracing)
        versions 1 (Lab 10 original) .. 4 (Lab 13 traced)

OBSERVABILITY (Lab 13)
├── logs: /usms/central/application (30d), /usms/ecs/enrolment (30d),
│         /aws/lambda/usms-transcript-notifier (14d), edge fn logs (14d)
├── metrics: USMS/Application - NotifyCount, CentralErrorCount,
│            TranscriptsProcessed{Faculty,Stage}, TranscriptLagSeconds{Stage}, EdgeDenyCount
├── alarms: usms-transcript-lag-high, usms-notify-silence
│           (usms-transcript-pipeline-down composite - DOCUMENT ONLY, see gaps.md)
└── usms-overview dashboard - DOCUMENT ONLY (put-dashboard unsupported, see gaps.md)
```

The edges that matter: `usms-ec2-app-role` and `usms-lambda-exec-role` were both created in Lab 01
naming resources (the S3 bucket, later the observability namespace) that did not exist for many
labs afterward. The S3 bucket's own notification configuration is the only thing that turns an
`s3:PutObject` into a running Lambda invocation - nothing in IAM expresses that link. The pipeline's
Build stage writes `imagedefinitions.json`, which is the only channel through which a new container
image reaches the ECS service; the Deploy stage that was supposed to consume it automatically does
not run on this build, so that channel is currently closed by hand instead (see `gaps.md`).

## Three dependencies worth tracing

**1. `USMSStudentDataReadWrite` named a bucket that did not exist for five practicals.**
This policy was written and attached to `usms-ec2-app-role` in Lab 01, naming
`arn:aws:s3:::usms-student-data` and `arn:aws:s3:::usms-student-data/*` as its resources. The
bucket itself was not created until Lab 06. Nothing in IAM validates that a `Resource` ARN refers
to something real at the moment the policy is written or attached - the statement sits inert,
waiting. Lab 09's security review later read this exact statement back out of IAM to confirm the
object-ARN and bucket-ARN split was done correctly (the classic mistake the lab guide itself
warns about: granting `s3:GetObject` on the bucket ARN instead of the `/*` object ARN, which would
fail every read with no policy error at all - just an empty result). If the bucket had been
renamed at any point between Lab 06 and Lab 10, this policy would not have raised an error; S3
access from the EC2 role would simply have started failing with `AccessDenied` on a resource ARN
that looked correct in the policy document and wrong in the world, which is a much harder bug to
spot than a syntax error.

**2. The `live` alias on `usms-transcript-notifier` is what every other piece of configuration
actually points at.** Lab 10 created the function, published version 1, and created the alias
`live` pointing at it. Every piece of wiring built afterward - the S3 bucket's event notification
(`LambdaFunctionArn`), the function's own resource-based policy letting S3 invoke it (Lab 09/10,
scoped with `aws:SourceAccount`/`aws:SourceArn` against the confused-deputy problem) - names the
**alias ARN**, never the function's bare ARN or a specific version number. Lab 13 repointed that
one alias twice (version 1 to version 3 for the instrumented handler, then to version 4 to add
active tracing) and nothing else in the system needed to change. This is precisely the mechanism
that would break the whole pipeline silently: if a future deploy published a new version but
*forgot* the `update-alias` call, every real S3-triggered invocation would keep running the old
code forever, while a manual `aws lambda invoke --qualifier $LATEST` during testing would show the
new code working perfectly - the exact "it passed my test, production is still broken" trap. This
is not hypothetical for this project: Lab 13's own Step 13 "Your turn" (roll back to version 1,
confirm, roll forward) was the moment this was actually exercised, and it surfaced a second,
sharper finding - on this Floci build, published versions do not actually freeze distinct code
(see `gaps.md`), which means the alias mechanism's *purpose* (instant, safe rollback) does not
fully hold here even though the alias *mechanics* (repointing, invoking through it) do.

**3. `USMSECSTaskExecution`'s ECR pull permissions were written for a repository that did not
exist until Lab 12.** Lab 01's execution-role policy for ECS tasks included the four `ecr:*`
actions a task execution role needs to pull a container image (`GetAuthorizationToken`,
`BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability`), scoped broadly because
no specific repository ARN existed yet to scope them to. Those four actions sat unused for eleven
labs. Lab 12 created the `usms-enrolment` ECR repository, pushed a real image to it, and for the
first time the ECS task execution role actually needed to exercise that permission to pull a
*private* image (Lab 04's placeholder had used a public image and needed none of it). If that
original Lab 01 statement had been scoped to a specific repository ARN guessed in advance - rather
than left broad, as it correctly was - and the guessed name had not matched `usms-enrolment`, every
task launch from Lab 12 onward would have failed with an ECR pull error that looks, superficially,
like a Docker or networking problem, when the actual cause is an IAM decision made in the very
first lab of the course.

## One decision I would now make differently

Lab 01 created a single `usms-lambda-exec-role`, described as the execution role for "notification
functions" generally, and all three Lambda functions in this system (`usms-edge-viewer-request`,
`usms-edge-origin-response`, `usms-transcript-notifier`) ended up using variants of this same
shared-role pattern. By Lab 13, `USMSObservabilityWrite` - which grants `logs:PutLogEvents` across
every `/usms/*` and `/aws/lambda/usms-*` log group, `cloudwatch:PutMetricData` into the whole
`USMS/Application` namespace, and `xray:PutTraceSegments` - was attached to that same role. The
two edge functions have no business publishing custom metrics or sending traces; they get that
ability anyway, purely because they share an execution role with the one function that does. I
understood this clearly enough by Lab 09 (the security-hardening lab, whose entire premise is
least privilege and blast-radius reduction) to recognise that sharing one execution role across
functions with genuinely different jobs is exactly the pattern that lab argues against - and I
would now give each function its own role: a minimal one for the two edge functions (CloudFront
and basic logging permissions only) and only the notifier gets the observability grant. This was
not a mistake at the time - the labs' own instructions set up the shared role in Lab 01 before
Lab 09's security lens existed in the project - but it is a decision I now understand well enough
to disagree with, and would change in a Checkpoint 2 pass.

## The trust boundary

Every place one component is allowed to act on another, and what grants it:

| Who acts | On what | Granted by |
|---|---|---|
| EC2 instances (`usms-web-01`, `usms-db-01`) | AWS APIs as `usms-ec2-app-role` | Instance profile `usms-ec2-app-profile`; trust policy allows `ec2.amazonaws.com` |
| ECS tasks, execution side | Pull ECR images, write logs | `usms-ecs-exec-role` via `USMSECSTaskExecution`; trust allows `ecs-tasks.amazonaws.com` |
| ECS tasks, application side | S3/other AWS calls at runtime | `usms-ecs-task-role` (separate from the execution role, same trust principal) |
| Lambda functions | Logs, S3, metrics, traces | `usms-lambda-exec-role`; trust allows `lambda.amazonaws.com` |
| S3 (`usms-student-data`) | Invoke `usms-transcript-notifier:live` | The function's own **resource-based policy**, conditioned on `aws:SourceAccount`/`aws:SourceArn` against the confused-deputy problem - not an identity policy at all |
| S3 (`usms-student-data`) | Trigger an invocation in the first place | The bucket's **event notification configuration** - a resource-level wiring with no IAM representation whatsoever |
| CodePipeline | Start CodeBuild, update the ECS service, read/write the artifact bucket | `usms-codepipeline-role` via `USMSCodePipelineBase` v2; trust allows `codepipeline.amazonaws.com` |
| CodeBuild | Push/pull ECR, write logs, read S3 source | `usms-codebuild-role` via `USMSCodeBuildBase` v2; trust allows `codebuild.amazonaws.com` |
| A human developer (`usms-dev-01`) | Elevated build permissions, temporarily | `sts:AssumeRole` on `usms-developer-role` - requires **both** the role's trust policy naming the user **and** the user's own group policy (`USMSAssumeAppRoles`) granting the assume-role call. Either half missing is a silent `AccessDenied` |
| EKS nodes | Join the cluster, pull images | `usms-eks-node-role` via `USMSEKSNodePolicy`; trust allows `ec2.amazonaws.com` (nodes are EC2-backed) |
| EKS control plane | Manage cluster resources | `usms-eks-cluster-role` via `USMSEKSClusterPolicy`; trust allows `eks.amazonaws.com` |
| A metric filter | Count a log line as an event | **Nothing in IAM at all** - `usms-notify-count` depends entirely on the notifier continuing to print the literal string `USMS_NOTIFY`. No policy, type system, or contract enforces this; a refactor of the log line silently zeroes the metric with no error anywhere in the stack |
| CodeBuild's build container | Build and push a Docker image | `privilegedMode: true` on the CodeBuild project - a capability grant at the project-configuration level, not an IAM statement, and one that would be a real security concern on a shared build fleet |

The two rows with no IAM representation at all (the bucket notification wiring, and the metric
filter's dependence on log format) are the ones this checkpoint's brief specifically warns are
easy to miss, and they are the two in this system that actually did cause a real, documented
finding each (Lab 10's notification-to-alias wiring surfacing the version-immutability gap in
Lab 13; the metric filter's text-matching dependence producing a genuine false-positive case,
recorded in Lab 13's own notes).
