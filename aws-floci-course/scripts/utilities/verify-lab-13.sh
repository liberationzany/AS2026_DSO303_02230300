#!/usr/bin/env bash
# Verify every Lab 13 artefact exists AND is configured as the lab requires.
# This build has NO metric filters, NO Logs Insights, NO dashboards, NO composite
# alarms and NO X-Ray at all (confirmed directly - see outputs/lab-13-support-probe.txt).
# Checks for those features verify the DOCUMENT this lab wrote instead of a live
# object, which is the honest thing this build can check. Exit 1 if anything is missing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export MSYS_NO_PATHCONV=1
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

CENTRAL="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
FN_LOG="${USMS_LOG_GROUP_NOTIFIER:-/aws/lambda/usms-transcript-notifier}"
ECS_LOG="${USMS_LOG_GROUP_ECS:-/usms/ecs/enrolment}"
NS="${USMS_METRIC_NAMESPACE:-USMS/Application}"
NOTIFIER="usms-transcript-notifier"
ROLE_LAMBDA="usms-lambda-exec-role"
ROLE_EC2="usms-ec2-app-role"
A_LAG="${USMS_ALARM_LAG_HIGH:-usms-transcript-lag-high}"
A_SILENCE="${USMS_ALARM_NOTIFY_SILENCE:-usms-notify-silence}"

AWS="aws --endpoint-url ${FLOCI_ENDPOINT:-http://localhost:4566}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

lg_retention() {
  $AWS logs describe-log-groups --log-group-name-prefix "$1" \
    --query "logGroups[?logGroupName=='$1'].retentionInDays | [0]" --output text
}
lg_any_unset() {
  $AWS logs describe-log-groups \
    --query 'logGroups[?retentionInDays==`null`].logGroupName' --output text \
    | tr '\t' '\n' | grep -E '^/usms/|^/aws/lambda/usms-'
}
metric_dims() {
  $AWS cloudwatch list-metrics --namespace "$NS" --metric-name "$1" \
    --query 'Metrics[].[join(`,`, Dimensions[].Name) || `NONE`]' --output text
}
alias_version() {
  $AWS lambda get-alias --function-name "$NOTIFIER" --name live --query 'FunctionVersion' --output text
}
alarm_field() {
  $AWS cloudwatch describe-alarms --alarm-names "$1" --query "MetricAlarms[0].$2" --output text
}

echo "== Environment =="
check "Floci container running" \
  'test "$(docker container inspect $FLOCI_CONTAINER_NAME --format "{{.State.Running}}")" = true'
check "AWS CLI reaches Floci" '$AWS sts get-caller-identity'

echo "== Log layer =="
check "central log group $CENTRAL exists" \
  '$AWS logs describe-log-groups --log-group-name-prefix "$CENTRAL" --query "length(logGroups)" --output text | grep -qv "^0$"'
check "central log group retention is 30 days" 'test "$(lg_retention "$CENTRAL")" = "30"'
check "notifier log group has a retention policy" 'lg_retention "$FN_LOG" | grep -qE "^[0-9]+$"'
check "ECS log group has a retention policy" 'lg_retention "$ECS_LOG" | grep -qE "^[0-9]+$"'
check "NO USMS log group is left on never-expire" '! lg_any_unset | grep -q .'
check "central log group has at least one stream" \
  'test "$($AWS logs describe-log-streams --log-group-name "$CENTRAL" --query "length(logStreams)" --output text)" != "0"'
check "at least 5 USMS_EVENT lines are present" \
  'test "$($AWS logs filter-log-events --log-group-name "$CENTRAL" --filter-pattern USMS_EVENT --query "length(events)" --output text)" -ge 5'

echo "== Metric filter documentation (put-metric-filter is UnsupportedOperation on this build) =="
check "metric filter definitions documented" 'test -f templates/lab-13-metric-filters.json'
check "metric filter document is valid JSON" 'python -m json.tool templates/lab-13-metric-filters.json'
check "filter-test reasoning recorded" 'test -f outputs/lab-13-filter-test.json'

echo "== Metrics =="
check "namespace $NS has metrics" \
  'test "$($AWS cloudwatch list-metrics --namespace "$NS" --query "length(Metrics)" --output text)" != "0"'
check "NotifyCount exists (published by hand - filter cannot fire)" \
  'test "$($AWS cloudwatch list-metrics --namespace "$NS" --metric-name NotifyCount --query "length(Metrics)" --output text)" != "0"'
check "CentralErrorCount exists (published by hand)" \
  'test "$($AWS cloudwatch list-metrics --namespace "$NS" --metric-name CentralErrorCount --query "length(Metrics)" --output text)" != "0"'
check "TranscriptsProcessed published WITH dimensions" 'metric_dims TranscriptsProcessed | grep -q Faculty'
check "TranscriptsProcessed ALSO published with none (the total)" 'metric_dims TranscriptsProcessed | grep -q NONE'
check "TranscriptLagSeconds exists" \
  'test "$($AWS cloudwatch list-metrics --namespace "$NS" --metric-name TranscriptLagSeconds --query "length(Metrics)" --output text)" != "0"'

echo "== IAM =="
check "USMSObservabilityWrite exists" \
  '$AWS iam list-policies --scope Local --query "Policies[?PolicyName==\`USMSObservabilityWrite\`].Arn" --output text | grep -q .'
check "attached to $ROLE_LAMBDA" \
  '$AWS iam list-attached-role-policies --role-name "$ROLE_LAMBDA" --output text | grep -q USMSObservabilityWrite'
check "attached to $ROLE_EC2" \
  '$AWS iam list-attached-role-policies --role-name "$ROLE_EC2" --output text | grep -q USMSObservabilityWrite'
