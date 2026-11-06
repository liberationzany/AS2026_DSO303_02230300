#!/usr/bin/env bash
# ############################################################
# DO NOT RUN UNTIL THE COURSE IS FINISHED.
# Deletes the entire Lab 01 IAM foundation. Labs 02+ will break.
# ############################################################
set -uo pipefail

read -r -p "Delete ALL Lab 01 IAM resources? Type DELETE to confirm: " CONFIRM
[ "$CONFIRM" = "DELETE" ] || { echo "Aborted."; exit 1; }

for U in usms-admin-01 usms-dev-01 usms-audit-01; do
  for G in $(aws iam list-groups-for-user --user-name "$U" --query 'Groups[*].GroupName' --output text); do
    aws iam remove-user-from-group --user-name "$U" --group-name "$G"
  done
  for K in $(aws iam list-access-keys --user-name "$U" --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$U" --access-key-id "$K"
  done
  for P in $(aws iam list-user-policies --user-name "$U" --query 'PolicyNames' --output text); do
    aws iam delete-user-policy --user-name "$U" --policy-name "$P"
  done
  aws iam delete-user --user-name "$U"
done
echo "Users removed. Groups, policies and roles left for manual review."
