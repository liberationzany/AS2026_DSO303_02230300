#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 05's load balancer stack and the cutover it made.
# Order: detach service's load balancer (recreate without one) -> listener/rules ->
# target group -> load balancer -> ALB security group -> restore direct SG rule.
# Run this AFTER scripts/cleanup/lab-06-cleanup.sh and BEFORE lab-04-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"
source "$REPO_ROOT/configs/lab-05.env"

cat <<'WARN'
========================================================================
  This deletes the enrolment load balancer, its listener and rule,
  its target group, and its security group, then recreates
  usms-enrolment-svc WITHOUT a load balancer (this build cannot
  detach one via update-service - see the lab report).
  None of this is reversible.
  Run this AFTER lab-06-cleanup.sh and BEFORE lab-04-cleanup.sh.
========================================================================
WARN

read -r -p 'Type exactly: DELETE USMS ALB > ' answer
[ "$answer" = "DELETE USMS ALB" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "recreate the service without a load balancer"
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --force >/dev/null || true
sleep 5
aws ecs create-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service-name "$USMS_ENROLMENT_SERVICE" \
  --task-definition "$USMS_ENROLMENT_TASK_FAMILY" \
  --desired-count "$USMS_ECS_DESIRED_BASELINE" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A_ID,$USMS_PRIVATE_SUBNET_B_ID],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=DISABLED}" \
  >/dev/null || true

say "listener and rule (deleting the listener removes its rules too)"
aws elbv2 delete-listener --listener-arn "$USMS_LISTENER_ARN" || true

say "target group"
aws elbv2 delete-target-group --target-group-arn "$USMS_TG_ARN" || true

say "load balancer"
aws elbv2 delete-load-balancer --load-balancer-arn "$USMS_ALB_ARN" || true

say "ALB security group (after the load balancer that used it is gone)"
aws ec2 delete-security-group --group-id "$USMS_ALB_SG" || true

say "restore the direct web-tier rule on usms-enrolment-sg, for a clean re-run of this lab"
aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$USMS_APP_SG_ID}]" || true

echo; echo "Lab 05 teardown complete. scripts/cleanup/lab-04-cleanup.sh may now run."
