#!/usr/bin/env bash
# Delete ONLY sb-gate- resources, then verify. Dry run unless --apply is given.
set -euo pipefail

export AWS_PROFILE="sb-gate"
export AWS_DEFAULT_REGION="ap-southeast-2"
PREFIX="sb-gate-"
KEY_NAME="${PREFIX}key"
SG_NAME="${PREFIX}sg"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
APPLY="no"
if [[ "${1:-}" == "--apply" ]]; then APPLY="yes"; fi

ALIVE="pending,running,stopping,stopped,shutting-down"
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}*" "Name=instance-state-name,Values=${ALIVE}" \
  --query "Reservations[].Instances[].InstanceId" --output text | tr -d '\r')
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
  --query "SecurityGroups[0].GroupId" --output text | tr -d '\r')
KEY_FOUND=$(aws ec2 describe-key-pairs --filters "Name=key-name,Values=${KEY_NAME}" \
  --query "KeyPairs[].KeyName" --output text | tr -d '\r')
HAS_FILE="no"; if [[ -e "$KEY_FILE" ]]; then HAS_FILE="yes"; fi

echo "to delete: instances=[${INSTANCES:-none}] sg=[${SG_ID}] key=[${KEY_FOUND:-none}] keyfile=${HAS_FILE}"
if [[ "$APPLY" != "yes" ]]; then echo "DRY RUN: nothing deleted. Use --apply to delete."; exit 0; fi

if [[ -n "$INSTANCES" ]]; then
  aws ec2 terminate-instances --instance-ids $INSTANCES > /dev/null
  aws ec2 wait instance-terminated --instance-ids $INSTANCES
  echo "instances terminated"
fi
if [[ "$SG_ID" != "None" ]]; then
  aws ec2 delete-security-group --group-id "$SG_ID" > /dev/null
  echo "security group deleted"
fi
if [[ -n "$KEY_FOUND" ]]; then
  aws ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null
  echo "key pair deleted"
fi
rm -f "$KEY_FILE"

N_INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}*" "Name=instance-state-name,Values=${ALIVE}" \
  --query "length(Reservations[].Instances[])" --output text | tr -d '\r')
N_VOL=$(aws ec2 describe-volumes --query "length(Volumes)" --output text | tr -d '\r')
N_EIP=$(aws ec2 describe-addresses --query "length(Addresses)" --output text | tr -d '\r')
N_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
  --query "length(SecurityGroups)" --output text | tr -d '\r')
N_KEY=$(aws ec2 describe-key-pairs --filters "Name=key-name,Values=${KEY_NAME}" \
  --query "length(KeyPairs)" --output text | tr -d '\r')
echo "verify: instances=$N_INST volumes=$N_VOL elastic_ips=$N_EIP sg=$N_SG key=$N_KEY"
if [[ "$N_INST$N_VOL$N_EIP$N_SG$N_KEY" != "00000" ]]; then echo "ERROR: leftovers found"; exit 1; fi
echo "teardown verified: clean"
