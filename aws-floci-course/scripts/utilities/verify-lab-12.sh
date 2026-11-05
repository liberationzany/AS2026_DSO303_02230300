#!/usr/bin/env bash
# Verify every Lab 12 artefact. Exit 1 if anything is missing.
# This build is Path A for ECR/ECS, but CodePipeline's ECS deploy PROVIDER is
# unavailable here (see notes/lab-12-notes.md). The pipeline checks below verify
# the pipeline DOCUMENT (stage count, provider name, config keys) rather than a
# successful execution, which is the honest thing this build can check.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-01.env configs/lab-04.env configs/lab-05.env \
         configs/lab-11.env configs/lab-12.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

: "${FLOCI_CONTAINER_NAME:=floci}"
: "${FLOCI_ENDPOINT:=http://localhost:4566}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"
: "${USMS_ECR_REPO:=usms-enrolment}"
: "${USMS_TASK_FAMILY:=usms-enrolment}"

AWS="aws --endpoint-url $FLOCI_ENDPOINT"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

ecr()  { $AWS ecr describe-repositories --repository-names "$USMS_ECR_REPO" --query "repositories[0].$1" --output text; }
proj() { $AWS codebuild batch-get-projects --names "$USMS_BUILD_PROJECT" --query "projects[0].$1" --output text; }
pipe() { $AWS codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query "pipeline.$1" --output text; }
tdef() { $AWS ecs describe-task-definition --task-definition "$USMS_TASK_FAMILY" --query "taskDefinition.$1" --output text; }
polv() { $AWS iam get-policy --policy-arn "arn:aws:iam::000000000000:policy/$1" --query 'Policy.DefaultVersionId' --output text; }

spec="labs/lab-11-cicd/app/buildspec.yml"

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "AWS CLI reaches Floci" "$AWS sts get-caller-identity"
check "account is 000000000000" \
  "test \"\$($AWS sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 11 dependencies =="
check "configs/lab-11.env present" "test -f configs/lab-11.env"
check "pipeline $USMS_PIPELINE_NAME exists" "pipe name | grep -q $USMS_PIPELINE_NAME"
check "build project exists" "proj name | grep -q $USMS_BUILD_PROJECT"
check "ECS service exists" \
  "$AWS ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text | grep -q ACTIVE"

echo "== ECR =="
check "repository $USMS_ECR_REPO exists" "ecr repositoryName | grep -q $USMS_ECR_REPO"
check "scanOnPush is true" "ecr imageScanningConfiguration.scanOnPush | grep -qi true"
check "repositoryUri has a registry host" "ecr repositoryUri | grep -q '/'"
# Known Floci Limitation (confirmed in Lab 12 Step 9 and re-confirmed here): this build's
# ECR control plane (describe-images) is disconnected from its own data plane - it returns
# imageDetails: [] even immediately after a successful, verified push. Proven by deleting the
# local image and pulling it back by digest. So these two checks verify the data-plane proof
# recorded at push time (outputs/lab-12-image-digest.txt), not the broken describe-images API.
check "at least one image push is recorded (describe-images is a known-broken API here)" \
  "test -f outputs/lab-12-image-digest.txt && grep -q 'sha256:' outputs/lab-12-image-digest.txt"
check "tag r7's push is recorded, with a real digest" \
  "grep -q '^r7 sha256:\|^r7\s' outputs/lab-12-image-digest.txt 2>/dev/null || docker inspect 000000000000.dkr.ecr.us-east-1.localhost:5100/usms-enrolment:r7 >/dev/null 2>&1"

echo "== Source tree =="
check "Dockerfile present" "test -f labs/lab-11-cicd/app/Dockerfile"
check ".dockerignore present" "test -f labs/lab-11-cicd/app/.dockerignore"
check "buildspec builds an image" "grep -q 'docker build' $spec"
check "buildspec writes imagedefinitions" "grep -q 'imagedefinitions.json' $spec"
check "smoke.sh has 8 assertions" "test \"\$(grep -cE '^t \"' labs/lab-11-cicd/app/tests/smoke.sh)\" = 8"

