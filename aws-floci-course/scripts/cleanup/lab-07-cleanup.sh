#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes every Lab 07 resource, dependencies inside-out.
# Does NOT delete USMSStudentDataReadWrite, which Labs 03 and 04 still use.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

cat <<'WARN'
========================================================================
This deletes:
  - Kubernetes namespace usms and everything inside it
  - EKS node group usms-eks-nodes
  - EKS cluster usms-eks-cluster
  - IAM roles usms-eks-cluster-role and usms-eks-node-role
  - IAM policies USMSEKSClusterPolicy and USMSEKSNodePolicy
  - Security group usms-eks-cluster-sg
It does NOT delete USMSStudentDataReadWrite, which Lab 03 and Lab 04 still use.
Run this BEFORE lab-04-cleanup.sh / lab-02-cleanup.sh, and AFTER lab-08-cleanup.sh.
========================================================================
WARN

printf 'Type exactly DELETE-LAB-07 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-07" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "Kubernetes objects first: a load balancer Service (Lab 08) must be gone before the cluster can be deleted cleanly"
kubectl delete namespace usms --ignore-not-found --timeout=180s

say "node group before cluster - a cluster with a node group refuses to delete"
aws eks delete-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || true
aws eks wait nodegroup-deleted --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || sleep 30

say "the cluster"
aws eks delete-cluster --name usms-eks-cluster 2>/dev/null || true
aws eks wait cluster-deleted --name usms-eks-cluster 2>/dev/null || sleep 30

say "detach before delete - delete-role fails with DeleteConflict while a policy is attached"
for R in usms-eks-cluster-role usms-eks-node-role; do
  for P in $(aws iam list-attached-role-policies --role-name "$R" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$R" --policy-arn "$P" || true
  done
  aws iam delete-role --role-name "$R" 2>/dev/null || true
done

say "our own policies only - never USMSStudentDataReadWrite"
for N in USMSEKSClusterPolicy USMSEKSNodePolicy; do
  A=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$N'].Arn | [0]" --output text 2>/dev/null)
  [ -n "$A" ] && [ "$A" != "None" ] && aws iam delete-policy --policy-arn "$A"
done

say "security group last - it cannot be deleted while an interface uses it"
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=usms-eks-cluster-sg \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG"

echo
echo "Lab 07 resources removed."
