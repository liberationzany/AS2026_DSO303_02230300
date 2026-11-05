#!/usr/bin/env bash
# END-OF-COURSE CLEANUP for Lab 13. Deletes dependencies inside-out.
# DO NOT RUN while a later lab still needs these alarms.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export MSYS_NO_PATHCONV=1
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

CENTRAL="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
AWS="aws --endpoint-url ${FLOCI_ENDPOINT:-http://localhost:4566}"

cat << 'WARN'
This will permanently delete:
  - usms-transcript-lag-high and usms-notify-silence (the composite alarm was
    never created live on this build - put-composite-alarm is unsupported)
  - /usms/central/application AND EVERY LOG EVENT IN IT
  - USMSObservabilityWrite, after detaching it from two roles

Metric DATA already published into USMS/Application is not deleted by this
script and cannot be deleted at all - CloudWatch metrics expire, they are
never removed.
WARN

printf 'Type exactly: DELETE USMS OBSERVABILITY\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS OBSERVABILITY" ] || { echo "aborted"; exit 1; }

say() { printf '\n== %s ==\n' "$1"; }

say "deleting the two metric alarms"
$AWS cloudwatch delete-alarms --alarm-names usms-transcript-lag-high usms-notify-silence 2>/dev/null \
  && echo "  deleted both metric alarms" || echo "  already absent"

say "deleting the central log group and its events"
$AWS logs delete-log-group --log-group-name "$CENTRAL" 2>/dev/null \
  && echo "  deleted $CENTRAL" || echo "  already absent"

say "detaching and deleting USMSObservabilityWrite"
OBS_ARN=$($AWS iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text 2>/dev/null)
if [ -n "$OBS_ARN" ] && [ "$OBS_ARN" != "None" ]; then
  for role in usms-lambda-exec-role usms-ec2-app-role; do
    $AWS iam detach-role-policy --role-name "$role" --policy-arn "$OBS_ARN" 2>/dev/null \
      && echo "  detached from $role" || true
  done
  $AWS iam delete-policy --policy-arn "$OBS_ARN" 2>/dev/null \
    && echo "  deleted USMSObservabilityWrite" \
    || echo "  could not delete - check for remaining attachments"
fi

echo
echo "NOT deleted, deliberately:"
echo "  - the notifier's versions and alias (Lab 10 owns them)"
echo "  - /aws/lambda/usms-transcript-notifier (Lambda recreates it anyway)"
echo "  - retention policies on groups this lab did not create"
echo "  - metric data in USMS/Application (CloudWatch metrics cannot be deleted)"
echo "  - the templates/ documents for the filters, composite alarm, dashboard,"
echo "    sampling rule and segments - none of those were ever live objects on"
echo "    this build, so there is nothing to delete for them"
