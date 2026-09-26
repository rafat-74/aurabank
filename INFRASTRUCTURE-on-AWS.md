# Aura Bank — AWS Infrastructure Documentation


> **Region:** us-east-1 (N. Virginia)  
> **Environment:** dev  
> **IaC:** Terraform 1.7+ — all resources defined in `terraform/`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Network — VPC](#2-network--vpc)
3. [Security — WAF & Security Groups](#3-security--waf--security-groups)
4. [DNS & CDN — Route53 & CloudFront](#4-dns--cdn--route53--cloudfront)
5. [Load Balancing — ALB](#5-load-balancing--alb)
6. [Compute — ECS Fargate](#6-compute--ecs-fargate)
7. [Container Registry — ECR](#7-container-registry--ecr)
8. [Database — RDS PostgreSQL](#8-database--rds-postgresql)
9. [Secrets Management](#9-secrets-management)
10. [IAM Roles & Permissions](#10-iam-roles--permissions)
11. [Observability — Logs & Alarms](#11-observability--logs--alarms)
12. [Cost Breakdown](#12-cost-breakdown)

---

## 1. Architecture Overview

### Traffic Flow

```
User (Browser / Mobile)
         │
         ▼
  Route53 (DNS)
  aurabank-eg.com  ──────────────────────────────────────────────►  CloudFront
  teller.aurabank-eg.com  ─────────────────────────────────────►  CloudFront (Teller)
         │
         ▼
  WAF (AWS WAFv2 — CLOUDFRONT scope)
  ├── Customer distribution: rate limiting + OWASP rules
  └── Teller distribution:  IP allowlist + OWASP rules
         │
         ▼
  Application Load Balancer  (aurabank-dev-alb)
  HTTPS :443  ──  HTTP :80 redirects to HTTPS
         │
         ├── /api/*    ──►  ECS: api-gateway        :8000
         ├── /teller/* ──►  ECS: frontend-teller    :80
         └── /*        ──►  ECS: frontend-customers  :80
                                    │
                              api-gateway
                                    │
                 ┌──────────────────┼──────────────────┐
                 ▼                  ▼                   ▼                  ▼
         auth-service      accounts-service   transactions-service   notifications-service
           :8001               :8002               :8003                  :8004
                 │                  │                   │                  │
                 └──────────────────┴───────────────────┴──────────────────┘
                                          │
                                          ▼
                                 RDS PostgreSQL  (aurabank-dev-rds)
                          ┌───────────┬───────────┬──────────────┬───────────────┐
                          │   auth    │ accounts  │ transactions │ notifications │
                          │  schema   │  schema   │   schema     │    schema     │
                          └───────────┴───────────┴──────────────┴───────────────┘
```

### Service Inventory

| Service | Container Port | ECS Service Name | Purpose |
|---------|---------------|-----------------|---------|
| `api-gateway` | 8000 | aurabank-dev-api-gateway | Request routing, JWT validation |
| `auth-service` | 8001 | aurabank-dev-auth-service | Login, register, JWT issuance |
| `accounts-service` | 8002 | aurabank-dev-accounts-service | Accounts, cards, loans |
| `transactions-service` | 8003 | aurabank-dev-transactions-service | Transfers, withdrawals, deposits |
| `notifications-service` | 8004 | aurabank-dev-notifications-service | In-app notifications |
| `frontend-customers` | 80 | aurabank-dev-frontend-customers | Customer web portal |
| `frontend-teller` | 80 | aurabank-dev-frontend-teller | Teller web portal (restricted) |

---

## 2. Network — VPC

**VPC Name:** `aurabank-dev-vpc`  
**CIDR:** `10.10.0.0/16`

### Subnets

| Name | AZ | CIDR | Type | Purpose |
|------|----|------|------|---------|
| aurabank-dev-public-us-east-1a | us-east-1a | 10.10.1.0/24 | Public | ALB, NAT Gateway |
| aurabank-dev-public-us-east-1b | us-east-1b | 10.10.2.0/24 | Public | ALB, NAT Gateway |
| aurabank-dev-private-us-east-1a | us-east-1a | 10.10.10.0/24 | Private | ECS tasks, RDS |
| aurabank-dev-private-us-east-1b | us-east-1b | 10.10.11.0/24 | Private | ECS tasks, RDS |

### Routing

- **Public subnets** route `0.0.0.0/0` through the Internet Gateway
- **Private subnets** route `0.0.0.0/0` through their respective NAT Gateway (one per AZ for high availability)

### NAT Gateways

Two NAT Gateways, one per AZ. Private subnet resources (ECS, Lambda) use these to reach the internet for any traffic not covered by VPC Endpoints.

**Cost:** ~$0.045/hour each = ~$65/month total

### VPC Endpoints (Traffic Stays Inside AWS)

| Endpoint | Type | Services Using It |
|----------|------|------------------|
| `com.amazonaws.us-east-1.ecr.api` | Interface | ECS pulling images |
| `com.amazonaws.us-east-1.ecr.dkr` | Interface | ECS pulling images |
| `com.amazonaws.us-east-1.secretsmanager` | Interface | ECS reading secrets |
| `com.amazonaws.us-east-1.s3` | Gateway | ECR layer storage |

These endpoints reduce NAT Gateway data transfer costs and keep traffic off the public internet.

### VPC Flow Logs

All VPC traffic is logged to CloudWatch Logs at `/aurabank/dev/vpc-flow-logs` with a 30-day retention period.

---

## 3. Security — WAF & Security Groups

### WAF (AWS WAFv2)

WAF is deployed at the CloudFront scope (must be in us-east-1 for CloudFront distributions).

#### Customer WAF (`aurabank-dev-waf-customers`)

| Rule | Priority | Action | Purpose |
|------|----------|--------|---------|
| RateLimitRule | 1 | Block | Max 1,000 requests per 5 min per IP |
| AWSManagedRulesCommonRuleSet | 2 | Count/Block | OWASP Top 10 protection |
| AWSManagedRulesKnownBadInputsRuleSet | 3 | Block | Known malicious payloads |
| AWSManagedRulesSQLiRuleSet | 4 | Block | SQL injection protection |

Default action: **Allow**

#### Teller WAF (`aurabank-dev-waf-teller`)

| Rule | Priority | Action | Purpose |
|------|----------|--------|---------|
| AllowTellerIPs | 1 | Allow | Whitelist: `197.121.133.107/32` |
| TellerRateLimit | 2 | Block | Max 200 requests per 5 min per IP |
| AWSManagedRulesCommonRuleSet | 3 | Block | OWASP Top 10 protection |

Default action: **Block** — any IP not in the allowlist is blocked before reaching the application.

### Security Groups

#### `aurabank-dev-sg-alb`
| Direction | Port | Source | Purpose |
|-----------|------|--------|---------|
| Inbound | 443 | 0.0.0.0/0 | HTTPS from internet (filtered by WAF) |
| Inbound | 80 | 0.0.0.0/0 | HTTP (redirected to HTTPS) |
| Outbound | All | 0.0.0.0/0 | Responses to ECS |

#### `aurabank-dev-sg-ecs`
| Direction | Port | Source | Purpose |
|-----------|------|--------|---------|
| Inbound | 8000 | ALB SG | API Gateway traffic |
| Inbound | 80 | ALB SG | Frontend traffic |
| Inbound | 8001–8004 | Self | Inter-service communication |
| Outbound | All | 0.0.0.0/0 | AWS APIs, ECR, NAT Gateway |

#### `aurabank-dev-sg-rds`
| Direction | Port | Source | Purpose |
|-----------|------|--------|---------|
| Inbound | 5432 | ECS SG | PostgreSQL from services |
| Inbound | 5432 | Lambda SG | PostgreSQL from DB init Lambda |
| Outbound | All | VPC CIDR | Responses within VPC |

#### `aurabank-dev-sg-lambda-db-init`
| Direction | Port | Source | Purpose |
|-----------|------|--------|---------|
| Outbound | 5432 | VPC CIDR | Connect to RDS |
| Outbound | 443 | VPC CIDR | Secrets Manager via VPC Endpoint |

---

## 4. DNS & CDN — Route53 & CloudFront

### Route53

**Hosted Zone:** `aurabank-eg.com` (Zone ID: Z04027843DPV86TD0FCMO)

| Record | Type | Target |
|--------|------|--------|
| `aurabank-eg.com` | A (Alias) | CloudFront distribution (customers) |
| `teller.aurabank-eg.com` | A (Alias) | CloudFront distribution (teller) |

### CloudFront Distributions

#### Customer Distribution (`aurabank-dev-cf-customers`)
- **Aliases:** `aurabank-eg.com`
- **WAF:** Customer WAF ACL
- **SSL:** TLSv1.2_2021 minimum
- **Price Class:** PriceClass_100 (US, Canada, Europe)
- **Geo Restriction:** None (worldwide)
- **Cache Behaviors:**

| Path | Cache | Methods | Notes |
|------|-------|---------|-------|
| `/api/*` | Disabled | All | Dynamic API calls |
| `/*` | 1 hour default | GET, HEAD | Static SPA assets |

- **SPA Fallback:** 404 and 403 errors return `index.html` (React Router support)
- **Custom Header:** `X-CloudFront-Secret` sent to ALB to prevent direct ALB access

#### Teller Distribution (`aurabank-dev-cf-teller`)
- **Aliases:** `teller.aurabank-eg.com`
- **WAF:** Teller WAF ACL (IP-restricted)
- **Geo Restriction:** Egypt (EG) only
- **Cache:** 5-minute default (shorter for security-sensitive tool)

---

## 5. Load Balancing — ALB

**Name:** `aurabank-dev-alb`  
**Type:** Application Load Balancer  
**Scheme:** Internet-facing  
**Subnets:** Both public subnets (us-east-1a, us-east-1b)

### Listeners

| Port | Protocol | Action |
|------|----------|--------|
| 80 | HTTP | Redirect to HTTPS (301) |
| 443 | HTTPS | Forward (see rules below) |

**TLS Policy:** `ELBSecurityPolicy-TLS13-1-2-2021-06`

### Listener Rules (HTTPS :443)

| Priority | Condition | Target Group |
|----------|-----------|-------------|
| 10 | Path: `/api/*`, `/health` | `aurabank-dev-tg-api` |
| 20 | Path: `/teller/*` | `aurabank-dev-tg-teller` |
| Default | All other paths | `aurabank-dev-tg-customers` |

### Target Groups

| Name | Port | Protocol | Health Check Path | Target Type |
|------|------|----------|-----------------|-------------|
| `aurabank-dev-tg-api` | 8000 | HTTP | `/health` | IP (Fargate) |
| `aurabank-dev-tg-teller` | 80 | HTTP | `/` | IP (Fargate) |
| `aurabank-dev-tg-customers` | 80 | HTTP | `/` | IP (Fargate) |

**Access Logs:** Stored in S3 bucket `aurabank-dev-alb-logs-816709079108`, retained 14 days (dev).

---

## 6. Compute — ECS Fargate

**Cluster:** `aurabank-dev-cluster`  
**Container Insights:** Enabled  
**Capacity Providers:** FARGATE_SPOT (dev) / FARGATE (prod)

### Service Configuration

| Service | CPU | Memory | Replicas | Capacity |
|---------|-----|--------|----------|---------|
| api-gateway | 512 | 1024 MB | 1 | FARGATE_SPOT |
| auth-service | 256 | 512 MB | 1 | FARGATE_SPOT |
| accounts-service | 256 | 512 MB | 1 | FARGATE_SPOT |
| transactions-service | 256 | 512 MB | 1 | FARGATE_SPOT |
| notifications-service | 256 | 512 MB | 1 | FARGATE_SPOT |
| frontend-customers | 256 | 512 MB | 1 | FARGATE_SPOT |
| frontend-teller | 256 | 512 MB | 1 | FARGATE_SPOT |

### Service Discovery

**Namespace:** `aurabank-dev.local` (private DNS within VPC)

Services communicate via internal DNS:
```
auth-service.aurabank-dev.local:8001
accounts-service.aurabank-dev.local:8002
transactions-service.aurabank-dev.local:8003
notifications-service.aurabank-dev.local:8004
api-gateway.aurabank-dev.local:8000
```

### Auto Scaling

The `api-gateway` service has auto scaling configured:
- **Min:** 1 task
- **Max:** 2 tasks (dev) / 10 tasks (prod)
- **Trigger:** CPU utilization > 70% (average)
- **Scale-out cooldown:** 60 seconds
- **Scale-in cooldown:** 300 seconds

### Deployment Safety

All services have **Circuit Breaker** enabled with automatic rollback. If a new deployment fails health checks, ECS automatically rolls back to the previous task definition revision.

### Environment Variables Injected at Runtime

| Variable | Source | Used By |
|----------|--------|---------|
| `DATABASE_URL` | Built by `entrypoint.sh` from Secrets Manager | All backend services |
| `JWT_SECRET` | Secrets Manager (`aurabank/dev/jwt-secret`) | auth-service, api-gateway |
| `DB_HOST` | Terraform output (RDS address) | All backend services |
| `ALLOWED_ORIGINS` | Terraform variable (domain names) | All backend services |
| `AUTH_URL`, `ACCOUNTS_URL`, etc. | Service Discovery DNS | api-gateway |

---

## 7. Container Registry — ECR

**7 repositories**, all under the naming convention `aurabank/dev/<service-name>`.

### Repository Settings

| Setting | Value |
|---------|-------|
| Image tag mutability | IMMUTABLE (prevents overwriting tags) |
| Image scanning | On push (vulnerability scanning) |
| Encryption | KMS (`alias/aurabank-dev`) |

### Lifecycle Policies (per repository)

| Rule | Action |
|------|--------|
| Untagged images older than 1 day | Expire |
| Tagged images beyond latest 5 (dev) / 20 (prod) | Expire |

Tags that trigger retention: `v*`, `release*`, `sha*`

---

## 8. Database — RDS PostgreSQL

**Identifier:** `aurabank-dev-rds`  
**Engine:** PostgreSQL 15.7  
**Instance class:** `db.t3.micro` (dev)  
**Storage:** 20 GB gp3, auto-scaling up to 50 GB  
**Encryption:** KMS (`alias/aurabank-dev`)  
**Multi-AZ:** Disabled (dev) / Enabled (prod)

### Schema Isolation Architecture

A single RDS instance hosts 4 isolated schemas. Each microservice connects with a dedicated database user that has permissions only on its own schema.

| Schema | DB User | Service | Secret ARN |
|--------|---------|---------|-----------|
| `auth` | `auth_user` | auth-service | `aurabank/dev/rds/auth` |
| `accounts` | `accounts_user` | accounts-service | `aurabank/dev/rds/accounts` |
| `transactions` | `transactions_user` | transactions-service | `aurabank/dev/rds/transactions` |
| `notifications` | `notifications_user` | notifications-service | `aurabank/dev/rds/notifications` |

Schema isolation is enforced at the PostgreSQL level:
- Each user can only `SELECT`, `INSERT`, `UPDATE`, `DELETE` within their own schema
- `search_path` is set per user so table names resolve automatically (e.g., `SELECT * FROM accounts` resolves to `accounts.accounts`)
- The schemas are created by the **DB Init Lambda** on first deployment

### Backup & Maintenance

| Setting | Dev | Prod |
|---------|-----|------|
| Backup retention | 3 days | 14 days |
| Backup window | 03:00–04:00 UTC | 03:00–04:00 UTC |
| Maintenance window | Mon 04:00–05:00 UTC | Mon 04:00–05:00 UTC |
| Deletion protection | Disabled | Enabled |
| Skip final snapshot | Yes | No |

### Monitoring

- **Enhanced Monitoring:** 60-second granularity, published to CloudWatch
- **Performance Insights:** Enabled, 7-day retention (dev) / 731-day (prod)
- **CloudWatch Alarms:**
  - CPU > 80% for 2 consecutive 5-minute periods → alarm
  - Free storage < 5 GB → alarm

---

## 9. Secrets Management

All credentials are stored in **AWS Secrets Manager**. No secrets exist in environment variables, code, or configuration files.

| Secret Name | Contents | Consumers |
|-------------|----------|-----------|
| `aurabank/dev/rds/master` | `{username, password}` | Lambda DB Init |
| `aurabank/dev/rds/auth` | `{username, password, dbname, schema}` | auth-service (via ECS) |
| `aurabank/dev/rds/accounts` | `{username, password, dbname, schema}` | accounts-service (via ECS) |
| `aurabank/dev/rds/transactions` | `{username, password, dbname, schema}` | transactions-service (via ECS) |
| `aurabank/dev/rds/notifications` | `{username, password, dbname, schema}` | notifications-service (via ECS) |
| `aurabank/dev/jwt-secret` | `{jwt_secret}` | auth-service, api-gateway (via ECS) |

### How Secrets Reach Containers

1. ECS Task Execution Role has `secretsmanager:GetSecretValue` permission
2. ECS injects the secret value as an environment variable (`DB_SECRET_JSON`, `JWT_SECRET_JSON`)
3. The `entrypoint.sh` script parses the JSON and constructs `DATABASE_URL` and `JWT_SECRET` before starting the application

```
ECS Task Definition
  └── secrets:
        DB_SECRET_JSON  ← Secrets Manager ARN
        JWT_SECRET_JSON ← Secrets Manager ARN
              │
              ▼
       entrypoint.sh (runs before uvicorn)
              │
              ├── parses DB_SECRET_JSON
              ├── builds: DATABASE_URL=postgresql://user:pass@host/db?search_path=schema
              ├── parses JWT_SECRET_JSON
              └── exports: JWT_SECRET=...
                        │
                        ▼
                  uvicorn main:app (your Python code)
                  reads DATABASE_URL and JWT_SECRET as plain env vars
```

**Recovery Window:** 7 days (dev) — secrets are not immediately deleted, protecting against accidental destruction.

---

## 10. IAM Roles & Permissions

### Role: `aurabank-dev-ecs-task-execution`

**Assumed by:** ECS service (before container starts)  
**Purpose:** Allows ECS to pull images and inject secrets

| Permission | Resource | Reason |
|-----------|----------|--------|
| `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage` | ECR repos | Pull Docker images |
| `logs:CreateLogStream`, `logs:PutLogEvents` | CloudWatch | Write container logs |
| `secretsmanager:GetSecretValue` | All 6 secrets | Inject credentials into containers |
| `kms:Decrypt` | KMS key | Decrypt encrypted secrets |

### Role: `aurabank-dev-ecs-task-role`

**Assumed by:** Application code running inside containers  
**Purpose:** Runtime AWS API access from within the application

Currently empty — add policies here when services need to call AWS APIs (e.g., SQS, S3, SNS).

### Role: `aurabank-dev-lambda-db-init-role`

**Assumed by:** `aurabank-dev-db-init` Lambda function  
**Purpose:** Database schema initialization

| Permission | Resource | Reason |
|-----------|----------|--------|
| `secretsmanager:GetSecretValue` | Master + 4 schema secrets | Read DB credentials |
| `logs:CreateLogStream`, `logs:PutLogEvents` | CloudWatch | Write Lambda execution logs |
| `ec2:CreateNetworkInterface`, `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface` | All | Required for VPC-attached Lambda |

### Role: `aurabank-dev-rds-monitoring-role`

**Assumed by:** AWS RDS Enhanced Monitoring service  
**Purpose:** Publish OS-level metrics every 60 seconds

Managed policy attached: `AmazonRDSEnhancedMonitoringRole`

### Role: `aurabank-dev-vpc-flow-log-role`

**Assumed by:** VPC Flow Logs service  
**Purpose:** Write network flow records to CloudWatch

| Permission | Resource | Reason |
|-----------|----------|--------|
| `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`, `logs:DescribeLogStreams` | All | Write flow logs |

---

## 11. Observability — Logs & Alarms

### CloudWatch Log Groups

| Log Group | Retention | Source |
|-----------|-----------|--------|
| `/aurabank/dev/api-gateway` | 14 days | ECS container stdout |
| `/aurabank/dev/auth-service` | 14 days | ECS container stdout |
| `/aurabank/dev/accounts-service` | 14 days | ECS container stdout |
| `/aurabank/dev/transactions-service` | 14 days | ECS container stdout |
| `/aurabank/dev/notifications-service` | 14 days | ECS container stdout |
| `/aurabank/dev/frontend-customers` | 14 days | ECS container stdout |
| `/aurabank/dev/frontend-teller` | 14 days | ECS container stdout |
| `/aurabank/dev/vpc-flow-logs` | 30 days | VPC Flow Logs |
| `aws-waf-logs-aurabank-dev-customers` | 30 days | WAF (Customer) |
| `aws-waf-logs-aurabank-dev-teller` | 30 days | WAF (Teller) |

### CloudWatch Alarms

| Alarm | Threshold | Action |
|-------|-----------|--------|
| `aurabank-dev-rds-cpu-high` | CPU > 80% for 10 min | Alert |
| `aurabank-dev-rds-storage-low` | Free storage < 5 GB | Alert |

### Access Logs (S3)

| Bucket | Contents | Retention |
|--------|----------|-----------|
| `aurabank-dev-alb-logs-816709079108` | ALB request logs | 14 days |
| `aurabank-dev-cf-logs-816709079108` | CloudFront access logs | 30 days |

---

## 12. Cost Breakdown

Estimated monthly cost for the **dev** environment.

| Service | Configuration | Est. Cost/Month |
|---------|--------------|----------------|
| ECS Fargate SPOT | 7 containers × 256–512 CPU | ~$15–25 |
| RDS db.t3.micro | Single-AZ, 20 GB gp3 | ~$15 |
| ALB | Application Load Balancer | ~$18 |
| NAT Gateway | 2× NAT GW + data transfer | ~$65 |
| CloudFront | First 1 TB free | ~$0–5 |
| VPC Endpoints | 4 endpoints × Interface | ~$28 |
| Secrets Manager | 6 secrets | ~$3 |
| ECR | 7 repositories | ~$2 |
| CloudWatch | Logs + metrics | ~$3 |
| WAF | 2 ACLs × $5 | ~$10 |
| SQS | First 1M requests free | ~$0–1 |
| SNS SMS | ~$0.02/SMS × volume | ~$10–20 |
| SES Email | First 62K emails/month free | ~$0–2 |
| **Total** | | **~$175–200/month** |

> Actual costs depend on traffic volume and data transfer. WAF rule charges apply per million requests processed.

### Cost Optimization Tips

- In dev, use a single AZ (one NAT Gateway) to save ~$32/month
- FARGATE_SPOT is already enabled in dev (up to 70% cheaper than on-demand)
- VPC Endpoints reduce NAT Gateway data transfer charges
- ECR lifecycle policies automatically delete old images

---

## 13. Notifications — SQS + SNS + Email

### Overview

Every financial transaction (deposit, withdrawal, transfer, bill payment, currency exchange) triggers a notification delivered through two channels simultaneously:

- **SMS** — sent to the customer's registered mobile number via AWS SNS
- **Email** — sent to the customer's registered email via AWS SES
- **In-app** — saved to the `notifications` schema in RDS and displayed in the customer portal notification tab

### Architecture

```
transactions-service
        │
        ├── saves transaction to PostgreSQL
        │
        ▼
SQS Queue (aurabank-dev-notifications)
        │
        ▼
notifications-service (background worker)
        │
        ├── saves to PostgreSQL notifications schema (in-app tab)
        ├── AWS SNS ──► SMS to customer mobile
        └── AWS SES ──► Email to customer inbox
```

### AWS Resources

| Resource | Name | Purpose |
|----------|------|---------|
| SQS Queue | `aurabank-dev-notifications` | Main queue for notification messages |
| SQS Dead Letter Queue | `aurabank-dev-notifications-dlq` | Failed messages, retained 14 days |
| SNS Topic | `aurabank-dev-sms` | SMS delivery channel |
| IAM Policy | `aurabank-dev-messaging-policy` | Allows ECS tasks to use SQS + SNS + SES |

### SQS Queue Configuration

| Setting | Value | Reason |
|---------|-------|--------|
| Message retention | 24 hours | Short-lived transactional messages |
| Visibility timeout | 30 seconds | Processing window per message |
| Max receive count | 3 | Retry attempts before DLQ |
| DLQ retention | 14 days | Investigation window for failures |
| Polling type | Long polling (20s) | Reduces cost vs short polling |

### Message Format (SQS)

```json
{
  "user_id":  "uuid",
  "title":    "💵 إيداع ناجح",
  "body":     "تم إيداع 500.00 EGP في حسابك. الرصيد: 1500.00 EGP",
  "type":     "transaction",
  "phone":    "01012345678",
  "email":    "customer@example.com"
}
```

### Triggered Notifications

| Operation | Message Template |
|-----------|-----------------|
| Deposit | `💵 إيداع ناجح — تم إيداع X EGP. الرصيد: Y EGP` |
| Withdrawal | `💸 سحب ناجح — تم سحب X EGP. الرصيد: Y EGP` |
| Incoming transfer | `💰 تحويل مالي وارد — استلمت X EGP` |
| Bill payment | `🧾 دفع فاتورة X — تم دفع Y EGP. الرصيد: Z EGP` |
| Currency exchange | `💱 صرف عملة ناجح — تم صرف X EGP إلى Y USD` |

### Phone Number Normalization

Egyptian numbers are normalized to E.164 format automatically before sending to SNS:

```
01012345678    →  +201012345678
+201012345678  →  +201012345678  (unchanged)
```

### Reliability Features

| Feature | Implementation |
|---------|---------------|
| Retry | Failed messages retry 3× automatically before going to DLQ |
| Fallback | If SQS publish fails, notification is sent via direct HTTP to notifications-service |
| Idempotency | Message is deleted from queue only after successful processing |
| Long polling | Worker waits 20s per poll cycle — more efficient than constant polling |

### Terraform Module

```
terraform/modules/messaging/
├── main.tf       # SQS queue, DLQ, SNS topic, IAM policy
├── variables.tf  # project, env, tags
└── outputs.tf    # queue_url, topic_arn, policy_arn
```

The module is called from `terraform/envs/dev/main.tf` and its outputs are passed as environment variables into the ECS task definitions for `transactions-service` and `notifications-service`.

### Environment Variables (ECS)

**transactions-service:**

| Variable | Value |
|----------|-------|
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/816709079108/aurabank-dev-notifications` |

**notifications-service:**

| Variable | Value |
|----------|-------|
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/816709079108/aurabank-dev-notifications` |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:816709079108:aurabank-dev-sms` |

---

### ⚠️ Sandbox Limitations (Action Required)

Both AWS SNS SMS and AWS SES are currently in **sandbox mode**. This means:

#### SMS (AWS SNS Sandbox)

- SMS messages can only be sent to phone numbers that have been **manually verified** in the AWS console
- To send to any Egyptian number without verification, production access must be requested

**To request production access:**
```
AWS Console → SNS → Text messaging (SMS)
→ Request production access
→ Fill in: use case description, estimated monthly volume, company name
→ Submit → AWS typically approves within 24–48 hours
```

**To verify a number for testing in sandbox:**
```
AWS Console → SNS → Text messaging (SMS) → Sandbox destination phone numbers
→ Add phone number → Enter OTP sent to that number
```

#### Email (AWS SES Sandbox)

- Emails can only be sent **to and from** verified email addresses or domains
- To send to any customer email, the SES account must be moved out of sandbox

**To verify a single email for testing:**
```
AWS Console → SES → Verified identities → Create identity
→ Email address → Enter email → Verify via link sent to inbox
```

**To request production access (send to any email):**
```
AWS Console → SES → Account dashboard → Request production access
→ Fill in: mail type (Transactional), website URL, use case description
→ Submit → AWS reviews within 24 hours
```

**To verify your sending domain (recommended over individual emails):**
```
AWS Console → SES → Verified identities → Create identity
→ Domain → aurabank-eg.com
→ Add the DNS records shown to Route53
→ Domain becomes verified automatically
```

**Recommended sender address once domain is verified:**
```
From: Aura Bank <noreply@aurabank-eg.com>
```

---

### Testing Notifications

```bash
# Verify SQS queues exist
aws sqs list-queues --region us-east-1

# Check number of messages in queue
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/816709079108/aurabank-dev-notifications \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1

# Trigger a deposit (watch for SMS + email)
curl -s -X POST https://aurabank-eg.com/api/transactions/deposit \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"accountId":"<id>","amount":100,"tellerName":"Test Teller"}'

# Follow notifications-service logs
aws logs tail /aurabank/dev/notifications-service --follow --region us-east-1

# Check DLQ for any failed messages
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/816709079108/aurabank-dev-notifications-dlq \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1
```

---

*Documentation generated from Terraform source in `terraform/` — last updated April 2026*
