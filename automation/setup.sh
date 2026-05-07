#!/bin/bash
# =============================================================================
# CloudVault — Full AWS Infrastructure Setup Script
# =============================================================================
#
# What this script creates (in order):
#   1.  S3 bucket              — stores uploaded files + thumbnails
#   2.  IAM user               — credentials for Express server to access S3
#   3.  IAM role for Lambda    — allows Lambda to read/write S3
#   4.  EC2 security group     — allows SSH (22) and API traffic (4000)
#   5.  RDS security group     — allows MySQL (3306) from EC2 only
#   6.  RDS MySQL instance     — stores file metadata (name, size, description)
#   7.  EC2 key pair           — SSH access to the server
#   8.  EC2 instance           — runs the Express API server
#   9.  Waits for RDS          — polls until database is available (~5-10 min)
#   10. Updates App.js         — injects the new EC2 IP into the React app
#   11. Waits for EC2 SSH      — polls until the instance accepts connections
#   12. Waits for Node.js      — polls until user data finishes installing Node
#   13. Deploys server.js      — SCPs code + .env to EC2, starts with PM2
#   14. Builds Lambda on EC2   — installs sharp (Linux binary) and zips
#   15. Creates Lambda         — uploads zip and configures the function
#   16. S3 → Lambda trigger    — fires Lambda on every file upload
#   17. Saves config           — writes cloudvault-config.env for teardown.sh
#
# Prerequisites (must be installed before running):
#   - AWS CLI  → brew install awscli  (then: aws configure)
#   - jq       → brew install jq
#   - ssh, scp → pre-installed on Mac
#   - zip      → pre-installed on Mac
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
# =============================================================================

set -e  # Exit immediately if any command fails

# ── Color codes for readable terminal output ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (reset)

# ── Directories ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # automation/
FILES_DIR="$SCRIPT_DIR/files"                                # automation/files/
APP_DIR="$(dirname "$SCRIPT_DIR")"                           # s3-explorer/
CONFIG_FILE="$SCRIPT_DIR/cloudvault-config.env"              # saved after setup

# ── AWS settings ──────────────────────────────────────────────────────────────
REGION="us-east-1"

# ── Unique suffix — appended to resource names to avoid conflicts on re-run ───
SUFFIX=$(date +%s | tail -c 7)
EC2_ROLE_NAME="cloudvault-ec2-role-${SUFFIX}"
EC2_PROFILE_NAME="cloudvault-ec2-profile-${SUFFIX}"
LAMBDA_ROLE_NAME="cloudvault-lambda-role-${SUFFIX}"

# ── Helper print functions ────────────────────────────────────────────────────
print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           CloudVault — AWS Setup Script                  ║"
  echo "║     Builds all infrastructure from zero automatically    ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() { echo -e "\n${BLUE}[$1] $2${NC}"; }
print_ok()   { echo -e "  ${GREEN}✓ $1${NC}"; }
print_warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
print_err()  { echo -e "  ${RED}✗ $1${NC}"; }

# =============================================================================
# STEP 0 — Prerequisites check
# =============================================================================
check_prerequisites() {
  print_step "0" "Checking prerequisites..."

  # Check required CLI tools are installed
  for cmd in aws jq ssh scp zip; do
    if ! command -v "$cmd" &>/dev/null; then
      print_err "$cmd is not installed."
      [ "$cmd" = "jq" ] && echo "    Run: brew install jq"
      [ "$cmd" = "aws" ] && echo "    Run: brew install awscli && aws configure"
      exit 1
    fi
  done

  # Check AWS CLI is authenticated
  if ! aws sts get-caller-identity &>/dev/null; then
    print_err "AWS CLI is not configured. Run: aws configure"
    exit 1
  fi

  # Check required source files exist
  if [ ! -f "$FILES_DIR/server.js" ]; then
    print_err "Missing: $FILES_DIR/server.js"
    exit 1
  fi
  if [ ! -f "$FILES_DIR/lambda-index.js" ]; then
    print_err "Missing: $FILES_DIR/lambda-index.js"
    exit 1
  fi

  print_ok "All prerequisites met"
  echo -e "  AWS account: $(aws sts get-caller-identity --query Account --output text)"
  echo -e "  Region:      $REGION"
}

