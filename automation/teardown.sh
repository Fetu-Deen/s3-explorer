#!/bin/bash
# =============================================================================
# CloudVault — Full AWS Infrastructure Teardown Script
# =============================================================================
#
# Deletes EVERYTHING created by setup.sh in the correct order:
#   1.  Disable + delete CloudFront distribution + OAC
#   2.  Remove S3 → Lambda notification
#   3.  Remove Lambda permission for S3
#   4.  Delete Lambda function
#   5.  Terminate EC2 instance (wait until fully terminated)
#   6.  Delete RDS instance    (wait until fully deleted)
#   7.  Delete EC2 security group
#   8.  Delete RDS security group
#   9.  Delete EC2 IAM role + instance profile
#   10. Detach IAM Lambda role policies + delete role
#   11. Empty S3 bucket (delete all files and thumbnails)
#   12. Delete S3 bucket
#   13. Delete EC2 key pair from AWS
#   14. Delete local .pem key file
#   15. Reset App.js API constant back to placeholder
#   16. Delete this config file
#
# Usage:
#   chmod +x teardown.sh
#   ./teardown.sh
# =============================================================================

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/cloudvault-config.env"
APP_DIR="$(dirname "$SCRIPT_DIR")"

print_step() { echo -e "\n${BLUE}[$1] $2${NC}"; }
print_ok()   { echo -e "  ${GREEN}✓ $1${NC}"; }
print_warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
print_skip() { echo -e "  ${YELLOW}→ Skipped: $1${NC}"; }
print_err()  { echo -e "  ${RED}✗ $1${NC}"; }

# =============================================================================
# Load config saved by setup.sh
# =============================================================================
load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    print_err "Config file not found: $CONFIG_FILE"
    echo "  Run setup.sh first, or the config file was already deleted."
    exit 1
  fi

  # Source all variables from the config file
  source "$CONFIG_FILE"

  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           CloudVault — Teardown Script                   ║"
  echo "║     Deletes ALL AWS resources created by setup.sh        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo "  The following AWS resources will be permanently deleted:"
  echo ""
  echo "    S3 bucket:    $BUCKET_NAME  (ALL files inside will be deleted)"
  echo "    RDS instance: $DB_IDENTIFIER"
  echo "    EC2 instance: $EC2_INSTANCE_ID ($EC2_IP)"
  echo "    Lambda:       $LAMBDA_FUNCTION_NAME"
  echo "    IAM user:     $IAM_USER"
  echo "    IAM role:     $LAMBDA_ROLE_NAME"
  echo "    Key pair:     $KEY_NAME"
  echo "    Local key:    $KEY_PATH"
  echo ""

  # Confirm before destroying anything
  read -p "  Type 'delete' to confirm teardown: " CONFIRM
  if [ "$CONFIRM" != "delete" ]; then
    echo "  Teardown cancelled."
    exit 0
  fi

  echo ""
}

# =============================================================================
# STEP 1 — Disable and delete CloudFront distribution
# =============================================================================
# CloudFront must be disabled before it can be deleted.
# Disabling triggers a redeployment that takes ~5 minutes.
# =============================================================================
delete_cloudfront() {
  print_step "1" "Disabling CloudFront distribution: $CF_DISTRIBUTION_ID"

  # Get current config + ETag
  CURRENT=$(aws cloudfront get-distribution-config --id "$CF_DISTRIBUTION_ID" 2>/dev/null)
  if [ -z "$CURRENT" ]; then
    print_skip "CloudFront distribution already deleted"
    return
  fi

  ETAG=$(echo "$CURRENT" | jq -r '.ETag')
  DISABLED_CONFIG=$(echo "$CURRENT" | jq '.DistributionConfig.Enabled = false | .DistributionConfig')

  TMPFILE=$(mktemp)
  echo "$DISABLED_CONFIG" > "$TMPFILE"

  NEW_ETAG=$(aws cloudfront update-distribution \
    --id "$CF_DISTRIBUTION_ID" \
    --distribution-config "file://$TMPFILE" \
    --if-match "$ETAG" \
    --query "ETag" --output text)
  rm "$TMPFILE"

  echo -n "  Waiting for distribution to disable: "
  while true; do
    STATUS=$(aws cloudfront get-distribution \
      --id "$CF_DISTRIBUTION_ID" \
      --query "Distribution.Status" --output text 2>/dev/null)
    [ "$STATUS" = "Deployed" ] && { echo ""; break; }
    echo -n "."
    sleep 15
  done

  aws cloudfront delete-distribution \
    --id "$CF_DISTRIBUTION_ID" \
    --if-match "$NEW_ETAG" 2>/dev/null || print_skip "Distribution already deleted"

  # Delete the Origin Access Control
  aws cloudfront delete-origin-access-control \
    --id "$CF_OAC_ID" 2>/dev/null || print_skip "OAC already deleted"

  print_ok "CloudFront distribution and OAC deleted"
}