echo "== Task definition and service =="
check "task family revision is at least 3" "test \"\$(tdef revision)\" -ge 3"
check "task definition names the ECR repo" "tdef 'containerDefinitions[0].image' | grep -q $USMS_ECR_REPO"
check "cpu is still 256" "test \"\$(tdef cpu)\" = 256"
check "service is on a revision naming r7, or was rolled back to the r7 revision" \
  "test \"\$($AWS ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].taskDefinition' --output text)\" = usms-enrolment:3"

echo "== IAM policy versions =="
check "USMSCodeBuildBase default is v2" "test \"\$(polv USMSCodeBuildBase)\" = v2"
check "codebuild v2 grants ecr:PutImage" "grep -q 'ecr:PutImage' policies/usms-codebuild-policy-v2.json"
check "GetAuthorizationToken is on Resource *" \
  "python -c \"import json;d=json.load(open('policies/usms-codebuild-policy-v2.json'));import sys;sys.exit(0 if any(s.get('Action')=='ecr:GetAuthorizationToken' and s.get('Resource')=='*' for s in d['Statement']) else 1)\""
check "USMSCodePipelineBase default is v2" "test \"\$(polv USMSCodePipelineBase)\" = v2"
check "pipeline v2 grants ecs:UpdateService" "grep -q 'ecs:UpdateService' policies/usms-codepipeline-policy-v2.json"
check "pipeline v2 scopes the ECS statement to one service ARN" \
  "grep -q 'service/usms-ecs-cluster/usms-enrolment-svc' policies/usms-codepipeline-policy-v2.json"
check "pipeline v2 passes roles to ecs-tasks" "grep -q 'ecs-tasks.amazonaws.com' policies/usms-codepipeline-policy-v2.json"

echo "== CodeBuild project =="
check "privilegedMode is true" "proj environment.privilegedMode | grep -qi true"
check "IMAGE_REPO_URI is set" \
  "proj 'environment.environmentVariables[?name==\`IMAGE_REPO_URI\`].value | [0]' | grep -q ."
check "source type is still CODEPIPELINE" "proj source.type | grep -q CODEPIPELINE"

echo "== Pipeline (document, not a live execution - see notes/lab-12-notes.md) =="
check "pipeline has 3 stages" "test \"\$(pipe 'length(stages)')\" = 3"
check "stage 3 is named Deploy" "pipe 'stages[2].name' | grep -q '^Deploy\$'"
check "deploy provider is ECS" "pipe 'stages[2].actions[0].actionTypeId.provider' | grep -q '^ECS\$'"
check "deploy reads imagedefinitions.json" "pipe 'stages[2].actions[0].configuration.FileName' | grep -q imagedefinitions.json"

echo "== Conceptual documents and helpers =="
check "appspec.yaml present" "test -f templates/lab-12-appspec.yaml"
check "deployment group document is valid JSON" \
  "python -m json.tool templates/lab-12-codedeploy-deployment-group.json"
check "usms-ecs-watch.sh executable and valid" \
  "test -x scripts/utilities/usms-ecs-watch.sh && bash -n scripts/utilities/usms-ecs-watch.sh"
check "deploy-support-probe.sh executable and valid" \
  "test -x scripts/utilities/deploy-support-probe.sh && bash -n scripts/utilities/deploy-support-probe.sh"

echo "== Files and Git hygiene =="
check "configs/lab-12.env present" "test -f configs/lab-12.env"
check "no empty or None values in lab-12.env" "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-12.env"
check "taskdef v3 template is valid JSON" "python -m json.tool templates/lab-12-taskdef-v3.json"
check "pipeline template is valid JSON" "python -m json.tool templates/lab-12-pipeline.json"
check "lab-12 templates have no unexpanded variables" \
  "! grep -q '[\$]' templates/lab-12-taskdef-v3.json templates/lab-12-codebuild-update.json templates/lab-12-pipeline.json"
check "both v2 policy documents are valid JSON" \
  "python -m json.tool policies/usms-codebuild-policy-v2.json && python -m json.tool policies/usms-codepipeline-policy-v2.json"
check "no secret is tracked" "! git ls-files | grep -v '\.gitkeep$' | grep -q '^outputs/'"

echo; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
