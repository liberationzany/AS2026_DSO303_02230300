#!/usr/bin/env bash
# Verify every Lab 10 artefact exists AND is configured for the edge.
# Exit 1 if anything is missing. Read-only: this script changes nothing.
#
# This build has confirmed quirks worth knowing before reading a FAIL below
# (see labs/lab-10-lambda-edge/README.md for the investigation behind each):
#   1. --qualifier is ignored by get-function-configuration and by
#      add-permission's Resource (always reports/targets the unqualified
#      function). Checks below work around this by reading list-aliases and
#      get-policy directly instead of trusting a --qualifier argument.
#   2. CloudFront create-distribution silently drops LambdaFunctionAssociations
#      and ForwardedValues from DefaultCacheBehavior on read-back, even though
#      Origins/Comment/Enabled persist fine. The distribution-config FILE (not
#      the live distribution) is therefore the thing verified below, which is
#      the same thing Path B verifies - a deliberate, honest choice.
#   3. No /aws/lambda/* log group is ever created on this build for any of the
#      three functions. Checks never depend on logs.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
ROLE_NAME="${USMS_ROLE_LAMBDA##*/}"
ROLE_NAME="${ROLE_NAME:-usms-lambda-exec-role}"
VIEWER=usms-edge-viewer-request
ORIGIN=usms-edge-origin-response
NOTIFIER=usms-transcript-notifier
DIST_CFG=templates/lab-10-distribution-config.json