# =============================================================================
# STEP 2 — Remove S3 → Lambda notification
# =============================================================================
remove_s3_notification() {
  print_step "1" "Removing S3 event notification..."

  aws s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration '{}' 2>/dev/null || print_skip "notification already removed"

  print_ok "S3 notification cleared"
}

# =============================================================================
# STEP 2 — Remove Lambda permission for S3
# =============================================================================
remove_lambda_permission() {
  print_step "2" "Removing Lambda S3 invoke permission..."

  aws lambda remove-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id "s3-trigger-${SUFFIX}" \
    2>/dev/null || print_skip "permission already removed"

  print_ok "Lambda permission removed"
}

# =============================================================================
# STEP 3 — Delete Lambda function
# =============================================================================
delete_lambda() {
  print_step "3" "Deleting Lambda function: $LAMBDA_FUNCTION_NAME"

  aws lambda delete-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    2>/dev/null || print_skip "Lambda already deleted"

  print_ok "Lambda function deleted"
}

# =============================================================================
# STEP 4 — Terminate EC2 instance and wait
# =============================================================================
terminate_ec2() {
  print_step "4" "Terminating EC2 instance: $EC2_INSTANCE_ID"

  aws ec2 terminate-instances \
    --instance-ids "$EC2_INSTANCE_ID" \
    > /dev/null 2>/dev/null || print_skip "EC2 already terminated"

  echo -n "  Waiting for EC2 to terminate: "
  while true; do
    STATE=$(aws ec2 describe-instances \
      --instance-ids "$EC2_INSTANCE_ID" \
      --query "Reservations[0].Instances[0].State.Name" \
      --output text 2>/dev/null)

    if [ "$STATE" = "terminated" ]; then
      echo ""
      break
    fi
    echo -n "."
    sleep 10
  done

  print_ok "EC2 terminated"
}

# =============================================================================
# STEP 5 — Delete RDS instance and wait (no final snapshot)
# =============================================================================
delete_rds() {
  print_step "5" "Deleting RDS instance: $DB_IDENTIFIER (no snapshot)"

  aws rds delete-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --skip-final-snapshot \
    --delete-automated-backups \
    > /dev/null 2>/dev/null || print_skip "RDS already deleted"

  echo -n "  Waiting for RDS to be deleted: "
  while true; do
    STATUS=$(aws rds describe-db-instances \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --query "DBInstances[0].DBInstanceStatus" \
      --output text 2>/dev/null)

    # When RDS is gone, describe returns empty or an error
    if [ -z "$STATUS" ] || [ "$STATUS" = "None" ] || [ "$STATUS" = "" ]; then
      echo ""
      break
    fi
    echo -n "."
    sleep 15
  done

  print_ok "RDS deleted"
}

# =============================================================================
# STEP 6 — Delete EC2 security group
# =============================================================================
# Security groups can only be deleted after no instances reference them
# That's why this runs after EC2 is terminated (step 4)
# =============================================================================
delete_ec2_sg() {
  print_step "6" "Deleting EC2 security group: $EC2_SG_ID"

  # Brief wait to ensure EC2 has fully released the SG
  sleep 5

  aws ec2 delete-security-group \
    --group-id "$EC2_SG_ID" \
    2>/dev/null || print_skip "EC2 SG already deleted or still in use"

  print_ok "EC2 security group deleted"
}

# =============================================================================
# STEP 7 — Delete RDS security group
# =============================================================================
delete_rds_sg() {
  print_step "7" "Deleting RDS security group: $RDS_SG_ID"

  aws ec2 delete-security-group \
    --group-id "$RDS_SG_ID" \
    2>/dev/null || print_skip "RDS SG already deleted"

  print_ok "RDS security group deleted"
}

# =============================================================================
# STEP 8 — Delete EC2 IAM role and instance profile
# =============================================================================
# Order matters:
#   1. Remove role from instance profile (can't delete profile with roles inside)
#   2. Detach policies from role       (can't delete role with attached policies)
#   3. Delete instance profile
#   4. Delete role
# EC2 must already be terminated (step 4) before the profile can be deleted
# =============================================================================
delete_ec2_role() {
  print_step "8" "Deleting EC2 IAM role and instance profile: $EC2_ROLE_NAME"

  # Remove role from instance profile
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$EC2_PROFILE_NAME" \
    --role-name "$EC2_ROLE_NAME" \
    2>/dev/null || print_skip "Role already removed from instance profile"

  # Detach all policies from the role
  POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$EC2_ROLE_NAME" \
    --query "AttachedPolicies[*].PolicyArn" \
    --output text 2>/dev/null)

  for POLICY_ARN in $POLICIES; do
    aws iam detach-role-policy \
      --role-name "$EC2_ROLE_NAME" \
      --policy-arn "$POLICY_ARN" 2>/dev/null
    echo "  Detached policy: $POLICY_ARN"
  done

  # Delete the instance profile
  aws iam delete-instance-profile \
    --instance-profile-name "$EC2_PROFILE_NAME" \
    2>/dev/null || print_skip "Instance profile already deleted"

  # Delete the role
  aws iam delete-role \
    --role-name "$EC2_ROLE_NAME" \
    2>/dev/null || print_skip "EC2 role already deleted"

  print_ok "EC2 IAM role and instance profile deleted"
}

