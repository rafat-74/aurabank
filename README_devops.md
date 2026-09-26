# ⚙️ README — DevOps & Infrastructure

> توثيق البنية التحتية لـ Aura Bank — بيئة التطوير المحلي (Docker Compose) والنشر على AWS.
>

---

## Stack التقني

| البيئة | الأداة | الدور |
|--------|--------|-------|
| **Local** | Docker 24+ | Containerization |
| **Local** | Docker Compose v2 | Orchestration |
| **Local** | Nginx alpine | Reverse proxy + static serving |
| **Local** | PostgreSQL 15-alpine | 4 قواعد بيانات مستقلة |
| **Local** | Python 3.12-slim | Runtime للـ services |
| **Cloud** | AWS ECS Fargate | تشغيل الـ containers |
| **Cloud** | AWS RDS PostgreSQL | قاعدة البيانات (schema isolation) |
| **Cloud** | AWS ALB | Load Balancer بديل Nginx |
| **Cloud** | AWS CloudFront + WAF | CDN + حماية |
| **Cloud** | Terraform 1.7+ | Infrastructure as Code |
| **CI/CD** | Jenkins | Automated deploy pipelines |
| **CI/CD** | GitHub Webhooks | Trigger على كل push لـ main |

---

## البيئة المحلية — Docker Compose

### الـ Services (11 container)

```
nginx                ← reverse proxy رئيسي :8080
frontend-customers   ← static SPA :3000
frontend-teller      ← static SPA :3001
api-gateway          ← :8000
auth-service         ← :8001  +  auth-db (PostgreSQL)
accounts-service     ← :8002  +  accounts-db (PostgreSQL)
transactions-service ← :8003  +  transactions-db (PostgreSQL)
notifications-service← :8004  +  notifications-db (PostgreSQL)
```

### الشبكة

```yaml
networks:
  aurabank-net:
    driver: bridge
```

جميع الـ containers على نفس الشبكة `aurabank-net`. التواصل بين الـ services يتم بالـ service name مباشرة:

```
http://auth-service:8001
http://accounts-service:8002
http://transactions-service:8003
http://notifications-service:8004
```

### الـ Volumes (بيانات دائمة)

```yaml
volumes:
  auth_data:           # بيانات auth-db
  accounts_data:       # بيانات accounts-db
  transactions_data:   # بيانات transactions-db
  notifications_data:  # بيانات notifications-db
```

البيانات تبقى محفوظة بعد `docker compose down`. تُحذف فقط بـ:

```bash
docker compose down -v   # حذف الـ volumes أيضاً (reset كامل)
```

---

## Health Checks

كل قاعدة بيانات لها healthcheck:

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U aurabank_admin -d auth_db"]
  interval: 5s
  timeout: 5s
  retries: 10
```

الـ services تنتظر الـ DB:

```yaml
depends_on:
  auth-db:
    condition: service_healthy
```

وكل service فيها retry loop داخلي عند الـ startup:

```python
for i in range(20):
    try:
        init_db()
        return
    except Exception as e:
        log.warning(f"DB not ready ({i+1}/20): {e}")
        time.sleep(3)
raise RuntimeError("DB failed after 20 retries")
```

---

## Nginx — الـ Reverse Proxy (Local)

**الملف:** `infrastructure/nginx/nginx.conf`

```nginx
upstream api_gateway {
    server api-gateway:8000;
}

