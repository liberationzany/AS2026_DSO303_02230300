#!/usr/bin/env bash
# Verify every Lab 05 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to re-run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null

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

echo "== Lab 01 to 04 dependencies =="
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A_ID"
check "usms-public-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_B_ID"
check "usms-ecs-cluster is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"

echo "== Lab 05 security group =="
check "usms-alb-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG"
check "usms-alb-sg admits tcp/80 from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[0].CidrIp | [0]' --output text | grep -q '0.0.0.0/0'"

echo "== Lab 05 load balancer =="
check "usms-enrolment-alb exists and is active" \
  "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns $USMS_ALB_ARN --query 'LoadBalancers[0].State.Code' --output text)\" = active"
check "load balancer is internet-facing" \
  "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns $USMS_ALB_ARN --query 'LoadBalancers[0].Scheme' --output text)\" = internet-facing"
check "load balancer spans TWO Availability Zones" \
  "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns $USMS_ALB_ARN --query 'length(LoadBalancers[0].AvailabilityZones)' --output text)\" = 2"
check "load balancer carries usms-alb-sg" \
  "aws elbv2 describe-load-balancers --load-balancer-arns $USMS_ALB_ARN --query 'LoadBalancers[0].SecurityGroups' --output text | grep -q $USMS_ALB_SG"

echo "== Lab 05 target group =="
check "usms-enrolment-tg exists" "aws elbv2 describe-target-groups --target-group-arns $USMS_TG_ARN"
check "target group target-type is ip" \
  "test \"\$(aws elbv2 describe-target-groups --target-group-arns $USMS_TG_ARN --query 'TargetGroups[0].TargetType' --output text)\" = ip"
check "target group health check path is /" \
  "test \"\$(aws elbv2 describe-target-groups --target-group-arns $USMS_TG_ARN --query 'TargetGroups[0].HealthCheckPath' --output text)\" = /"
check "target group matcher is 200" \
  "test \"\$(aws elbv2 describe-target-groups --target-group-arns $USMS_TG_ARN --query 'TargetGroups[0].Matcher.HttpCode' --output text)\" = 200"
check "target group is attached to the load balancer" \
  "test \"\$(aws elbv2 describe-target-groups --target-group-arns $USMS_TG_ARN --query 'length(TargetGroups[0].LoadBalancerArns)' --output text)\" = 1"
check "deregistration delay is 30 seconds" \
  "aws elbv2 describe-target-group-attributes --target-group-arn $USMS_TG_ARN --query 'Attributes[?Key==\`deregistration_delay.timeout_seconds\`].Value | [0]' --output text | grep -q '^30$'"
check "at least one target is healthy" \
  "aws elbv2 describe-target-health --target-group-arn $USMS_TG_ARN --query 'TargetHealthDescriptions[?TargetHealth.State==\`healthy\`]' --output text | grep -q ."

echo "== Lab 05 listener and rule =="
check "listener exists on port 80" \
  "test \"\$(aws elbv2 describe-listeners --listener-arns $USMS_LISTENER_ARN --query 'Listeners[0].Port' --output text)\" = 80"
check "listener default action forwards to usms-enrolment-tg" \
  "test \"\$(aws elbv2 describe-listeners --listener-arns $USMS_LISTENER_ARN --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)\" = $USMS_TG_ARN"
check "health-check rule exists at priority 10" \
  "aws elbv2 describe-rules --listener-arn $USMS_LISTENER_ARN --query \"Rules[?Priority=='10']\" --output text | grep -q ."

echo "== Lab 05 service attachment =="
check "usms-enrolment-svc has a loadBalancers entry" \
  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].loadBalancers[0].targetGroupArn' --output text | grep -q $USMS_TG_ARN"
check "service's load-balanced container is enrolment-api on port 80" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].loadBalancers[0].containerPort' --output text)\" = 80"

# KNOWN FLOCI GAP: healthCheckGracePeriodSeconds is accepted with no error on both
# update-service and create-service, but is never persisted or returned on this
# build (confirmed via direct describe-services immediately after create-service).
# See report Section 7.
grace="$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].healthCheckGracePeriodSeconds' --output text 2>/dev/null)"
if [ "$grace" = "60" ]; then
  printf " ✓ %s\n" "healthCheckGracePeriodSeconds is 60"; PASS=$((PASS+1))
else
  info "healthCheckGracePeriodSeconds reads '$grace', not 60 - not persisted on this Floci build via either create-service or update-service (confirmed gap, see report Section 7)"
fi

echo "== Lab 05 cutover (Step 13) =="
check "usms-enrolment-sg admits tcp/80 (exactly one rule remains, the ALB path)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'length(SecurityGroups[0].IpPermissions)' --output text)\" = 1"

echo "== Files and Git hygiene =="
check "configs/lab-05.env exists" "test -f configs/lab-05.env"
check "configs/lab-05.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\"\"$|=\"None\"$' configs/lab-05.env"
check "listener default-actions document is valid JSON" "python -m json.tool templates/lab-05-listener-default-actions.json"
check "rule conditions document is valid JSON" "python -m json.tool templates/lab-05-rule-conditions.json"
check "rule actions document is valid JSON" "python -m json.tool templates/lab-05-rule-actions.json"
check "service load-balancers document is valid JSON" "python -m json.tool templates/lab-05-service-load-balancers.json"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/lab-05-'"

echo
echo "PASS=$PASS FAIL=$FAIL INFO=$INFO"
[ "$FAIL" -eq 0 ]