# =============================================================================
# STEP 1 — Prompt for secrets
# =============================================================================
prompt_secrets() {
  print_step "1" "Configuration..."

  echo ""
  echo "  CloudVault needs a few inputs before starting."
  echo "  Generated resource names will include a unique suffix: ${SUFFIX}"
  echo ""

  # S3 bucket name — must be globally unique across all AWS accounts
  BUCKET_NAME="cloudvault-files-${SUFFIX}"
  echo -e "  ${CYAN}S3 bucket name:${NC} $BUCKET_NAME (auto-generated)"

  # RDS password — use env var if set, otherwise prompt interactively
  echo ""
  if [ -n "$DB_PASSWORD" ] && [ ${#DB_PASSWORD} -ge 8 ]; then
    echo "  Using provided DB_PASSWORD (${#DB_PASSWORD} chars)"
  else
    while true; do
      read -s -p "  Enter RDS database password (min 8 chars, no special chars @/\"): " DB_PASSWORD
      echo ""
      if [ ${#DB_PASSWORD} -ge 8 ]; then
        break
      fi
      print_warn "Password must be at least 8 characters. Try again."
    done
  fi

  # Fixed DB settings
  DB_NAME="cloudvault"
  DB_USER="admin"
  DB_IDENTIFIER="cloudvault-db-${SUFFIX}"

  print_ok "Configuration ready"
}

# =============================================================================
# STEP 2 — Create S3 bucket
# =============================================================================
create_s3_bucket() {
  print_step "2" "Creating S3 bucket: $BUCKET_NAME"

  # Create the bucket (us-east-1 does NOT need --create-bucket-configuration)
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    > /dev/null

  # Block all public access — files are served via pre-signed URLs only
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  print_ok "S3 bucket created: $BUCKET_NAME"
}

# =============================================================================
# STEP 3 — Create IAM role + instance profile for EC2
# =============================================================================
# EC2 uses a ROLE (not user keys) — AWS auto-injects temporary credentials
# via the instance metadata service. No secrets stored in .env or code.
# =============================================================================
create_ec2_role() {
  print_step "3" "Creating IAM role for EC2: ${EC2_ROLE_NAME}"

  EC2_TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

  aws iam create-role \
    --role-name "${EC2_ROLE_NAME}" \
    --assume-role-policy-document "$EC2_TRUST_POLICY" \
    > /dev/null

  aws iam attach-role-policy \
    --role-name "${EC2_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess"

  aws iam create-instance-profile \
    --instance-profile-name "${EC2_PROFILE_NAME}" \
    > /dev/null

  aws iam add-role-to-instance-profile \
    --instance-profile-name "${EC2_PROFILE_NAME}" \
    --role-name "${EC2_ROLE_NAME}"

  print_ok "EC2 role and instance profile created: ${EC2_PROFILE_NAME}"

  echo "  Waiting 15s for instance profile to propagate..."
  sleep 15
}

# =============================================================================
# STEP 4 — Create IAM role for Lambda
# =============================================================================
# Lambda uses a ROLE (not user keys) — AWS auto-injects temporary credentials
# This is more secure than storing keys in code
# =============================================================================
create_lambda_role() {
  print_step "4" "Creating IAM role for Lambda: ${LAMBDA_ROLE_NAME}"

  # Trust policy — declares that the Lambda service can assume this role
  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

  LAMBDA_ROLE_ARN=$(aws iam create-role \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document "$TRUST_POLICY" \
    | jq -r '.Role.Arn')

  # Allow Lambda to read/write S3 (download original, upload thumbnail)
  aws iam attach-role-policy \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess"

  # Allow Lambda to write logs to CloudWatch (for debugging)
  aws iam attach-role-policy \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

  print_ok "Lambda role created: $LAMBDA_ROLE_ARN"

  # IAM roles take a few seconds to propagate across AWS globally
  echo "  Waiting 15s for IAM role to propagate..."
  sleep 15
}

# =============================================================================
# STEP 5 — Create security groups
# =============================================================================
# EC2 security group:
#   - Port 22   (SSH)  — so we can deploy code
#   - Port 4000 (API)  — so React app can call the Express server
#
# RDS security group:
#   - Port 3306 (MySQL) — only from EC2's security group (not public internet)
# =============================================================================
create_security_groups() {
  print_step "5" "Creating security groups..."

  # Find the default VPC — all resources go here
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

  echo "  Using VPC: $VPC_ID"

  # ── EC2 security group ──────────────────────────────────────────────────────
  EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name "cloudvault-ec2-sg-${SUFFIX}" \
    --description "CloudVault EC2 - SSH and API access" \
    --vpc-id "$VPC_ID" \
    | jq -r '.GroupId')

  # Allow SSH from anywhere (you can restrict to your IP for better security)
  aws ec2 authorize-security-group-ingress \
    --group-id "$EC2_SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

  # Allow port 4000 from anywhere (Express API)
  aws ec2 authorize-security-group-ingress \
    --group-id "$EC2_SG_ID" \
    --protocol tcp --port 4000 --cidr 0.0.0.0/0 > /dev/null

  print_ok "EC2 security group: $EC2_SG_ID"

  # ── RDS security group ──────────────────────────────────────────────────────
  RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "cloudvault-rds-sg-${SUFFIX}" \
    --description "CloudVault RDS - MySQL access from EC2 only" \
    --vpc-id "$VPC_ID" \
    | jq -r '.GroupId')

  # Allow MySQL ONLY from the EC2 security group — not from the public internet
  # This means: only EC2 instances in cloudvault-ec2-sg can reach the database
  aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" \
    --protocol tcp --port 3306 \
    --source-group "$EC2_SG_ID" > /dev/null

  print_ok "RDS security group: $RDS_SG_ID (MySQL only from EC2)"
}

# =============================================================================
# STEP 6 — Start RDS creation (runs in background while we set up other things)
# =============================================================================
# RDS takes 5-10 minutes to become available.
# We kick it off now and wait for it later (step 9) so it runs in parallel
# with EC2 setup, saving several minutes of total time.
# =============================================================================
create_rds() {
  print_step "6" "Starting RDS MySQL creation (runs in background)..."

  aws rds create-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --db-instance-class db.t4g.micro \
    --engine mysql \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage 20 \
    --db-name "$DB_NAME" \
    --vpc-security-group-ids "$RDS_SG_ID" \
    --publicly-accessible \
    --no-multi-az \
    --no-deletion-protection \
    > /dev/null

  print_ok "RDS creation started: $DB_IDENTIFIER (will wait for it in step 9)"
}

# =============================================================================
# STEP 7 — Create EC2 key pair
# =============================================================================
create_key_pair() {
  print_step "7" "Creating EC2 key pair..."

  KEY_NAME="cloudvault-key-${SUFFIX}"
  KEY_PATH="$HOME/Downloads/${KEY_NAME}.pem"

  # Generate key pair and save the private key locally
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query "KeyMaterial" \
    --output text > "$KEY_PATH"

  # Restrict permissions — SSH requires the key file to be private
  chmod 400 "$KEY_PATH"

  print_ok "Key pair saved: $KEY_PATH"
}

# =============================================================================
# STEP 8 — Launch EC2 instance
# =============================================================================
# User data = a shell script that runs automatically on first boot
# We use it to pre-install Node.js and PM2 so they're ready when we SSH in
# =============================================================================
create_ec2() {
  print_step "8" "Launching EC2 instance..."

  # Write user data script to a temp file (auto-runs on EC2 first boot)
  USER_DATA_FILE=$(mktemp)
  cat > "$USER_DATA_FILE" << 'USERDATA'
#!/bin/bash
# This script runs automatically when EC2 first boots
dnf install -y nodejs npm
npm install -g pm2
USERDATA

  # Find the latest Amazon Linux 2023 AMI for x86_64
  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters \
      "Name=name,Values=al2023-ami-*-x86_64" \
      "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

  echo "  Using AMI: $AMI_ID"

  # Launch the instance with the EC2 IAM instance profile attached
  EC2_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t3.micro \
    --key-name "$KEY_NAME" \
    --security-group-ids "$EC2_SG_ID" \
    --iam-instance-profile Name="${EC2_PROFILE_NAME}" \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=cloudvault-server}]" \
    | jq -r '.Instances[0].InstanceId')

  rm "$USER_DATA_FILE"

  print_ok "EC2 instance launched: $EC2_INSTANCE_ID"

  # Wait until EC2 reports "running" state
  echo "  Waiting for EC2 to reach running state..."
  aws ec2 wait instance-running --instance-ids "$EC2_INSTANCE_ID"

  # Get the public IP assigned to the instance
  EC2_IP=$(aws ec2 describe-instances \
    --instance-ids "$EC2_INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

  print_ok "EC2 is running at: $EC2_IP"
}

# =============================================================================
# STEP 9 — Update React App.js with the new EC2 IP
# =============================================================================
update_app_js() {
  print_step "9" "Updating App.js with EC2 IP: $EC2_IP"

  # Replace whatever IP was in the API constant with the new EC2 IP
  sed -i '' \
    "s|const API = \"http://.*:4000\"|const API = \"http://${EC2_IP}:4000\"|" \
    "$APP_DIR/src/App.js"

  print_ok "App.js updated → API points to http://${EC2_IP}:4000"
}

# =============================================================================
# STEP 10 — Wait for RDS to be available
# =============================================================================
wait_for_rds() {
  print_step "10" "Waiting for RDS to be available (5-10 minutes)..."
  echo -n "  Progress: "

  while true; do
    STATUS=$(aws rds describe-db-instances \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --query "DBInstances[0].DBInstanceStatus" \
      --output text 2>/dev/null)

    if [ "$STATUS" = "available" ]; then
      echo ""
      break
    fi

    echo -n "."
    sleep 15
  done

  # Fetch the RDS hostname now that it's available
  DB_HOST=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

  print_ok "RDS ready: $DB_HOST"
}

# =============================================================================
# STEP 11 — Wait for EC2 SSH to accept connections
# =============================================================================
wait_for_ssh() {
  print_step "11" "Waiting for EC2 SSH to be ready..."
  echo -n "  Progress: "

  while true; do
    if ssh \
      -i "$KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      ec2-user@"$EC2_IP" "echo ok" &>/dev/null; then
      echo ""
      break
    fi
    echo -n "."
    sleep 5
  done

  print_ok "SSH is ready"
}

# =============================================================================
# STEP 12 — Wait for Node.js and PM2 to finish installing (from user data)
# =============================================================================
# EC2 user data runs asynchronously. SSH may be ready before Node.js is done.
# We poll until both npm and pm2 are available before deploying.
# =============================================================================
wait_for_nodejs() {
  print_step "12" "Waiting for Node.js and PM2 to finish installing on EC2..."
  echo -n "  Progress: "

  while true; do
    if ssh \
      -i "$KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      ec2-user@"$EC2_IP" \
      "command -v npm &>/dev/null && command -v pm2 &>/dev/null" 2>/dev/null; then
      echo ""
      break
    fi
    echo -n "."
    sleep 10
  done

  print_ok "Node.js and PM2 are ready on EC2"
}

# =============================================================================
# STEP 13 — Deploy server.js to EC2
# =============================================================================
# Creates the app directory, writes the .env, copies server.js,
# installs npm dependencies, and starts the server with PM2
# =============================================================================
deploy_server() {
  print_step "13" "Deploying server to EC2..."

  # ── Write .env to a local temp file (avoids shell escaping issues with SCP) ─
  ENV_FILE=$(mktemp)
  cat > "$ENV_FILE" << EOF
AWS_REGION=${REGION}
S3_BUCKET=${BUCKET_NAME}
DB_HOST=${DB_HOST}
DB_USER=${DB_USER}
DB_PASS=${DB_PASSWORD}
DB_NAME=${DB_NAME}
PORT=4000
EOF

  # ── Create app directory on EC2 ────────────────────────────────────────────
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    ec2-user@"$EC2_IP" "mkdir -p ~/cloudvault"

  # ── Copy server.js and .env to EC2 ─────────────────────────────────────────
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    "$FILES_DIR/server.js" \
    ec2-user@"$EC2_IP":~/cloudvault/server.js

  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    "$ENV_FILE" \
    ec2-user@"$EC2_IP":~/cloudvault/.env

  rm "$ENV_FILE"

  # ── Install dependencies and start server with PM2 ─────────────────────────
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    ec2-user@"$EC2_IP" << 'ENDSSH'
    set -e
    cd ~/cloudvault

    # Initialize package.json and install all required npm packages
    npm init -y > /dev/null
    npm install express cors multer mysql2 dotenv \
      @aws-sdk/client-s3 @aws-sdk/s3-request-presigner > /dev/null

    # Start server with PM2 (keeps it running, restarts on crash)
    pm2 start server.js --name cloudvault
    pm2 save

    # Set PM2 to auto-start on system reboot
    STARTUP_CMD=$(pm2 startup 2>&1 | grep "sudo env")
    if [ -n "$STARTUP_CMD" ]; then
      eval "$STARTUP_CMD"
    fi
ENDSSH

  print_ok "Server deployed and running on EC2 with PM2"
}

# =============================================================================
# STEP 14 — Build Lambda package on EC2 and deploy to AWS Lambda
# =============================================================================
# WHY build on EC2?
#   The "sharp" image library uses native C++ binaries.
#   The binary must match the OS where it runs (Lambda = Linux x64).
#   If built on Mac, the binary is incompatible with Lambda.
#   EC2 is Amazon Linux (Linux x64) — same as Lambda — so it works perfectly.
# =============================================================================
deploy_lambda() {
  print_step "14" "Building Lambda on EC2 (ensures Linux-compatible sharp binary)..."

  # ── Copy Lambda source code to EC2 ─────────────────────────────────────────
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    ec2-user@"$EC2_IP" "mkdir -p ~/lambda-thumbnail"

  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    "$FILES_DIR/lambda-index.js" \
    ec2-user@"$EC2_IP":~/lambda-thumbnail/index.js

  # ── Install dependencies and zip on EC2 (Linux) ────────────────────────────
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    ec2-user@"$EC2_IP" << 'ENDSSH'
    set -e
    cd ~/lambda-thumbnail
    npm init -y > /dev/null
    npm install sharp @aws-sdk/client-s3 > /dev/null
    sudo dnf install -y zip > /dev/null 2>&1
    zip -r function.zip index.js node_modules/ > /dev/null
    echo "Zip size: $(du -sh function.zip | cut -f1)"
ENDSSH

  # ── Copy zip from EC2 back to local machine ─────────────────────────────────
  LAMBDA_ZIP="/tmp/cloudvault-lambda-${SUFFIX}.zip"
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
    ec2-user@"$EC2_IP":~/lambda-thumbnail/function.zip \
    "$LAMBDA_ZIP"

  print_ok "Lambda zip built and downloaded: $LAMBDA_ZIP"

  # ── Create Lambda function with retry (IAM role needs time to propagate) ────
  echo "  Creating Lambda function..."
  RETRIES=5
  for i in $(seq 1 $RETRIES); do
    LAMBDA_RESULT=$(aws lambda create-function \
      --function-name "cloudvault-thumbnail-${SUFFIX}" \
      --runtime nodejs20.x \
      --role "$LAMBDA_ROLE_ARN" \
      --handler index.handler \
      --zip-file "fileb://$LAMBDA_ZIP" \
      --timeout 30 \
      --memory-size 512 \
      --region "$REGION" \
      2>&1) && break

    if [ $i -eq $RETRIES ]; then
      print_err "Failed to create Lambda after $RETRIES attempts"
      echo "$LAMBDA_RESULT"
      exit 1
    fi

    echo "  IAM role not ready yet, retrying in 10s... ($i/$RETRIES)"
    sleep 10
  done

  LAMBDA_FUNCTION_NAME="cloudvault-thumbnail-${SUFFIX}"
  LAMBDA_ARN=$(aws lambda get-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --query "Configuration.FunctionArn" \
    --output text)

  print_ok "Lambda function created: $LAMBDA_ARN"
}

# =============================================================================
# STEP 15 — Connect S3 bucket to Lambda (event trigger)
# =============================================================================
# Two things must happen:
#   1. Lambda must give S3 PERMISSION to invoke it (resource-based policy)
#   2. S3 must be told WHEN to invoke Lambda (notification configuration)
# =============================================================================
setup_s3_trigger() {
  print_step "15" "Setting up S3 → Lambda trigger..."

  # Allow S3 to invoke the Lambda function
  aws lambda add-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id "s3-trigger-${SUFFIX}" \
    --action "lambda:InvokeFunction" \
    --principal "s3.amazonaws.com" \
    --source-arn "arn:aws:s3:::${BUCKET_NAME}" \
    > /dev/null

  # Write notification config to temp file (avoids inline JSON escaping issues)
  NOTIF_FILE=$(mktemp)
  cat > "$NOTIF_FILE" << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:Put"]
    }
  ]
}
EOF

  # Tell S3 to call Lambda on every PUT (file upload)
  aws s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration "file://$NOTIF_FILE"

  rm "$NOTIF_FILE"

  print_ok "S3 will now trigger Lambda on every file upload"
}