server {
    listen 80;

    location /api/ {
        proxy_pass http://api_gateway;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

> **في الـ production على AWS:** Nginx استُبدل بـ **AWS ALB** الذي يقوم بنفس مهمة الـ routing مع إضافة SSL termination وhealth checks وauto scaling. انظر `INFRASTRUCTURE-on-AWS.md` → Section 5.

---

## قواعد البيانات — الفصل الكامل

### Local (Docker Compose)

كل service لها container PostgreSQL مستقل:

| Service | Host | DB Name | User |
|---------|------|---------|------|
| auth | `auth-db:5432` | `auth_db` | aurabank_admin |
| accounts | `accounts-db:5432` | `accounts_db` | aurabank_admin |
| transactions | `transactions-db:5432` | `transactions_db` | aurabank_admin |
| notifications | `notifications-db:5432` | `notifications_db` | aurabank_admin |

### Production (AWS RDS)

instance PostgreSQL واحدة (`aurabank-dev-rds`) بـ **4 schemas معزولة**. الـ schema init بيتعمل عن طريق **AWS Lambda function** (`aurabank-dev-db-init`) بيتشغل بعد الـ deploy مباشرةً.

**الـ Lambda بتعمل:**
1. تتصل بـ RDS بـ master credentials من Secrets Manager
2. تخلق كل schema لو مش موجودة: `CREATE SCHEMA IF NOT EXISTS`
3. تخلق user مخصص لكل schema بـ password من Secrets Manager
4. تعطي كل user صلاحيات على schema بتاعته بس

| Schema | User | Secret ARN |
|--------|------|-----------|
| `auth` | `auth_user` | `aurabank/dev/rds/auth` |
| `accounts` | `accounts_user` | `aurabank/dev/rds/accounts` |
| `transactions` | `transactions_user` | `aurabank/dev/rds/transactions` |
| `notifications` | `notifications_user` | `aurabank/dev/rds/notifications` |

**عزل الصلاحيات:**
```sql
-- كل user شايف schema بتاعته بس
GRANT USAGE ON SCHEMA auth TO auth_user;
GRANT CREATE ON SCHEMA auth TO auth_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON TABLES TO auth_user;
ALTER USER auth_user SET search_path TO auth, public;
```

انظر `INFRASTRUCTURE-on-AWS.md` → Section 8.

### init_db() — إنشاء الجداول تلقائياً

كل service تُنشئ جداولها عند أول تشغيل باستخدام `CREATE TABLE IF NOT EXISTS`. لا يوجد migration tool — النظام self-initializing.

**مبدأ أساسي:** لا توجد أي service تقرأ مباشرة من قاعدة بيانات service أخرى. كل تبادل بيانات يتم عبر HTTP API.

---

## Dockerfiles

### Backend Services

```dockerfile
FROM python:3.12-slim

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER appuser

ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
```

> **entrypoint.sh:** في الـ production، هذا الملف يقرأ credentials من AWS Secrets Manager ويبني `DATABASE_URL` قبل بدء الـ application. انظر `DEPLOY_AND_DESTROY.md` → Step 4.

### Frontend Services

```dockerfile
FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Environment Variables

### Local (docker-compose)

```env
# API Gateway
AUTH_URL=http://auth-service:8001
ACCOUNTS_URL=http://accounts-service:8002
TRANSACTIONS_URL=http://transactions-service:8003
NOTIFICATIONS_URL=http://notifications-service:8004
JWT_SECRET=change-this-in-production

# Auth Service
DATABASE_URL=postgresql://aurabank_admin:secret@auth-db:5432/auth_db
ACCOUNTS_URL=http://accounts-service:8002

# Transactions Service
DATABASE_URL=postgresql://aurabank_admin:secret@transactions-db:5432/transactions_db
ACCOUNTS_URL=http://accounts-service:8002
NOTIFICATIONS_URL=http://notifications-service:8004
SQS_QUEUE_URL=http://... (AWS only)
```

> **في الـ production على AWS:** لا توجد أي secrets في environment variables. كل الـ credentials محفوظة في **AWS Secrets Manager** ويتم حقنها وقت التشغيل عبر `entrypoint.sh`. انظر `INFRASTRUCTURE-on-AWS.md` → Section 9.

---

## تشغيل المشروع (Local)

```bash
# أول تشغيل (build كامل)
docker compose up --build

# تشغيل عادي
docker compose up -d

# إيقاف مع حفظ البيانات
docker compose down

# إيقاف مع حذف البيانات (reset كامل)
docker compose down -v

# logs
docker compose logs -f
docker compose logs -f transactions-service

# Health check شامل
curl http://localhost:8000/ready
# {"status":"ready","services":{"auth":"ok","accounts":"ok","transactions":"ok","notifications":"ok"}}
```

---

---

## الفرق بين Local وProduction

| الجانب | Local (Docker Compose) | Production (AWS) |
|--------|----------------------|-----------------|
| Routing | Nginx container | AWS ALB |
| Database | 4 containers PostgreSQL | RDS واحدة + 4 schemas |
| Secrets | `.env` file | AWS Secrets Manager |
| Scaling | يدوي | Auto Scaling تلقائي |
| SSL | لا يوجد | CloudFront + ACM |
| Monitoring | `docker compose logs` | CloudWatch Logs |
| HA | لا يوجد | Multi-AZ (prod) |

---

## Jenkins CI/CD Pipelines

## نظرة عامة

| Pipeline | الملف | الغرض | متى يشتغل |
|----------|-------|--------|-----------|
| **Full Deploy** | `Jenkinsfile.deploy` | ينشئ كل الـ infrastructure من الصفر | يدوي |
| **CI/CD** | `Jenkinsfile.cicd` | يبني ويعمل deploy للـ services اللي اتغيرت بس | تلقائي عند كل push على main |
| **Destroy** | `Jenkinsfile.destroy` | يمسح كل الـ infrastructure | يدوي مع تأكيد |

---

## المتطلبات المشتركة

### Jenkins Credentials
لازم تتعمل في Jenkins → Manage Jenkins → Credentials:

| Credential ID | النوع | المحتوى |
|--------------|-------|---------|
| `aws-creds` | AWS Credentials | AWS Access Key ID + Secret Access Key |
| `terraform-tfvars-dev` | Secret File | ملف `terraform.tfvars` بتاع الـ dev environment |

### Tools على Jenkins Server
- **Docker** — لازم يكون مثبت ومشغل
- **AWS CLI** — بيتثبت تلقائياً لو مش موجود
- **Terraform** — بيتثبت تلقائياً لو مش موجود (v1.7.5)

---

## Pipeline 1: Full Deploy (`Jenkinsfile.deploy`)

يبني كل حاجة من الصفر — infrastructure + database + Docker images + ECS services.

### Environment Variables

| المتغير | القيمة | الشرح |
|---------|--------|-------|
| `AWS_REGION` | `us-east-1` | الـ AWS region |
| `AWS_ACCOUNT_ID` | `816709079108` | رقم الـ AWS account |
| `ENV` | `dev` | اسم البيئة |
| `PROJECT` | `aurabank` | اسم المشروع، بيتستخدم في تسمية الـ resources |
| `REGISTRY` | `<account>.dkr.ecr.<region>.amazonaws.com` | عنوان الـ ECR registry |
| `TF_DIR` | `terraform/envs/dev` | مسار الـ Terraform environment |
| `CLUSTER` | `aurabank-dev-cluster` | اسم الـ ECS cluster |

### Parameters

| الـ Parameter | الـ Default | الشرح |
|--------------|------------|-------|
| `IMAGE_TAG` | `v1.0.0` | الـ tag اللي هيتحط على كل Docker image |

### Stages

#### Stage 1: Install Dependencies
بيتحقق من وجود الـ tools المطلوبة:
- **AWS CLI** — لو موجود يطبع الـ version، لو مش موجود ينزله من `awscli.amazonaws.com`
- **Terraform** — لو موجود يطبع الـ version، لو مش موجود ينزل v1.7.5
- **Docker** — لو مش موجود الـ pipeline يوقف بـ error (مش بيتنصب تلقائياً)

#### Stage 2: Checkout
بيجيب الـ code من الـ Git repo المربوط بالـ pipeline (SCM).

#### Stage 3: Bootstrap State
بيتحقق إن الـ S3 bucket الخاص بـ Terraform state موجود:
- **Bucket name:** `aurabank-terraform-state-dev`
- لو الـ bucket موجود → يكمل بدون تغيير
- لو مش موجود → بيشغل `bootstrap_state.sh` اللي بيخلق الـ bucket و DynamoDB lock table

#### Stage 4: Build Lambda
بيبني الـ Lambda zip اللي بيستخدمه الـ db-init function:
- بيشغل `terraform/modules/rds/build_lambda.sh`
- الـ script بيستخدم Docker image `public.ecr.aws/lambda/python:3.12` عشان يضمن compatibility مع Lambda runtime
- الـ output: `terraform/modules/rds/db_init_lambda.zip`

#### Stage 5: Terraform Init
بيحضّر Terraform:
- بيجيب الـ `terraform.tfvars` من Jenkins Credentials
- بيعمل `terraform init -reconfigure` عشان يربط بـ S3 backend

#### Stage 6: Import Secrets
بيتحقق من وجود الـ Secrets Manager secrets على AWS قبل الـ apply:
- لو الـ secret موجود على AWS بس مش في الـ Terraform state → بيعمله `terraform import`
- لو مش موجود → بيتعمل جديد في الـ apply
- بيتعامل مع الـ secrets دي:
  - `aurabank/dev/rds/master` — credentials الـ RDS master user
  - `aurabank/dev/rds/auth` — credentials الـ auth schema user
  - `aurabank/dev/rds/accounts` — credentials الـ accounts schema user
  - `aurabank/dev/rds/transactions` — credentials الـ transactions schema user
  - `aurabank/dev/rds/notifications` — credentials الـ notifications schema user
  - `aurabank/dev/jwt-secret` — الـ JWT signing secret

#### Stage 7: Terraform Plan
بيعمل `terraform plan` ويحفظ النتيجة في ملف `tfplan`:
- بيمرر `image_tag` كـ variable عشان Terraform يعرف انهي Docker image tag يستخدم

#### Stage 8: Terraform Apply
بيطبق الـ plan المحفوظ في `tfplan`:
- بينشئ كل الـ infrastructure: VPC, subnets, security groups, RDS, ECS cluster, ALB, ECR repos, Lambda function, إلخ

#### Stage 9: Deploy Lambda
بعد ما Terraform خلق الـ Lambda function، بيرفع عليها الـ zip الجديد:
- بيستنى الـ Lambda تبقى `Active` قبل الـ update
- بيستخدم `aws lambda update-function-code` لرفع الـ zip
- بيستنى الـ update يخلص قبل ما يكمل
- **السبب:** Terraform بيخلق الـ Lambda بـ zip قديم، وبعدين بنرفع الـ zip الجديد المبني بـ python3.12

#### Stage 10: ECR Login
بيعمل login على الـ ECR registry عشان Docker يقدر يعمل push:
- بيستخدم `aws ecr get-login-password` ويحوله لـ `docker login`

#### Stage 11: Build & Push Images
بيشغل `terraform/scripts/push_images.sh` اللي:
- يبني الـ 7 Docker images بالتوازي
- يتحقق لو الـ tag موجود في ECR قبل الـ push (عشان immutable tags)
- يعمل push للـ versioned tag
- يعمل re-tag للـ `latest` عن طريق ECR API مباشرةً (مش بـ docker push)
- **الـ 7 services:** `auth-service`, `accounts-service`, `transactions-service`, `notifications-service`, `api-gateway`, `frontend-customers`, `frontend-teller`

#### Stage 12: Init Database
بينادي على الـ Lambda function لإنشاء الـ schemas و users في RDS:
- بيستنى الـ Lambda تكون `Active`
- بيستدعي `aurabank-dev-db-init`
- بيتحقق من الـ response — لو `statusCode` مش 200 يفشل
- الـ Lambda بتنشئ 4 schemas: `auth`, `accounts`, `transactions`, `notifications`

#### Stage 13: Deploy ECS Services
بيعمل force redeploy لكل الـ ECS services عشان تبدأ تشغل الـ images الجديدة:
- `--force-new-deployment` بيخلي ECS يوقف الـ tasks القديمة ويبدأ جديدة بالـ image الجديد

#### Stage 14: Health Check
بيستنى 120 ثانية وبعدين بيتحقق من كل الـ 7 services:
- بيقارن `runningCount` بـ `desiredCount` لكل service
- لو أي service مش healthy بيفشل الـ pipeline
- بيطبع URLs الـ portals في الآخر

### Post Actions

| الحالة | الإجراء |
|--------|---------|
| دايماً | حذف `terraform.tfvars` و `tfplan` و `/tmp/db-result.json` من الـ workspace |
| نجاح | طباعة رسالة تأكيد |
| فشل | طباعة رسالة خطأ |

---

## Pipeline 2: CI/CD (`Jenkinsfile.cicd`)

بيشتغل تلقائياً عند كل push على `main`. بيكتشف الـ services اللي اتغيرت وبيعمل deploy ليها بس.

### Environment Variables

| المتغير | القيمة | الشرح |
|---------|--------|-------|
| `AWS_REGION` | `us-east-1` | الـ AWS region |
| `AWS_ACCOUNT_ID` | `816709079108` | رقم الـ AWS account |
| `ENV` | `dev` | اسم البيئة |
| `PROJECT` | `aurabank` | اسم المشروع |
| `REGISTRY` | `<account>.dkr.ecr.<region>.amazonaws.com` | عنوان الـ ECR registry |
| `CLUSTER` | `aurabank-dev-cluster` | اسم الـ ECS cluster |
| `SERVICES` | قائمة بالـ 7 services | بيتستخدم كـ reference |

### Trigger
```groovy
triggers {
    githubPush()
}
```
بيشتغل تلقائياً على كل push على `main` عن طريق GitHub Webhook.

### Dynamic Variables (بتتعمل أثناء الـ pipeline)

| المتغير | مثال | الشرح |
|---------|------|-------|
| `SERVICES_TO_BUILD` | `auth-service frontend-customers` | الـ services اللي هتتبنى |
| `IMAGE_TAG` | `build-42-a3f9d2c` | tag مكوّن من build number + commit hash |

### Stages

#### Stage 1: Install Dependencies
نفس الـ deploy pipeline — بيتحقق من AWS CLI و Docker.

#### Stage 2: Checkout
بيجيب الكود من Git ويطبع اسم الـ branch والـ commit والـ author.

#### Stage 3: Detect Changes
**أهم stage في الـ pipeline** — بيكتشف الـ services اللي اتغيرت:

- بيشغل `git diff --name-only HEAD~1 HEAD` عشان يجيب الملفات اللي اتغيرت
- لو في تغيير في `terraform/` أو أول run → يبني **كل** الـ services
- لو تغيير في `services/auth-service/` → يبني `auth-service` بس
- النتيجة بتتحفظ في `env.SERVICES_TO_BUILD`
- لو مفيش تغييرات في أي service → بيـ skip الـ build والـ deploy

**مثال:**
```
Changed files: services/auth-service/main.py
               services/frontend-customers/nginx.conf

Services to build: auth-service frontend-customers
```

#### Stage 4: Generate Tag
بيولد image tag فريد من:
- `BUILD_NUMBER` — رقم الـ build في Jenkins
- `git rev-parse --short HEAD` — أول 7 حروف من الـ commit hash

**مثال:** `build-42-a3f9d2c`

#### Stage 5: ECR Login
بيشتغل بس لو `SERVICES_TO_BUILD` مش فاضي.
بيعمل login على ECR.

#### Stage 6: Build & Push
بيشتغل بس لو `SERVICES_TO_BUILD` مش فاضي.

لكل service في القائمة:
- يبني الـ Docker image بـ `--platform linux/amd64` و `--cache-from latest` للسرعة
- يتحقق لو الـ tag موجود في ECR قبل الـ push (immutable tags protection)
- يعمل push للـ versioned tag
- يعمل re-tag للـ `latest` عن طريق:
  1. `aws ecr batch-get-image` — جلب الـ manifest
  2. `aws ecr batch-delete-image` — حذف الـ latest القديم
  3. `aws ecr put-image` — إضافة الـ latest الجديد

#### Stage 7: Update Task Definitions
بيشتغل بس لو `SERVICES_TO_BUILD` مش فاضي.

لكل service:
1. يجيب الـ task definition الحالية من ECS
2. ينشئ نسخة جديدة منها مع تغيير الـ image tag بـ Python script
3. يسجل الـ task definition الجديدة
4. يعمل update للـ ECS service للـ task definition الجديدة

**ملاحظة مهمة:** الـ Python script بيكتب تغييرات الـ image في `sys.stderr` مش `sys.stdout` عشان متتخلطش مع الـ JSON اللي بيتمرر لـ `aws ecs register-task-definition`.

#### Stage 8: Health Check
بيشتغل بس لو `SERVICES_TO_BUILD` مش فاضي.

- بيستنى 90 ثانية عشان الـ tasks تبدأ
- بيستخدم `withEnv(["SVCS=..."])` عشان يمرر `SERVICES_TO_BUILD` لـ shell script بشكل صح
- بيقارن `runningCount` بـ `desiredCount` لكل service

#### Stage 9: No Changes
بيشتغل بس لو `SERVICES_TO_BUILD` فاضي — بيطبع رسالة إن مفيش تغييرات.

### Post Actions

| الحالة | الإجراء |
|--------|---------|
| نجاح | طباعة الـ tag والـ services اللي اتبنت والـ commit |
| فشل | طباعة الـ commit واللي حصل |
| دايماً | `docker image prune -f` لتنظيف الـ images القديمة |

---

## Pipeline 3: Destroy (`Jenkinsfile.destroy`)

بيمسح **كل** الـ infrastructure بالكامل. لا رجعة بعد التأكيد.

### Environment Variables

| المتغير | القيمة | الشرح |
|---------|--------|-------|
| `AWS_REGION` | `us-east-1` | الـ AWS region |
| `AWS_ACCOUNT_ID` | `816709079108` | رقم الـ AWS account |
| `ENV` | `dev` | اسم البيئة |
| `PROJECT` | `aurabank` | اسم المشروع |
| `TF_DIR` | `terraform/envs/dev` | مسار الـ Terraform environment |
| `STATE_BUCKET` | `aurabank-terraform-state-dev` | اسم الـ S3 bucket بتاع الـ Terraform state |
| `LOCK_TABLE` | `aurabank-terraform-locks-dev` | اسم الـ DynamoDB table بتاع الـ state locking |

### Stages

#### Stage 1: Install Dependencies
نفس الـ pipelines التانية — بيتحقق من AWS CLI و Terraform.

#### Stage 2: Checkout
بيجيب الكود من Git.

#### Stage 3: Show Resources
بيعرض قائمة بكل الـ resources اللي هتتمسح قبل ما تأكد:
- **ECS Services** في `aurabank-dev-cluster`
- **ECR Repositories** اللي اسمها فيه `aurabank`
- **RDS Instances** اللي اسمها فيه `aurabank`
- **Load Balancers** اللي اسمها فيه `aurabank`

#### Stage 4: Manual Approval
**أهم safety check في الـ pipeline** — بيوقف الـ pipeline وينتظر موافقة يدوية:
- بيستنى 30 دقيقة كحد أقصى
- `submitter: 'admin'` — بس الـ admin يقدر يوافق
- لو ضغطت "نعم، امسح كل حاجة" → يكمل
- لو ضغطت "Abort" أو فضل 30 دقيقة → يوقف

#### Stage 5: Stop ECS Services
بيوقف كل الـ ECS tasks قبل الـ destroy عشان يمنع أي connections جديدة على RDS:
- بيعمل `--desired-count 0` لكل service
- بيستنى 30 ثانية للـ tasks تخلص

#### Stage 6: Clear ECR Images
بيمسح كل الـ images من الـ ECR repositories قبل الـ destroy:
- ضروري عشان Terraform مش بيقدر يمسح ECR repo فيه images
- بيتعامل مع الـ 7 repos بتاعة الـ services

#### Stage 7: Terraform Init
بيحضّر Terraform للـ destroy:
- بيجيب الـ tfvars من Credentials
- بيعمل `sudo rm -rf db_init_build` عشان يمسح الـ build artifacts اللي اتعملت بـ root من Docker — لو مش بيعمل كده الـ workspace بيفشل من الـ run الجاي
- `terraform init -reconfigure` للربط بالـ S3 backend

#### Stage 8: Terraform Destroy
بيمسح كل الـ infrastructure عن طريق Terraform:
- `#!/bin/bash` في أول الـ script ضروري عشان `if !` مش شغال في dash
- لو فشل في المرة الأولى بيحاول تاني مع `-lock=false` في حالة الـ state lock
- بيمسح كل الـ resources اللي Terraform أنشأها: VPC, subnets, RDS, Lambda, ECS, ALB, Security Groups, إلخ

#### Stage 9: Delete State Bucket
بيمسح الـ S3 bucket بتاع الـ Terraform state:
- Terraform مش بيمسح الـ backend bucket عشان ما يحصلش data loss عن طريق غلط
- بيمسح كل الـ versions والـ delete markers الأول (S3 versioning)
- وبعدين بيمسح الـ bucket نفسه

#### Stage 10: Delete Lock Table
بيمسح الـ DynamoDB table المستخدمة لـ Terraform state locking:
- `|| echo "..."` عشان لو الـ table مش موجودة ما يوقفش

#### Stage 11: Verify Destruction
بيتحقق إن الـ resources اتمسحت فعلاً:
- يتحقق من status الـ ECS cluster
- يعد الـ RDS instances المتبقية
- يعد الـ NAT Gateways المتبقية
- بيطبع تقرير نهائي

### Post Actions

| الحالة | الإجراء |
|--------|---------|
| نجاح | رسالة تأكيد الحذف |
| فشل | رسالة تحذير مع أمر يدوي لتكملة الحذف |
| دايماً | `sudo rm -rf db_init_build` + حذف الـ temp files |

---

## ملاحظات مهمة

### ECR Immutable Tags
كل الـ repos عندها immutable tags مفعّلة — يعني مش تقدر تعمل push لـ tag موجود بالفعل. الحل المستخدم:

1. **Versioned tags** (مثل `v1.0.30`): بيتحقق من وجودهم قبل الـ push، لو موجود يـ skip
2. **Latest tag**: بيتمسح ويتعمل re-tag عن طريق `aws ecr put-image` مباشرةً بدل docker push

### Lambda و Python Versions
- الـ Lambda runtime: **python3.12**
- الـ Docker image للـ build: `public.ecr.aws/lambda/python:3.12`
- مهم إنهم يتطابقوا عشان الـ `.so` files تكون compatible

### Terraform State
- **Backend:** S3 (`aurabank-terraform-state-dev`)
- **Locking:** DynamoDB (`aurabank-terraform-locks-dev`)
- الـ tfvars مش موجودة في الـ Git — بتيجي من Jenkins Credentials لحماية الـ passwords

### Frontend Services
الـ `frontend-customers` و `frontend-teller` بيستخدموا nginx. الـ nginx config بتستخدم:
```nginx
resolver 169.254.169.253 valid=10s ipv6=off;
set $upstream http://api-gateway.aurabank-dev.local:8000;
proxy_pass $upstream;
```
ده مهم عشان الـ DNS resolution يحصل وقت الـ request مش وقت الـ nginx startup — لو حصل وقت الـ startup والـ api-gateway مش شغال الـ container هيموت.
---

## AWS Infrastructure — Architecture

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

---

## Terraform Versions

```hcl
terraform  >= 1.7.0
aws        ~> 5.50
random     ~> 3.6
```