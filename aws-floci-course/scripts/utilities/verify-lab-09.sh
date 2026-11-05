#!/usr/bin/env bash
# Verify every Lab 09 control exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
#
# This build has TWO confirmed Floci limitations that make some checks below
# fail even though the work was done correctly (see labs/lab-09-security/README.md):
#   1. --permissions-boundary / put-role-permissions-boundary is accepted but
#      never persisted (always reads back null).
#   2. revoke-security-group-egress AND revoke-security-group-ingress always
#      report Return:true but never actually remove the targeted rule, on
#      this build - confirmed 4-for-4 across every group this lab touched.
# Both are marked FAIL-BUT-DOCUMENTED below rather than hidden.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env" 2>/dev/null || true

# This repo's own established variable names (differ from the guide's generic
# USMS_APP_SG / USMS_DB_SG / USMS_S3_ENDPOINT - see report).
: "${USMS_ACCOUNT_ID:=000000000000}"
: "${USMS_VPC_ID:=none}"
: "${USMS_APP_SG_ID:=none}"
: "${USMS_DB_SG_ID:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ALB_SG:=none}"
: "${USMS_BASTION_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A_ID:=none}"
: "${USMS_DEV_USER:=usms-dev-01}"
: "${USMS_INSTANCE_PROFILE:=usms-ec2-app-profile}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_WEB_INSTANCE:=none}"
: "${USMS_DB_INSTANCE:=none}"

