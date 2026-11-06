#!/usr/bin/env bash
# One description of the whole USMS system, across every practical.
# Read-only. Safe to run at any time. Writes nothing except its own stdout.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export MSYS_NO_PATHCONV=1
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-*.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

section() { printf '\n== %s ==\n' "$1"; }

printf 'USMS project inventory - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'account : %s\n' "$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNREACHABLE)"
printf 'endpoint: %s\n' "${FLOCI_ENDPOINT:-unset}"

section "identity (Lab 01)"
aws iam list-roles --query "Roles[?starts_with(RoleName, 'usms-')].RoleName" --output text | tr '\t' '\n'
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, 'USMS')].PolicyName" --output text | tr '\t' '\n'
aws iam list-groups --query "Groups[?starts_with(GroupName, 'usms-')].GroupName" --output text 2>/dev/null | tr '\t' '\n'
aws iam list-users --query "Users[?starts_with(UserName, 'usms-')].UserName" --output text 2>/dev/null | tr '\t' '\n'
aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName, 'usms-')].InstanceProfileName" --output text 2>/dev/null | tr '\t' '\n'

section "network (Lab 02)"
aws ec2 describe-vpcs --filters Name=tag:Project,Values=USMS --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null || echo "none"
aws ec2 describe-subnets --filters Name=tag:Project,Values=USMS --query 'length(Subnets)' --output text 2>/dev/null || echo 0
aws ec2 describe-security-groups --filters Name=tag:Project,Values=USMS --query 'length(SecurityGroups)' --output text 2>/dev/null || echo 0

section "compute (Labs 03, 04, 05, 07)"
aws ec2 describe-instances --filters Name=tag:Project,Values=USMS --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null || echo "none"
aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null || echo "none"
aws eks list-clusters --query 'clusters' --output text 2>/dev/null || echo "none"
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'usms-')].LoadBalancerName" --output text 2>/dev/null || echo "none"

section "storage and functions (Labs 06, 10)"
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'usms-')].Name" --output text 2>/dev/null
aws lambda list-functions \
  --query "sort_by(Functions[?starts_with(FunctionName, 'usms-')], &FunctionName)[].[FunctionName,Runtime,TracingConfig.Mode]" \
  --output text 2>/dev/null || echo "none"

section "pipeline (Labs 11, 12)"
aws codepipeline list-pipelines --query 'pipelines[].name' --output text 2>/dev/null || echo "none"
aws codebuild list-projects --query 'projects' --output text 2>/dev/null || echo "none"
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null || echo "none"

section "observability (Lab 13)"
aws logs describe-log-groups --query 'logGroups[].[logGroupName,retentionInDays]' --output text 2>/dev/null
aws cloudwatch list-metrics --namespace USMS/Application --query 'Metrics[].MetricName' --output text 2>/dev/null | tr '\t' '\n' | sort -u
aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text 2>/dev/null
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text 2>/dev/null

section "repository"
printf 'lab documents    : %s\n' "$(ls -d labs/lab-* 2>/dev/null | wc -l | tr -d ' ')"
printf 'env files        : %s\n' "$(ls configs/lab-*.env 2>/dev/null | wc -l | tr -d ' ')"
printf 'verify scripts   : %s\n' "$(ls scripts/utilities/verify-lab-*.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'cleanup scripts  : %s\n' "$(ls scripts/cleanup/lab-*-cleanup.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'commits          : %s\n' "$(git rev-list --count HEAD 2>/dev/null || echo 0)"
printf 'tracked secrets  : %s\n' "$(git ls-files outputs/ 2>/dev/null | grep -cv '.gitkeep' || echo 0)"

section "verification"
for v in scripts/utilities/verify-lab-*.sh; do
  [ -x "$v" ] || continue
  printf '%-40s %s\n' "$v" "$("$v" 2>/dev/null | tail -1)"
done