PASS=0; FAIL=0
check() {
   if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
   else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

fn_field() { aws lambda get-function-configuration --function-name "$1" --query "$2" --output text; }
fn_env_count() {
   aws lambda get-function-configuration --function-name "$1" --output json 2>/dev/null \
      | python -c 'import json,sys; c=json.load(sys.stdin); print(len((c.get("Environment") or {}).get("Variables") or {}))'
}
fn_version_count() { aws lambda list-versions-by-function --function-name "$1" --query 'length(Versions)' --output text; }
alias_version() { aws lambda get-alias --function-name "$1" --name "$2" --query 'FunctionVersion' --output text; }
role_principals() {
   aws iam get-role --role-name "$ROLE_NAME" \
      --query 'Role.AssumeRolePolicyDocument.Statement[].Principal.Service' --output json
}
notifier_policy() { aws lambda get-policy --function-name "$NOTIFIER" --query 'Policy' --output text; }
dist_assoc() {
   python - "$DIST_CFG" << 'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for i in cfg['DefaultCacheBehavior']['LambdaFunctionAssociations']['Items']:
      print(i['EventType'], i['LambdaFunctionARN'])
PY
}
dist_arns_qualified() {
   dist_assoc | awk '{print $2}' | awk -F: '{print $NF}' \
      | grep -qvE '^[0-9]+$' && return 1 || return 0
}
policy_bucket_arns() {
   local arn
   arn=$(aws iam list-policies --scope Local \
            --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
   aws iam get-policy-version --policy-arn "$arn" \
      --version-id "$(aws iam get-policy --policy-arn "$arn" \
                               --query 'Policy.DefaultVersionId' --output text)" \
      --query 'PolicyVersion.Document.Statement[].Resource' --output text
}

echo "== Environment =="
check "Floci container running" \
   'test "$(docker container inspect $FLOCI_CONTAINER_NAME --format "{{.State.Running}}")" = true'
check "Storage mode is NOT memory" \
   'docker container inspect $FLOCI_CONTAINER_NAME --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -qE "^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$"'
check "AWS CLI reaches Floci" \
   'aws sts get-caller-identity'

echo "== Origin bucket =="
check "bucket $BUCKET exists" \
   'aws s3api head-bucket --bucket "$BUCKET"'
check "bucket is tagged Project=USMS" \
   'aws s3api get-bucket-tagging --bucket "$BUCKET" --output text | grep -q USMS'
check "at least one object under transcripts/" \
   'test "$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ --query "length(Contents)" --output text)" != "None"'
check "USMSStudentDataReadWrite names this bucket, and it now resolves" \
   'policy_bucket_arns | grep -q "arn:aws:s3:::$BUCKET"'

echo "== Execution role =="
check "role $ROLE_NAME exists" \
   'aws iam get-role --role-name "$ROLE_NAME"'
check "role trusts lambda.amazonaws.com" \
   'role_principals | grep -q "lambda.amazonaws.com"'
check "role trusts edgelambda.amazonaws.com (Lambda@Edge requirement)" \
   'role_principals | grep -q "edgelambda.amazonaws.com"'
check "USMSLambdaBasic is attached to the role" \
   'aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output text | grep -q USMSLambdaBasic'

echo "== Edge function 1: viewer-request =="
check "$VIEWER exists" \
   'aws lambda get-function-configuration --function-name "$VIEWER"'
check "runtime is node or python (the only two the edge accepts)" \
   'fn_field "$VIEWER" Runtime | grep -qE "^(nodejs|python)"'
check "handler is index.handler" \
   'test "$(fn_field "$VIEWER" Handler)" = index.handler'
check "memory is within the 128 MB viewer cap" \
   'test "$(fn_field "$VIEWER" MemorySize)" -le 128'
check "timeout is within the 5 s viewer cap" \
   'test "$(fn_field "$VIEWER" Timeout)" -le 5'
check "NO environment variables (forbidden at the edge)" \
   'test "$(fn_env_count "$VIEWER")" -eq 0'
check "at least one published version exists" \
   'test "$(fn_version_count "$VIEWER")" -ge 2'

echo "== Edge function 2: origin-response =="
check "$ORIGIN exists" \
   'aws lambda get-function-configuration --function-name "$ORIGIN"'
check "runtime is node or python" \
   'fn_field "$ORIGIN" Runtime | grep -qE "^(nodejs|python)"'
check "memory is within the cap chosen for it" \
   'test "$(fn_field "$ORIGIN" MemorySize)" -le 128'
check "NO environment variables" \
   'test "$(fn_env_count "$ORIGIN")" -eq 0'
check "at least one published version exists" \
   'test "$(fn_version_count "$ORIGIN")" -ge 2'

echo "== Regional function: transcript notifier =="
check "$NOTIFIER exists" \
   'aws lambda get-function-configuration --function-name "$NOTIFIER"'
check "handler is notifier.handler" \
   'test "$(fn_field "$NOTIFIER" Handler)" = notifier.handler'
check "HAS environment variables (legal here, and the contrast is the point)" \
   'test "$(fn_env_count "$NOTIFIER")" -ge 1'
check "alias live exists" \
   'aws lambda get-alias --function-name "$NOTIFIER" --name live'
check "alias live points at a numbered version, not \$LATEST" \
   'alias_version "$NOTIFIER" live | grep -qE "^[0-9]+$"'
check "resource policy allows s3.amazonaws.com" \
   'notifier_policy | grep -q "s3.amazonaws.com"'
check "resource policy is scoped to this bucket (no confused deputy)" \
   'notifier_policy | grep -q "$BUCKET"'

echo "== S3 notification =="
check "bucket notification usms-transcript-upload exists" \
   'aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output text | grep -q usms-transcript-upload'
check "notification targets the live alias" \
   'aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output text | grep -q "function:$NOTIFIER:live"'
check "notification is filtered to transcripts/" \
   'aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output text | grep -q "transcripts/"'

echo "== CloudFront association configuration (the FILE - see header note on why) =="
check "distribution config file exists" \
   'test -f "$DIST_CFG"'
check "distribution config is valid JSON" \
   'python -m json.tool "$DIST_CFG"'
check "exactly two associations declared" \
   'test "$(dist_assoc | wc -l | tr -d " ")" -eq 2'
check "viewer-request is associated" \
   'dist_assoc | grep -q "^viewer-request "'
check "origin-response is associated" \
   'dist_assoc | grep -q "^origin-response "'
check "every associated ARN is version-qualified (the edge refuses \$LATEST and aliases)" \
   'dist_arns_qualified'
check "cache key forwards no cookies" \
   'python -c "import json;print(json.load(open(\"$DIST_CFG\"))[\"DefaultCacheBehavior\"][\"ForwardedValues\"][\"Cookies\"][\"Forward\"])" | grep -q none'

echo "== Source, scripts and Git hygiene =="
check "viewer-request handler source exists" \
   'test -f labs/lab-10-lambda-edge/edge-viewer-request/index.mjs'
check "origin-response handler source exists" \
   'test -f labs/lab-10-lambda-edge/edge-origin-response/index.mjs'
check "notifier handler source exists" \
   'test -f labs/lab-10-lambda-edge/transcript-notifier/notifier.py'
check "viewer handler kept its template literal (heredoc was quoted)" \
   'grep -q "studentId.toLowerCase()}" labs/lab-10-lambda-edge/edge-viewer-request/index.mjs'
check "usms-edge-simulate.sh is executable and valid bash" \
   'test -x scripts/utilities/usms-edge-simulate.sh && bash -n scripts/utilities/usms-edge-simulate.sh'
check "edge trace records the full three-stage chain" \
   'python -c "import json;t=json.load(open(\"outputs/lab-10-edge-trace.json\"));print(len(t[\"chain\"]))" | grep -q 3'
check "configs/lab-10.env exists" \
   'test -f configs/lab-10.env'
check "configs/lab-10.env has 25 exports" \
   'test "$(grep -c "^export" configs/lab-10.env)" -eq 25'
check "configs/lab-10.env has no empty values" \
   '! grep -qE "^export [A-Z_]+=\$" configs/lab-10.env'
check "no secret is tracked" \
   'test "$(git ls-files outputs/ | grep -v "\.gitkeep\$" | wc -l)" = 0'
check "no deployment archive is tracked" \
   '! git ls-files | grep -q "\.zip\$"'

echo; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