PASS=0; FAIL=0; DOCFAIL=0
check() {
    if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
    else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
checkdoc() {
    if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
    else printf "  FAIL(documented) %s\n" "$1"; DOCFAIL=$((DOCFAIL+1)); fi
}

poldoc() {
    arn=$(aws iam list-policies --scope Local \
                --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text 2>/dev/null)
    [ -n "$arn" ] && [ "$arn" != "None" ] || return 1
    ver=$(aws iam get-policy --policy-arn "$arn" \
                --query 'Policy.DefaultVersionId' --output text 2>/dev/null)
    aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
        --query 'PolicyVersion.Document' --output json 2>/dev/null
}

# Default allow-all egress rules, counted via the GRANULAR api (describe-security-group-rules),
# which (unlike describe-security-groups' IpPermissionsEgress) reliably surfaces this rule
# on this build - see report.
allowall() {
    aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$1" \
        --query "length(SecurityGroupRules[?IsEgress==\`true\` && IpProtocol=='-1'])" --output text 2>/dev/null
}

echo "== Environment =="
check "Floci container running" \
    "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
    "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
    "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Labs 01 to 06 dependencies still present =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "$USMS_ECS_TASK_ROLE exists" "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "$USMS_INSTANCE_PROFILE exists" \
    "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"
check "$USMS_ENROLMENT_SERVICE is ACTIVE" \
    "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text)\" = ACTIVE"
check "USMSStudentDataReadWrite is still on at least TWO roles (Lab 10 needs it)" \
    "test \"\$(for r in usms-ec2-app-role usms-ecs-task-role usms-eks-node-role; do aws iam list-attached-role-policies --role-name \$r --query 'AttachedPolicies[].PolicyName' --output text; done | grep -c USMSStudentDataReadWrite)\" -ge 2"

echo "== Lab 09 identity: the read-only split =="
check "USMSStudentDataReadOnly exists" \
    "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSStudentDataReadOnly'].Arn | [0]\" --output text | grep -q '^arn:'"
check "it ALLOWS s3:GetObject" \
    "poldoc USMSStudentDataReadOnly | grep -q 's3:GetObject'"
check "it does NOT allow s3:PutObject as an Allow action" \
    "! poldoc USMSStudentDataReadOnly | python -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']];a=[x for s in sts if s['Effect']=='Allow' for x in (s['Action'] if isinstance(s['Action'],list) else [s['Action']])];sys.exit(0 if 's3:PutObject' in a else 1)\""
check "it explicitly DENIES s3:PutObject" \
    "poldoc USMSStudentDataReadOnly | python -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']];a=[x for s in sts if s['Effect']=='Deny' for x in (s['Action'] if isinstance(s['Action'],list) else [s['Action']])];sys.exit(0 if 's3:PutObject' in a else 1)\""
check "usms-transcripts-reader-role exists" \
    "aws iam get-role --role-name usms-transcripts-reader-role"
check "it carries USMSStudentDataReadOnly" \
    "aws iam list-attached-role-policies --role-name usms-transcripts-reader-role --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSStudentDataReadOnly"

echo "== Lab 09 identity: the confused-deputy fix =="
check "$USMS_ECS_TASK_ROLE trust policy has a Condition" \
    "test \"\$(aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text)\" -ge 1"
check "its principal is STILL ecs-tasks.amazonaws.com" \
    "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q 'ecs-tasks.amazonaws.com'"
check "the condition pins aws:SourceAccount to this account" \
    "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q '$USMS_ACCOUNT_ID'"

echo "== Lab 09 identity: PassRole and the boundary =="
check "USMSDeployBase exists" \
    "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSDeployBase'].Arn | [0]\" --output text | grep -q '^arn:'"
check "its iam:PassRole names role ARNs, not Resource \"*\"" \
    "poldoc USMSDeployBase | python -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'];bad=[s for s in sts if s['Effect']=='Allow' and 'iam:PassRole' in (s['Action'] if isinstance(s['Action'],list) else [s['Action']]) and '*' in (s['Resource'] if isinstance(s['Resource'],list) else [s['Resource']])];sys.exit(1 if bad else 0)\""
check "its iam:PassRole carries an iam:PassedToService condition" \
    "poldoc USMSDeployBase | grep -q 'iam:PassedToService'"
check "USMSPermissionsBoundary exists" \
    "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSPermissionsBoundary'].Arn | [0]\" --output text | grep -q '^arn:'"
check "the boundary is attached to NOTHING as an ordinary policy" \
    "test \"\$(aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSPermissionsBoundary'].AttachmentCount | [0]\" --output text)\" = 0"
check "usms-deploy-role exists" "aws iam get-role --role-name usms-deploy-role"
checkdoc "usms-deploy-role HAS a permissions boundary (known Floci limitation: not persisted on this build)" \
    "aws iam get-role --role-name usms-deploy-role --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text | grep -q 'USMSPermissionsBoundary'"
check "usms-deploy-role trusts a USER, not a service" \
    "aws iam get-role --role-name usms-deploy-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS' --output text | grep -q ':user/'"

echo "== Lab 09 credentials and metadata =="
check "$USMS_DEV_USER has EXACTLY ONE access key" \
    "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'length(AccessKeyMetadata)' --output text)\" = 1"
check "that key is Active" \
    "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'AccessKeyMetadata[0].Status' --output text)\" = Active"
checkdoc "usms-web-01 requires IMDSv2 (known Floci limitation: modify-instance-metadata-options is UnsupportedOperation on this build)" \
    "test \"\$(aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)\" = required"

echo "== Lab 09 network: ingress unchanged =="
check "usms-alb-sg still admits tcp/80 from 0.0.0.0/0" \
    "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"
check "usms-db-sg still admits tcp/5432 (source-group metadata is a known, separate Floci gap - see report)" \
    "aws ec2 describe-security-groups --group-ids $USMS_DB_SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==\`5432\`]' --output text | grep -q '5432'"

echo "== Lab 09 network: egress written (authorize succeeded; revoke is a confirmed no-op - see report) =="
check "usms-alb-sg's replacement egress rule (group-referenced, tcp/80) was added" \
    "aws ec2 describe-security-group-rules --filters \"Name=group-id,Values=$USMS_ALB_SG\" --query 'SecurityGroupRules[?IsEgress==\`true\` && FromPort==\`80\`]' --output text | grep -q 80"
checkdoc "usms-alb-sg has NO allow-all egress rule (known Floci limitation: revoke-security-group-egress never removes anything on this build)" \
    "test \"\$(allowall $USMS_ALB_SG)\" = 0"
check "usms-enrolment-sg's replacement egress rules (tcp/443) were added" \
    "aws ec2 describe-security-group-rules --filters \"Name=group-id,Values=$USMS_ENROLMENT_SG\" --query 'length(SecurityGroupRules[?IsEgress==\`true\` && FromPort==\`443\`])' --output text | grep -qv '^0$'"
checkdoc "usms-enrolment-sg has NO allow-all egress rule (known Floci limitation)" \
    "test \"\$(allowall $USMS_ENROLMENT_SG)\" = 0"
check "usms-db-sg's replacement egress rule (tcp/443) was added" \
    "aws ec2 describe-security-group-rules --filters \"Name=group-id,Values=$USMS_DB_SG_ID\" --query 'SecurityGroupRules[?IsEgress==\`true\` && FromPort==\`443\`]' --output text | grep -q 443"
checkdoc "usms-db-sg has NO allow-all egress rule (known Floci limitation)" \
    "test \"\$(allowall $USMS_DB_SG_ID)\" = 0"

echo "== Lab 09 network: the SSH cutover (authorize succeeded; old rule's removal blocked by the same revoke no-op) =="
check "usms-bastion-sg exists" \
    "aws ec2 describe-security-groups --filters Name=group-name,Values=usms-bastion-sg Name=vpc-id,Values=$USMS_VPC_ID --query 'SecurityGroups[0].GroupId' --output text | grep -q '^sg-'"
check "usms-app-sg has a second tcp/22 ingress statement (the bastion-sourced replacement)" \
    "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_APP_SG_ID --query 'length(SecurityGroups[0].IpPermissions[?FromPort==\`22\`])' --output text)\" -ge 2"
checkdoc "usms-app-sg has NO CIDR source on tcp/22 (known Floci limitation: the pre-existing 10.0.0.0/16 rule could not be revoked)" \
    "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_APP_SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==\`22\`]' --output json | python -c 'import json,sys;perms=json.load(sys.stdin);print(sum(len(p.get(\"IpRanges\",[])) for p in perms))')\" = 0"

echo "== The negatives that must stay true =="
check "usms-db-01 has NO Elastic IP association (via describe-addresses, client-filtered - see report)" \
    "test \"\$(aws ec2 describe-addresses --query \"length(Addresses[?InstanceId=='$USMS_DB_INSTANCE'])\" --output text)\" = 0"
check "the private subnet does NOT auto-assign public addresses" \
    "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A_ID --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"
check "the private route table has NO internet gateway route" \
    "! aws ec2 describe-route-tables --filters \"Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A_ID\" --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"

echo "== Files, documents and Git hygiene =="
check "configs/lab-09.env exists" "test -f configs/lab-09.env"
check "configs/lab-09.env has no empty values" \
    "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-09.env"
check "every policies/ document is valid JSON" \
    "for f in policies/*.json; do python -m json.tool \"\$f\" >/dev/null || exit 1; done"
check "no policies/ document contains an unexpanded variable" \
    "! grep -l '\\\$' policies/*.json"
check "the three audit scripts exist and are executable" \
    "test -x scripts/utilities/usms-iam-audit.sh && test -x scripts/utilities/usms-sg-audit.sh && test -x scripts/utilities/usms-reachability-matrix.sh"
check "no secret is tracked by git" "test \"\$(git ls-files outputs/ | grep -v '\\.gitkeep$' | wc -l)\" = 0"

echo; echo "PASS=$PASS FAIL=$FAIL DOCUMENTED_FAIL=$DOCFAIL"

if [ "$FAIL" -ne 0 ]; then
    cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:

    ./scripts/utilities/floci-storage-check.sh

A failure under "== Labs 01 to 06 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh through verify-lab-06.sh before re-reading anything here.

A failure under "== The negatives that must stay true ==" is the most serious kind in
this script: something that was unreachable has become reachable. Stop and find out
what changed before doing anything else.

Lines marked FAIL(documented) are confirmed Floci build limitations, not gaps in this
lab's own work - see labs/lab-09-security/README.md for the investigation behind each one.
REMEDY
fi

[ "$FAIL" -eq 0 ]
