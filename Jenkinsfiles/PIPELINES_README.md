# AuraBank — Jenkins Pipelines Documentation

دليل شامل للـ 3 pipelines الخاصة بـ AuraBank Microservices System.

---

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
