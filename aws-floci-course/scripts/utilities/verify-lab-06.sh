#!/usr/bin/env bash
# Verify every Lab 06 artefact that CAN exist on this Floci build.
# This build is Support Path C: Application Auto Scaling
# (aws application-autoscaling) returns UnknownOperationException for every
# operation. No scalable target, scaling policy or scheduled action exists for
# real - that is a confirmed, documented finding, not a failure of this script.
# What this script verifies is everything that genuinely IS real on this build:
# the CloudWatch custom metric, the alarm, and the configuration documents.
# Read-only; safe to re-run. See the lab report Section 7.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-06.env" 2>/dev/null

PASS=0; FAIL=0; INFO=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf " ✓ %s\n" "$1"; PASS=$((PASS+1))
  else printf " ✗ %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
info() { printf " (i) %s\n" "$1"; INFO=$((INFO+1)); }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = $ACCOUNT_ID"

echo "== Lab 02 to 05 dependencies =="
check "usms-private-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A_ID"
check "usms-private-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B_ID"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service still has exactly ONE loadBalancers entry" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'length(services[0].loadBalancers)' --output text)\" = 1"
check "target group $USMS_TG_NAME still has target type ip" \
  "test \"\$(aws elbv2 describe-target-groups --names $USMS_TG_NAME --query 'TargetGroups[0].TargetType' --output text)\" = ip"

echo "== Support path confirmation (Path C, confirmed) =="
# A real Application Auto Scaling backend answers describe-scalable-targets with
# an empty list (a legitimate, successful call) when nothing is registered. This
# build instead throws UnknownOperationException - categorically different from
# "empty list" and the basis for recording this build as Path C.
aas_error="$(aws application-autoscaling describe-scalable-targets --service-namespace ecs 2>&1 || true)"
if echo "$aas_error" | grep -q "UnknownOperationException"; then
  info "Application Auto Scaling confirmed absent on this build (UnknownOperationException) - Path C, see report Section 7"
else
  check "describe-scalable-targets answers (re-test: build may have changed)" "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
fi

echo "== What IS real on this build: CloudWatch =="
check "custom metric $USMS_METRIC_NAMESPACE / $USMS_METRIC_NAME exists" \
  "aws cloudwatch list-metrics --namespace '$USMS_METRIC_NAMESPACE' --query 'Metrics[?MetricName==\`'$USMS_METRIC_NAME'\`]' --output text | grep -q ."
check "alarm $USMS_ALARM_QUEUE_HIGH exists" "aws cloudwatch describe-alarms --alarm-names $USMS_ALARM_QUEUE_HIGH"
check "alarm watches the custom metric" \
  "test \"\$(aws cloudwatch describe-alarms --alarm-names $USMS_ALARM_QUEUE_HIGH --query 'MetricAlarms[0].MetricName' --output text)\" = $USMS_METRIC_NAME"
check "alarm threshold is 100" \
  "test \"\$(aws cloudwatch describe-alarms --alarm-names $USMS_ALARM_QUEUE_HIGH --query 'MetricAlarms[0].Threshold' --output text | cut -d. -f1)\" = 100"

# KNOWN FLOCI GAP: --treat-missing-data notBreaching was accepted with no error
# on put-metric-alarm, but is not persisted (reads null on read-back). Same
# accepted-but-dropped pattern already found for Lab 05's grace period.
missing="$(aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" --query 'MetricAlarms[0].TreatMissingData' --output text 2>/dev/null)"
if [ "$missing" = "notBreaching" ]; then
  printf " ✓ %s\n" "alarm TreatMissingData is notBreaching"; PASS=$((PASS+1))
else
  info "alarm TreatMissingData reads '$missing', not 'notBreaching' - accepted but not persisted on this build (confirmed gap, see report Section 7)"
fi

echo "== ResourceLabel construction (validated, even though the policy cannot exist) =="
check "USMS_ALB_RESOURCE_LABEL has 6 segments, starts app, 4th is targetgroup" \
  "printf '%s' \"\$USMS_ALB_RESOURCE_LABEL\" | awk -F/ '{exit !(NF==6 && \$1==\"app\" && \$4==\"targetgroup\")}'"

echo "== Files and Git hygiene =="
check "configs/lab-06.env exists" "test -f configs/lab-06.env"
check "target tracking (cpu) document is valid JSON" "python -m json.tool templates/lab-06-target-tracking-cpu.json"
check "target tracking (requests) document is valid JSON" "python -m json.tool templates/lab-06-target-tracking-requests.json"
check "requests document's ResourceLabel has no unexpanded variable" "! grep -q '[$]' templates/lab-06-target-tracking-requests.json"
check "step scaling document is valid JSON" "python -m json.tool templates/lab-06-step-scaling-out.json"
check "suspended-state document is valid JSON" "python -m json.tool templates/lab-06-suspended-state.json"
check "no outputs/ file is tracked except .gitkeep" \
  "test \"\$(git ls-files outputs/ | grep -v '\\.gitkeep$' | wc -l)\" = 0"

echo
echo "PASS=$PASS FAIL=$FAIL INFO=$INFO"
[ "$FAIL" -eq 0 ]