# =============================================================================
# STEP 16 — Save config file (used by teardown.sh to delete everything)
# =============================================================================
save_config() {
  print_step "16" "Saving infrastructure config..."

  cat > "$CONFIG_FILE" << EOF
# CloudVault infrastructure config — generated by setup.sh
# DO NOT edit manually — used by teardown.sh to delete all resources
# Created: $(date)

REGION=${REGION}
SUFFIX=${SUFFIX}
BUCKET_NAME=${BUCKET_NAME}
DB_IDENTIFIER=${DB_IDENTIFIER}
EC2_INSTANCE_ID=${EC2_INSTANCE_ID}
EC2_IP=${EC2_IP}
KEY_NAME=${KEY_NAME}
KEY_PATH=${KEY_PATH}
EC2_SG_ID=${EC2_SG_ID}
RDS_SG_ID=${RDS_SG_ID}
EC2_ROLE_NAME=${EC2_ROLE_NAME}
EC2_PROFILE_NAME=${EC2_PROFILE_NAME}
LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME}
EOF

  print_ok "Config saved: $CONFIG_FILE"
}

# =============================================================================
# Final summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║            CloudVault is fully deployed!                 ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${CYAN}Start React app:${NC}"
  echo -e "    cd $APP_DIR && npm start"
  echo ""
  echo -e "  ${CYAN}Resources created:${NC}"
  echo -e "    S3 bucket:    $BUCKET_NAME"
  echo -e "    RDS host:     $DB_HOST"
  echo -e "    EC2 IP:       $EC2_IP"
  echo -e "    Lambda:       $LAMBDA_FUNCTION_NAME"
  echo -e "    Key pair:     $KEY_PATH"
  echo ""
  echo -e "  ${CYAN}To SSH into EC2:${NC}"
  echo -e "    ssh -i $KEY_PATH ec2-user@$EC2_IP"
  echo ""
  echo -e "  ${YELLOW}To delete everything when done:${NC}"
  echo -e "    ./teardown.sh"
  echo ""
}

# =============================================================================
# MAIN — Run all steps in order
# =============================================================================
main() {
  print_banner
  check_prerequisites   # step 0  — verify tools and AWS auth
  prompt_secrets        # step 1  — ask for DB password

  create_s3_bucket      # step 2  — S3 bucket
  create_ec2_role       # step 3  — IAM role + instance profile for EC2
  create_lambda_role    # step 4  — IAM role for Lambda
  create_security_groups # step 5  — EC2 and RDS security groups
  create_rds            # step 6  — start RDS (async — we wait later)
  create_key_pair       # step 7  — EC2 SSH key
  create_ec2            # step 8  — launch EC2 + wait for running
  update_app_js         # step 9  — inject EC2 IP into React App.js
  wait_for_rds          # step 10 — block until RDS is available
  wait_for_ssh          # step 11 — block until EC2 accepts SSH
  wait_for_nodejs       # step 12 — block until Node.js is installed
  deploy_server         # step 13 — copy + start Express server
  deploy_lambda         # step 14 — build + upload Lambda function
  setup_s3_trigger      # step 15 — connect S3 → Lambda
  save_config           # step 16 — save resource IDs for teardown
  print_summary
}

main
