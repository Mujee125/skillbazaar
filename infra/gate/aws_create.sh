#!/usr/bin/env bash
# Create ONE gate server on AWS. Dry run unless --apply is given.
set -euo pipefail

export AWS_PROFILE="sb-gate"
export AWS_DEFAULT_REGION="ap-southeast-2"
PREFIX="sb-gate-"
INSTANCE_TYPE="t3.small"
APPLY="no"
if [[ "${1:-}" == "--apply" ]]; then APPLY="yes"; fi

AMI_ID=$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-*-26.04-amd64-server-*" \
  --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text | tr -d '\r')
if [[ ! "$AMI_ID" =~ ^ami- ]]; then echo "ERROR: no Ubuntu image found"; exit 1; fi

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
if [[ ! "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "ERROR: could not read my ip"; exit 1; fi
echo "my ip: looks valid"

EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text | tr -d '\r')
if [[ -n "$EXISTING" ]]; then echo "ERROR: an ${PREFIX} instance already exists"; exit 1; fi
echo "existing sb-gate instances: 0"

echo "plan: 1 x $INSTANCE_TYPE, image $AMI_ID, region $AWS_DEFAULT_REGION, SSH from my ip /32 only"
if [[ "$APPLY" != "yes" ]]; then echo "DRY RUN: nothing created. Use --apply to create."; exit 0; fi
echo "ERROR: --apply is not implemented yet (part 2)"; exit 1