check "observability policy document is valid JSON" 'python -m json.tool policies/usms-observability-write-policy.json'
check "PutMetricData is scoped by a cloudwatch:namespace condition" \
  'grep -q "cloudwatch:namespace" policies/usms-observability-write-policy.json'
check "log group ARNs end in :* (streams, not just the group)" \
  'grep -qE "log-group:/usms/\*:\*" policies/usms-observability-write-policy.json'

echo "== The instrumented notifier =="
check "$NOTIFIER exists" '$AWS lambda get-function-configuration --function-name "$NOTIFIER"'
check "alias live points at a numbered version" 'alias_version | grep -qE "^[0-9]+$"'
check "alias live has moved past Lab 10 version 1" 'test "$(alias_version)" -ge 2'
check "tracing mode on the alias is Active" \
  'test "$($AWS lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live --query TracingConfig.Mode --output text)" = "Active"'
check "instrumented handler source emits USMS_SUMMARY" \
  'grep -q "USMS_SUMMARY" labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py'

echo "== Alarms =="
check "$A_LAG exists" '$AWS cloudwatch describe-alarms --alarm-names "$A_LAG" --query "length(MetricAlarms)" --output text | grep -qv "^0$"'
check "$A_LAG uses the Maximum statistic, not Average" 'test "$(alarm_field "$A_LAG" Statistic)" = "Maximum"'
check "$A_LAG's intended missing-data policy is documented as notBreaching" \
  'python -c "import json,sys; d=json.load(open(\"templates/lab-13-alarms.json\")); sys.exit(0 if d[\"usms-transcript-lag-high\"][\"TreatMissingData\"]==\"notBreaching\" else 1)"'
check "$A_SILENCE exists" '$AWS cloudwatch describe-alarms --alarm-names "$A_SILENCE" --query "length(MetricAlarms)" --output text | grep -qv "^0$"'
check "$A_SILENCE's intended missing-data policy is documented as breaching" \
  'python -c "import json,sys; d=json.load(open(\"templates/lab-13-alarms.json\")); sys.exit(0 if d[\"usms-notify-silence\"][\"TreatMissingData\"]==\"breaching\" else 1)"'
check "no alarm is left stuck in ALARM from Step 20" \
  'test "$(alarm_field "$A_LAG" StateValue)" != "ALARM" && test "$(alarm_field "$A_SILENCE" StateValue)" != "ALARM"'
check "composite alarm documented (put-composite-alarm is unsupported on this build)" \
  'test -f templates/lab-13-composite-alarm.json && python -m json.tool templates/lab-13-composite-alarm.json'

echo "== Dashboard (put-dashboard is unsupported on this build - document only) =="
check "dashboard document exists" 'test -f templates/lab-13-dashboard.json'
check "dashboard body is valid JSON" 'python -m json.tool templates/lab-13-dashboard.json'
check "dashboard has 5 widgets" \
  'test "$(python -c "import json; print(len(json.load(open(\"templates/lab-13-dashboard.json\"))[\"widgets\"]))")" -eq 5'
check "no two widgets overlap" \
  'python -c "
import json
w = json.load(open(\"templates/lab-13-dashboard.json\"))[\"widgets\"]
boxes = [(x[\"x\"], x[\"y\"], x[\"x\"]+x[\"width\"], x[\"y\"]+x[\"height\"]) for x in w]
import sys
for i, a in enumerate(boxes):
    for b in boxes[i+1:]:
        if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
            sys.exit(1)
sys.exit(0)"'

echo "== X-Ray documents (X-Ray is entirely unrouted on this build - documents only) =="
check "sampling rule document is valid JSON" 'python -m json.tool templates/lab-13-sampling-rule.json'
check "sampling rule declares every required field" \
  'python -c "
import json
r = json.load(open(\"templates/lab-13-sampling-rule.json\"))
need = {\"RuleName\",\"ResourceARN\",\"Priority\",\"FixedRate\",\"ReservoirSize\",\"ServiceName\",\"ServiceType\",\"Host\",\"HTTPMethod\",\"URLPath\",\"Version\"}
import sys; sys.exit(0 if need.issubset(r) else 1)"'
check "segment documents share one trace id and are well formed" \
  'python -c "
import json, re, sys
d = {n: json.load(open(\"templates/lab-13-segment-%s.json\" % n)) for n in (\"parent\", \"subsegments\", \"downstream\")}
tid = d[\"parent\"][\"trace_id\"]
ok = (re.fullmatch(r\"1-[0-9a-f]{8}-[0-9a-f]{24}\", tid)
      and all(x[\"trace_id\"] == tid for x in d.values())
      and all(re.fullmatch(r\"[0-9a-f]{16}\", x[\"id\"]) for x in d.values())
      and d[\"downstream\"].get(\"parent_id\") == d[\"parent\"][\"id\"]
      and all(x[\"end_time\"] > x[\"start_time\"] for x in d.values()))
sys.exit(0 if ok else 1)"'

echo "== Telemetry emitter =="
check "usms-emit-telemetry.sh is executable and valid bash" \
  'test -x scripts/utilities/usms-emit-telemetry.sh && bash -n scripts/utilities/usms-emit-telemetry.sh'
check "trace-ids file has at least 4 lines" 'test "$(wc -l < outputs/lab-13-trace-ids.txt)" -ge 4'

echo "== Files and Git hygiene =="
check "configs/lab-13.env exists" 'test -f configs/lab-13.env'
check "configs/lab-13.env has no empty values" '! grep -qE "^export [A-Z_]+=$" configs/lab-13.env'
check "no secret is tracked" '! git ls-files | grep -v "\.gitkeep$" | grep -q "^outputs/"'
check "no deployment archive is tracked" '! git ls-files | grep -q "\.zip$"'

echo; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
