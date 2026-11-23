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

KEY_NAME="${PREFIX}key"
SG_NAME="${PREFIX}sg"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
mkdir -p "$HOME/.ssh"
if [[ -e "$KEY_FILE" ]]; then echo "ERROR: key file already exists: $KEY_FILE"; exit 1; fi

aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text | tr -d '\r' > "$KEY_FILE"
chmod 600 "$KEY_FILE"
echo "key pair created: $KEY_NAME (private key saved outside the repo)"

SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "sb-gate ssh from my ip only" --query GroupId --output text | tr -d '\r')
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32" > /dev/null
echo "security group created: $SG_ID (SSH from my ip /32 only)"

INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --count 1 \
  --metadata-options HttpTokens=required \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PREFIX}db}]" "ResourceType=volume,Tags=[{Key=Name,Value=${PREFIX}db}]" \
  --query "Instances[0].InstanceId" --output text | tr -d '\r')
echo "launched: $INSTANCE_ID at $(date -u +%H:%M:%SZ)"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].[InstanceType,Architecture,State.Name]" --output text
echo "REMEMBER: run infra/gate/aws_teardown.sh --apply today"
