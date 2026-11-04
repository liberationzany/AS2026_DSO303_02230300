#!/usr/bin/env bash
# END OF COURSE ONLY. Removes the (small) amount of Lab 06 that is real on this
# build. Application Auto Scaling itself (scalable target, scaling policies,
# scheduled actions) does not exist on this Floci build (Path C - see the lab
# report) so there is nothing of that kind to deregister or delete. What IS
# real and is removed here: the custom CloudWatch metric's alarm, and the
# attempted service-linked role, if this build ever creates one.
# Run this FIRST of the compute cleanups, then lab-05, then lab-04.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-06.env"

cat <<'WARN'
========================================================================
  This build has no real Application Auto Scaling objects to delete
  (Path C - confirmed UnknownOperationException on every operation;
  see the lab report Section 7). This script only deletes the one
  CloudWatch alarm Lab 06 created for real.

  It does NOT touch the ECS service, the task definition, the cluster,
  the load balancer or the target group.

  Run this FIRST, then lab-05-cleanup.sh, then lab-04-cleanup.sh.
========================================================================
WARN

read -r -p 'Type exactly: DELETE USMS SCALING > ' answer
[ "$answer" = "DELETE USMS SCALING" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "the alarm you wrote (the only real Application-Auto-Scaling-adjacent object)"
aws cloudwatch delete-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" \
  && echo "  deleted $USMS_ALARM_QUEUE_HIGH" || echo "  already gone"

say "what is deliberately NOT deleted"
cat <<'KEPT'
    The USMS/Enrolment custom metric
       CloudWatch metrics cannot be deleted. They stop being published and
       the datapoints expire on CloudWatch's own retention schedule.

    usms-enrolment-svc, its task definition, its cluster, the load balancer
       Untouched. lab-05-cleanup.sh and lab-04-cleanup.sh remove those,
       in that order.
KEPT

echo
echo "Lab 06 teardown complete. scripts/cleanup/lab-05-cleanup.sh may now run."
