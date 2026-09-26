# AuraBank AWS Infrastructure — Terraform

## Architecture Overview

```
Internet
    │
    ▼
CloudFront (2 distributions)
├── customers.aurabank.com  →  WAF (public + rate limit + OWASP)
└── teller.aurabank.com     →  WAF (IP allowlist + OWASP)
    │
    ▼
Application Load Balancer (HTTPS only)
├── /api/*      →  ECS: api-gateway (port 8000)
├── /teller/*   →  ECS: frontend-teller (port 80)
└── /*          →  ECS: frontend-customers (port 80)
    │
    ├── ECS Fargate (private subnets, Service Discovery)
    │   ├── api-gateway           :8000
    │   ├── auth-service          :8001
    │   ├── accounts-service      :8002
    │   ├── transactions-service  :8003
    │   └── notifications-service :8004
    │
    └── RDS PostgreSQL (private subnets, Multi-AZ in prod)
        ├── schema: auth          (user: auth_user)
        ├── schema: accounts      (user: accounts_user)
        ├── schema: transactions  (user: transactions_user)
        └── schema: notifications (user: notifications_user)
```

## Directory Structure

```
terraform/
├── modules/
│   ├── vpc/             VPC, subnets, NAT GWs, Flow Logs
│   ├── security-groups/ ALB/ECS/RDS SGs, VPC Endpoints
│   ├── secrets/         Secrets Manager (DB creds, JWT)
│   ├── rds/             PostgreSQL + schema init Lambda
│   ├── ecr/             Container registries (7 repos)
│   ├── alb/             Application Load Balancer
│   ├── ecs/             Fargate cluster + 7 services
│   ├── waf/             WAFv2 (customers + teller)
│   └── cloudfront/      2 CloudFront distributions
│
├── envs/
│   ├── dev/             Dev deployment (small instances, SPOT)
│   └── prod/            Prod deployment (HA, Multi-AZ, on-demand)
│
└── scripts/
    ├── bootstrap_state.sh   Create S3+DynamoDB for remote state
    ├── push_images.sh       Build & push Docker images to ECR
    └── entrypoint.sh        Container entrypoint (secrets → env vars)
```

---

## Step-by-Step Deployment

### Prerequisites

```bash
# Install required tools
brew install terraform awscli docker

# Verify
terraform version   # >= 1.7.0
aws --version
docker --version

# Configure AWS credentials
aws configure
# OR use AWS SSO / environment variables
```

### Step 1 — Bootstrap Remote State (run once per env)

```bash
chmod +x scripts/bootstrap_state.sh

# For dev
./scripts/bootstrap_state.sh dev eu-west-1

# For prod
./scripts/bootstrap_state.sh prod eu-west-1
```

This creates:
- S3 bucket `aurabank-terraform-state-<env>` (versioned, encrypted, private)
- DynamoDB table `aurabank-terraform-locks-<env>` (for state locking)

### Step 2 — Build the DB Init Lambda

```bash
cd modules/rds
chmod +x build_lambda.sh
./build_lambda.sh
# Creates: modules/rds/db_init_lambda.zip
cd ../..
```

### Step 3 — Fill in Your Values

Edit `envs/dev/terraform.tfvars`:

```hcl
# Your domain (must exist in Route53)
hosted_zone_name  = "aurabank.yourdomain.com"
customer_domain   = "app-dev.aurabank.yourdomain.com"
teller_domain     = "teller-dev.aurabank.yourdomain.com"

# ACM certificates (must be validated)
# One in your main region (for ALB)
acm_certificate_arn = "arn:aws:acm:eu-west-1:ACCOUNT:certificate/CERT_ID"
# One in us-east-1 (for CloudFront) — even if your region is different
acm_certificate_arn_us_east_1 = "arn:aws:acm:us-east-1:ACCOUNT:certificate/CERT_ID"

# Your office IP(s) that can access the teller portal
teller_allowed_ips = ["YOUR.OFFICE.IP.ADDRESS/32"]

# ALB account ID for your region:
# eu-west-1:    156460612806
# us-east-1:    127311923021
# eu-central-1: 054676820928
alb_account_id = "156460612806"
```

### Step 4 — Initialize and Deploy