# =============================================================================
# STEP 9 — Delete Lambda IAM role (detach policies first)
# =============================================================================
delete_lambda_role() {
  print_step "9" "Deleting Lambda IAM role: $LAMBDA_ROLE_NAME"

  # Detach all attached policies (can't delete role with attached policies)
  POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$LAMBDA_ROLE_NAME" \
    --query "AttachedPolicies[*].PolicyArn" \
    --output text 2>/dev/null)

  for POLICY_ARN in $POLICIES; do
    aws iam detach-role-policy \
      --role-name "$LAMBDA_ROLE_NAME" \
      --policy-arn "$POLICY_ARN" 2>/dev/null
    echo "  Detached policy: $POLICY_ARN"
  done

  aws iam delete-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    2>/dev/null || print_skip "Lambda role already deleted"

  print_ok "Lambda IAM role deleted"
}

# =============================================================================
# STEP 10 — Empty S3 bucket (delete all files and thumbnails)
# =============================================================================
# S3 buckets cannot be deleted unless they are empty.
# This deletes all objects including files in thumbnails/ subfolder.
# =============================================================================
empty_s3_bucket() {
  print_step "10" "Emptying S3 bucket: $BUCKET_NAME"

  # Delete all objects recursively
  aws s3 rm "s3://$BUCKET_NAME" --recursive 2>/dev/null || true

  print_ok "S3 bucket emptied"
}

# =============================================================================
# STEP 11 — Delete S3 bucket
# =============================================================================
delete_s3_bucket() {
  print_step "11" "Deleting S3 bucket: $BUCKET_NAME"

  aws s3api delete-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    2>/dev/null || print_skip "S3 bucket already deleted"

  print_ok "S3 bucket deleted"
}

# =============================================================================
# STEP 12 — Delete EC2 key pair from AWS
# =============================================================================
delete_key_pair() {
  print_step "12" "Deleting key pair: $KEY_NAME"

  aws ec2 delete-key-pair \
    --key-name "$KEY_NAME" \
    2>/dev/null || print_skip "Key pair already deleted"

  print_ok "Key pair deleted from AWS"
}

# =============================================================================
# STEP 13 — Delete local .pem key file
# =============================================================================
delete_local_key() {
  print_step "13" "Deleting local key file: $KEY_PATH"

  if [ -f "$KEY_PATH" ]; then
    rm -f "$KEY_PATH"
    print_ok "Local key file deleted"
  else
    print_skip "Key file not found locally"
  fi
}

# =============================================================================
# STEP 14 — Reset App.js API constant back to placeholder
# =============================================================================
reset_app_js() {
  print_step "14" "Resetting App.js API constant..."

  APP_JS="$APP_DIR/src/App.js"
  if [ -f "$APP_JS" ]; then
    sed -i '' \
      "s|const API = \"http://.*:4000\"|const API = \"http://YOUR_EC2_IP:4000\"|" \
      "$APP_JS"
    print_ok "App.js reset — update the IP next time you run setup.sh (it does this automatically)"
  else
    print_skip "App.js not found"
  fi
}

# =============================================================================
# STEP 15 — Delete config file
# =============================================================================
delete_config() {
  print_step "15" "Deleting config file..."

  rm -f "$CONFIG_FILE"
  print_ok "Config file deleted"
}

# =============================================================================
# Final summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║          All CloudVault resources deleted!               ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Your AWS account is clean."
  echo "  To rebuild everything from scratch, run: ./setup.sh"
  echo ""
}

# =============================================================================
# MAIN — Run all teardown steps in order
# =============================================================================
main() {
  load_config              # load saved resource IDs from setup.sh

  delete_cloudfront        # step 1  — disable + delete CloudFront + OAC
  remove_s3_notification   # step 2  — disconnect S3 from Lambda
  remove_lambda_permission # step 3  — revoke S3's right to invoke Lambda
  delete_lambda            # step 4  — delete Lambda function
  terminate_ec2            # step 5  — terminate EC2 + wait
  delete_rds               # step 6  — delete RDS + wait
  delete_ec2_sg            # step 7  — delete EC2 security group
  delete_rds_sg            # step 8  — delete RDS security group
  delete_ec2_role          # step 9  — delete EC2 IAM role + instance profile
  delete_lambda_role       # step 10 — delete Lambda IAM role
  empty_s3_bucket          # step 11 — delete all files in bucket
  delete_s3_bucket         # step 12 — delete the bucket itself
  delete_key_pair          # step 13 — delete key pair from AWS
  delete_local_key         # step 14 — delete local .pem file
  reset_app_js             # step 15 — reset App.js placeholder
  delete_config            # step 16 — delete cloudvault-config.env

  print_summary
}

main
