#!/usr/bin/env bash
# Delete every Lab 02 resource, in dependency order (deepest first).
# Safe to re-run: each delete is tolerant of "already gone".
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || { echo "configs/lab-02.env not found — nothing to clean up."; exit 0; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

log "S3 gateway endpoint"
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$USMS_S3_ENDPOINT_ID" 2>/dev/null || true

log "NAT gateway (this can take a few seconds)"
aws ec2 delete-nat-gateway --nat-gateway-id "$USMS_NAT_GW_ID" 2>/dev/null || true
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$USMS_NAT_GW_ID" 2>/dev/null || true

log "Elastic IP"
aws ec2 release-address --allocation-id "$USMS_NAT_EIP_ALLOC_ID" 2>/dev/null || true

log "Route table associations and route tables"
for rt in "$USMS_PUBLIC_RT_ID" "$USMS_PRIVATE_RT_ID"; do
  assocs="$(aws ec2 describe-route-tables --route-table-ids "$rt" \
            --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
            --output text 2>/dev/null)"
  for a in $assocs; do
    aws ec2 disassociate-route-table --association-id "$a" 2>/dev/null || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null || true
done

log "Private NACL (move its subnet back to the VPC default NACL first)"
default_nacl="$(aws ec2 describe-network-acls \
  --query "NetworkAcls[?VpcId=='$USMS_VPC_ID' && IsDefault==\`true\`].NetworkAclId | [0]" \
  --output text 2>/dev/null)"
assoc="$(aws ec2 describe-network-acls \
  --query "NetworkAcls[?NetworkAclId=='$USMS_PRIVATE_NACL_ID'].Associations[0].NetworkAclAssociationId | [0]" \
  --output text 2>/dev/null)"
if [ -n "$assoc" ] && [ "$assoc" != "None" ] && [ -n "$default_nacl" ] && [ "$default_nacl" != "None" ]; then
  aws ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$default_nacl" 2>/dev/null || true
fi
aws ec2 delete-network-acl --network-acl-id "$USMS_PRIVATE_NACL_ID" 2>/dev/null || true

log "Security groups (db before app: db references app as a source)"
aws ec2 delete-security-group --group-id "$USMS_DB_SG_ID" 2>/dev/null || true
aws ec2 delete-security-group --group-id "$USMS_APP_SG_ID" 2>/dev/null || true

log "Subnets"
for s in "$USMS_PUBLIC_SUBNET_A_ID" "$USMS_PUBLIC_SUBNET_B_ID" "$USMS_PRIVATE_SUBNET_A_ID"; do
  aws ec2 delete-subnet --subnet-id "$s" 2>/dev/null || true
done

log "Internet gateway (detach, then delete)"
aws ec2 detach-internet-gateway --internet-gateway-id "$USMS_IGW_ID" --vpc-id "$USMS_VPC_ID" 2>/dev/null || true
aws ec2 delete-internet-gateway --internet-gateway-id "$USMS_IGW_ID" 2>/dev/null || true

log "VPC"
aws ec2 delete-vpc --vpc-id "$USMS_VPC_ID" 2>/dev/null || true

log "Lab 02 resources removed. configs/lab-02.env left in place for reference; delete it manually if desired."