```bash
cd envs/dev

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Terraform will create ~80 resources. Estimated time: 15-20 minutes (RDS takes longest).

### Step 5 — Build & Push Docker Images

```bash
# From project root
cd ../../  # back to AuraBank directory

# Get your ECR URLs from terraform output
terraform -chdir=terraform/envs/dev output ecr_repositories

# Build and push all 7 images
chmod +x terraform/scripts/push_images.sh
./terraform/scripts/push_images.sh dev eu-west-1 YOUR_ACCOUNT_ID v1.0.0
```

### Step 6 — Update Dockerfiles to Use Entrypoint

Copy the entrypoint script to each service:

```bash
cp terraform/scripts/entrypoint.sh services/auth-service/
cp terraform/scripts/entrypoint.sh services/accounts-service/
# ... repeat for all services
```

Add to each backend Dockerfile:
```dockerfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
```

### Step 7 — Initialize Database Schemas

```bash
aws lambda invoke \
  --function-name aurabank-dev-db-init \
  --region eu-west-1 \
  /tmp/db-init-output.json

cat /tmp/db-init-output.json
# Should show: {"statusCode": 200, "body": "DB init complete"}
```

### Step 8 — Deploy Updated Images

```bash
# Push with specific tag
./terraform/scripts/push_images.sh dev eu-west-1 YOUR_ACCOUNT_ID v1.0.0

# Update ECS services to use new tag
cd terraform/envs/dev
terraform apply -var="image_tag=v1.0.0" -var-file=terraform.tfvars
```

---

## Key Security Decisions

| Concern | Solution |
|---------|----------|
| No secrets in code | All credentials in AWS Secrets Manager, injected at runtime |
| Teller access | WAF IP allowlist + CloudFront geo-restriction (Egypt only) |
| Database isolation | Separate PostgreSQL schemas + dedicated DB users per service |
| No direct DB access | RDS in private subnet, no public IP, SG allows ECS only |
| Traffic integrity | CloudFront → ALB uses secret header, blocks direct ALB hits |
| Encryption at rest | KMS encrypts RDS, ECR, Secrets Manager |
| Encryption in transit | TLS 1.2+ enforced at CloudFront and ALB |
| Container security | ECR image scanning on push |
| State security | Remote state in S3 (encrypted) + DynamoDB locking |

---

## Operational Commands

```bash
# View logs for a service
aws logs tail /aurabank/dev/api-gateway --follow
aws logs tail /aurabank/dev/auth-service --follow

# Force ECS service redeploy (after pushing new image)
aws ecs update-service \
  --cluster aurabank-dev-cluster \
  --service aurabank-dev-api-gateway \
  --force-new-deployment \
  --region eu-west-1

# Redeploy ALL services at once
for svc in auth-service accounts-service transactions-service notifications-service api-gateway frontend-customers frontend-teller; do
  aws ecs update-service \
    --cluster aurabank-dev-cluster \
    --service "aurabank-dev-${svc}" \
    --force-new-deployment \
    --region eu-west-1 \
    --query 'service.serviceName' \
    --output text
done

# Check service health
aws ecs describe-services \
  --cluster aurabank-dev-cluster \
  --services aurabank-dev-api-gateway \
  --region eu-west-1 \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'

# View RDS performance insights
aws pi get-resource-metrics \
  --service-type RDS \
  --identifier db:aurabank-dev-rds \
  --metric-queries '[{"Metric":"db.load.avg"}]' \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period-in-seconds 300

# Update teller allowed IPs without full apply
terraform apply \
  -var="teller_allowed_ips=[\"NEW.IP.ADDRESS/32\"]" \
  -var-file=terraform.tfvars \
  -target=module.waf.aws_wafv2_ip_set.teller_allowed
```

---

## Environment Differences

| Setting | Dev | Prod |
|---------|-----|------|
| RDS Instance | db.t3.micro | db.t3.medium |
| RDS Multi-AZ | No | Yes |
| RDS Backup | 3 days | 14 days |
| RDS Deletion Protection | No | Yes |
| ECS Capacity | FARGATE_SPOT | FARGATE |
| ECS Replicas | 1 | 2 |
| AZs | 2 | 3 |
| CloudFront Price Class | PriceClass_100 | PriceClass_All |
| Log Retention | 14 days | 90 days |

---

## Terraform Versions

```hcl
terraform  >= 1.7.0
aws        ~> 5.50
random     ~> 3.6
```
