# Lab 12 - Deploying to Amazon ECS from the Pipeline

Support path: **A** (Docker, ECR and raw ECS APIs all work on this build -
`outputs/lab-12-deploy-probe.txt`). The application source and its Dockerfile live in
`labs/lab-11-cicd/app/`, alongside the Lab 11 buildspec and local runner; this lab only adds
an image build to that buildspec and a third pipeline stage.

## What this lab built

- ECR repository `usms-enrolment` (MUTABLE, `scanOnPush=true`, AES256).
- `labs/lab-11-cicd/app/Dockerfile` and `.dockerignore` (`FROM nginx:1.27-alpine`, `COPY dist/`).
- Images `r6` and `r7` built, tagged, pushed, and proven present in the registry by deleting
  the local copy and pulling it back **by digest**.
- Task definition family `usms-enrolment` extended via describe-strip-register: revision 3
  names the ECR image, keeping `cpu`, both IAM roles, and (this build's own, already-null)
  health check unchanged.
- `USMSCodeBuildBase` v2 (adds scoped ECR push, `GetAuthorizationToken` on `*`) and
  `USMSCodePipelineBase` v2 (adds a service-scoped `ecs:UpdateService`/`DescribeServices`, an
  unscoped `RegisterTaskDefinition`, and a second `iam:PassRole` for the two ECS roles), both
  created and set as default.
- CodeBuild project updated: `privilegedMode: true`, `IMAGE_REPO_URI` and three other env vars.
- `buildspec.yml` extended to build + push an image (guarded, since this build's CodeBuild
  image has no Docker daemon) and write `imagedefinitions.json`; `tests/smoke.sh` grew an
  eighth assertion validating that file's shape.
- The pipeline grew a third stage, `Deploy` (provider `ECS`), added via the mandatory
  read-modify-write (`get-pipeline` -> append stage -> `update-pipeline`), with the document
  committed at `templates/lab-12-pipeline.json`.
- The rollback drill: a task definition naming a never-pushed tag (`r8`) was registered and
  deployed; rolled back by hand to the known-good revision.
- The blue/green CodeDeploy documents (`templates/lab-12-appspec.yaml`,
  `templates/lab-12-codedeploy-deployment-group.json`) were written and validated, not executed
  - this emulator has no CodeDeploy (`deploy list-applications` does not answer).

## Headline finding: the pipeline's ECS deploy provider is not implemented here

Every other mechanism in this lab is genuinely real on this build - the image push, the task
definition registration, the policy versioning, the pipeline document's three stages with the
correct artifact chain. But `start-pipeline-execution` on the finished three-stage pipeline
returned `status: Failed`, with:

```
Action DeployToECS failed: Provider ECS is not available in Floci CodePipeline
```

`get-pipeline-state` kept every stage's `latestExecution.status` at `None` (the same gap found
in Lab 11); `list-action-executions` gave the real picture - Source and Build both
`Succeeded`, only Deploy `Failed`. To still produce genuine end-to-end evidence, the deploy
action's own four documented steps (describe, strip, change the image, register,
update-service) were reproduced by hand against the real r7 image the build had already
pushed. Full detail and reasoning in `notes/lab-12-notes.md`.

## Other findings

- `ecr describe-images` returns `imageDetails: []` for a repository that genuinely has images
  pushed to it (confirmed again, consistent with Lab 11's artifact-upload finding) - the
  control plane is disconnected from the data plane. Proven via delete-local-then-pull-by
  -digest. `verify-lab-12.sh` checks the data-plane proof recorded in
  `outputs/lab-12-image-digest.txt` instead of the broken API.
- `update-service --task-definition <family>` (no revision) leaves `describe-services`'
  `taskDefinition` field holding the literal unresolved string `usms-enrolment`, not a resolved
  ARN. Supplying the revision explicitly gives the `family:revision` shorthand, not the full
  ARN real AWS returns. Neither form breaks a later `describe-task-definition` call.
- The deployment circuit breaker is stored, not enforced: deploying a task definition naming a
  never-pushed image left the service reporting `runningCount: 2`, `status: ACTIVE`, no events,
  and `services[0].deployments: null` - nothing here ever objected.
- This repository's actual Lab 04 build never set a container-level health check (relies on the
  ALB target group's check instead), so `healthCheck` is genuinely `null` throughout - not a
  bug introduced by this lab's describe-strip-register.

## Verification

`scripts/utilities/verify-lab-12.sh`: **PASS=46 FAIL=0**. See the script for the two checks
adapted around the ECR control-plane gap, and the pipeline checks' note that they verify the
pipeline *document* rather than a live execution, honestly reflecting what this build can
support.
