#!/bin/bash
###############################################################################
# AuraBank – Bootstrap Terraform Remote State
# Run this ONCE before the first `terraform init` in any environment.
# Creates:
#   - S3 bucket for state files (versioned + encrypted)
#   - DynamoDB table for state locking
###############################################################################

set -euo pipefail

ENV="${1:-dev}"
REGION="${2:-eu-west-1}"
PROJECT="aurabank"

BUCKET="${PROJECT}-terraform-state-${ENV}"
TABLE="${PROJECT}-terraform-locks-${ENV}"

echo "🚀 Bootstrapping Terraform remote state for env=${ENV} region=${REGION}"
echo "   Bucket: ${BUCKET}"
echo "   Table:  ${TABLE}"
echo ""

# ── S3 Bucket ─────────────────────────────────────────────────────────────────
echo "📦 Creating S3 bucket..."

if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "   ✅ Bucket already exists: ${BUCKET}"
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "   ✅ Bucket created: ${BUCKET}"
fi

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
echo "   ✅ Versioning enabled"

# Enable server-side encryption (AES256)
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'
echo "   ✅ Encryption enabled"

# Block all public access
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "   ✅ Public access blocked"

# Lifecycle: expire old versions after 90 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BUCKET}" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-old-versions",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90}
    }]
  }'
echo "   ✅ Lifecycle policy set"

# ── DynamoDB Table for Locking ─────────────────────────────────────────────────
echo ""
echo "🔒 Creating DynamoDB lock table..."

if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "   ✅ DynamoDB table already exists: ${TABLE}"
else
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" \
    --tags Key=Project,Value="${PROJECT}" Key=Environment,Value="${ENV}" Key=ManagedBy,Value=bootstrap

  echo "   ⏳ Waiting for table to become active..."
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
  echo "   ✅ DynamoDB table created: ${TABLE}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Bootstrap complete for env=${ENV}"
echo ""
echo "Now run:"
echo "  cd envs/${ENV}"
echo "  terraform init"
echo "  terraform plan -var-file=terraform.tfvars"
echo "  terraform apply -var-file=terraform.tfvars"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
