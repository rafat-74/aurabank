<div align="center">

# 🏦 Aura Bank — البنك الرقمي المتكامل

<img src="https://img.shields.io/badge/Architecture-Microservices-0A0F1E?style=for-the-badge&logo=docker&logoColor=C9A84C"/>
<img src="https://img.shields.io/badge/Backend-FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white"/>
<img src="https://img.shields.io/badge/Database-PostgreSQL-336791?style=for-the-badge&logo=postgresql&logoColor=white"/>
<img src="https://img.shields.io/badge/Cloud-AWS-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white"/>
<img src="https://img.shields.io/badge/IaC-Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white"/>
<img src="https://img.shields.io/badge/Auth-JWT-000000?style=for-the-badge&logo=jsonwebtokens&logoColor=white"/>
<img src="https://img.shields.io/badge/Frontend-HTML%2FCSS%2FJS-F7DF1E?style=for-the-badge&logo=javascript&logoColor=black"/>
<img src="https://img.shields.io/badge/CI%2FCD-Jenkins-D24939?style=for-the-badge&logo=jenkins&logoColor=white"/>

<br/><br/>

> **نظام بنكي رقمي متكامل مبني بمعمارية Microservices حديثة — يشمل بوابة API Gateway، خدمات مستقلة، قواعد بيانات معزولة (Database-per-Service)، لوحة تحكم للعملاء ولوحة عمليات للموظفين والخزينة (Teller)، جاهز للنشر المحلي بـ Docker وللسحابة على AWS ECS Fargate عبر Terraform و Jenkins.**

</div>

---

## ما هو Aura Bank؟

**Aura Bank** نظام بنكي رقمي متكامل يجسّد مفهوم **Microservices Architecture** بأفضل الممارسات البرمجية والتشغيلية (Production-Grade). كل خدمة تعمل في Container مستقل، تعتمد على Schema مخصصة ومستخدم معزول داخل PostgreSQL، وتتواصل الخدمات مع بعضها عبر شبكة داخلية آمنة.

يدعم المشروع بيئتين أساسيتين:
1. **Local Development:** تشغيل جميع الخدمات والواجهات بأمر واحد عبر `docker compose up --build`.
2. **Cloud Production (AWS):** بنية تحتية برمجية بالكامل (IaC) عبر Terraform تشمل VPC، ECS Fargate، ALB، RDS Multi-AZ، CloudFront، WAF، SQS، SES، و 3 Jenkins Pipelines للأتمتة الكاملة.

---

## التقنيات المستخدمة

| الطبقة | التقنيات |
|--------|---------|
| **Backend** | Python 3.12 · FastAPI · psycopg2 (Threaded Pool) · httpx · python-jose · bcrypt |
| **Database** | PostgreSQL 15 — تصميم Database-per-Service مع 4 Schemas ومستخدمين معزولين |
| **Frontend** | HTML5 · Modern CSS3 (Dark/Luxury theme) · Vanilla JavaScript (SPA) |
| **Infrastructure (Local)** | Docker · Docker Compose · Nginx (Static Serving & Reverse Proxy) |
| **Infrastructure (Cloud)** | AWS ECS Fargate · RDS · ALB · CloudFront · WAFv2 · Route53 |
| **IaC** | Terraform 1.7+ — Remote State على S3 مع State Locking عبر DynamoDB |
| **CI/CD** | Jenkins · GitHub Webhooks — 3 خطوط أنابيب (Deploy · CI/CD Delta · Destroy) |
| **Notifications & Queue** | AWS SQS · AWS SNS (SMS) · AWS SES (Email) |
| **Security & RBAC** | JWT HS256 · bcrypt · Rate Limiting · RBAC (Customer, Teller, Supervisor, Admin) · AWS WAF |

---

## معمارية النظام (System Architecture)

### 1. البيئة المحلية (Local Docker Compose)

```
                        ┌────────────────────────────────────┐
                        │        CLIENT BROWSER              │
                        │  frontend-customers   frontend-teller│
                        │       :8080                :8081    │
                        └─────────────┬──────────────────────┘
                                      │
                        ┌─────────────▼──────────────────────┐
                        │         API GATEWAY :8000           │
                        │    JWT · Rate Limit · RBAC          │
                        └──┬──────────┬──────────┬───────────┘
                           │          │          │          │
                      auth-svc  accounts-svc  txn-svc  notif-svc
                       :8001      :8002        :8003     :8004
                         │          │            │          │
                      auth-db  accounts-db   txn-db   notif-db
                     (schema)   (schema)    (schema)   (schema)
```

### 2. البيئة السحابية (AWS Production)

```
User / Employee
 │
 ▼
Route53
 │
 ▼
CloudFront (2 Distributions)
├── app-dev.aurabank-eg.com   →  WAF (OWASP + Rate Limit)
└── teller-dev.aurabank-eg.com →  WAF (IP Allowlist + OWASP)
 │
 ▼
Application Load Balancer (HTTPS)
├── /api/*    →  ECS: api-gateway        :8000
├── /teller/* →  ECS: frontend-teller   :80
└── /*        →  ECS: frontend-customers :80
 │
 ├── ECS Fargate (Private Subnets — AWS Service Discovery)
 │   ├── api-gateway           :8000  (JWT · Rate Limit · RBAC)
 │   ├── auth-service          :8001
 │   ├── accounts-service      :8002
 │   ├── transactions-service  :8003 ──► AWS SQS
 │   └── notifications-service :8004 ◄── AWS SQS ──► SES (Email) · SNS (SMS)
 │
 └── RDS PostgreSQL (Private Subnets)
     ├── schema: auth          (user: auth_user)
     ├── schema: accounts      (user: accounts_user)
     ├── schema: transactions  (user: transactions_user)
     └── schema: notifications (user: notifications_user)
```

---

## الفيتشرز الرئيسية

### 📱 بوابة العملاء (Customer Portal)
- تسجيل حساب جديد فورياً وفتح حساب بنكي تلقائي برقم مميز (`AURA-XXXXXXXX`).
- لوحة تحكم بالرصيد اللحظي والعمليات الأخيرة مع مخططات تفاعلية.
- تحويل أموال داخلي بين الحسابات مع فحص فوري للأرصدة وتجميد الحسابات.
- دفع الفواتير (كهرباء، ماء، إنترنت، غاز) وتحديث الأرصدة تلقائياً.
- صرف العملات الحية بأسعار صرف متعددة (EGP, USD, EUR, GBP, SAR, AED, KWD).
- إدارة البطاقات البنكية الائتمانية والخصم المباشر (تجميد/تفعيل/تفاصيل).
- خطط وأهداف الادخار (Savings Goals) ومتابعة التقدم.
- تقديم طلبات القروض ومتابعة حالتها اللحظية.
- محفظة تداول استثمارية للأسهم.
- مركز إشعارات متكامل (In-App Notifications + Email عبر AWS SES).

### 💼 بوابة الخزينة والعمليات (Teller & Ops Portal)
- تسجيل دخول الموظفين حسب الصلاحيات: `teller`، `supervisor`، `admin`.
- استعراض وبحث وتصفية جميع حسابات العملاء.
- تنفيذ عمليات الإيداع، السحب، والتحويل المباشر من الشباك.
- تجميد وفك تجميد الحسابات البنكية.
- دورة مراجعة واعتماد/رفض طلبات القروض من قِبل المشرفين والمدراء مع الصرف المالي الآلي للرصيد فور الموافقة.
- سجل عمليات الخزينة اليومي (`teller_log`) مع إحصاءات 7 أيام.
- سجل الرقابة والمراجعة الأمني الشامل (`audit_log`).
- لوحة إدارة الموظفين للمدراء (إنشاء موظف، تفعيل/تعطيل الحسابات).

### 🔒 نظام الأمان والحماية
- توثيق JWT مع نظام الصلاحيات المبني على الأدوار (RBAC).
- تشفير كلمات المرور باستخدام خوارزمية `bcrypt`.
- Rate Limiting على مسارات تسجيل الدخول لحماية النظام من Brute-Force Attacks.
- عزل قواعد البيانات على مستوى الـ Schemas والمستخدمين وصلاحيات `GRANT`.
- حماية ضد تعارض العمليات المالية المتزامنة (Race Conditions) باستخدام `SELECT ... FOR UPDATE` في المعاملات البنكية.
- WAFv2 على AWS: قواعد OWASP Top 10 وقائمة بيضاء (IP Allowlist) لبوابة الموظفين.

---

## هيكل المشروع

```
AuraBank/
├── docker-compose.yml                 # تشغيل النظام المحلي كاملاً
├── infrastructure/nginx/              # إعدادات Nginx العكسي
├── scripts/
│   └── init-schemas.sql              # تهيئة الـ PostgreSQL Schemas والمستخدمين
├── services/                          # الـ Microservices المستقلة
│   ├── api-gateway/                   # بوابة الـ API والـ Routing والصلاحيات (:8000)
│   ├── auth-service/                  # خدمة المصادقة والمستخدمين (:8001)
│   ├── accounts-service/              # خدمة الحسابات والبطاقات والقروض (:8002)
│   ├── transactions-service/          # خدمة العمليات والتحويلات وسجلات الخزينة (:8003)
│   ├── notifications-service/         # خدمة الإشعارات و SQS Worker (:8004)
│   ├── frontend-customers/            # واجهة بوابة العملاء (:8080)
│   └── frontend-teller/               # واجهة بوابة الخزينة والعمليات (:8081)
│
├── Jenkinsfiles/                      # Jenkins CI/CD Automation
│   ├── Jenkinsfile.deploy             # بناء ونشر كامل على AWS من الصفر
│   ├── Jenkinsfile.cicd               # Webhook — إعادة بناء الـ Services المعدلة فقط
│   └── Jenkinsfile.destroy            # حذف موارد الـ Infrastructure لتوفير التكاليف
│
└── terraform/                         # AWS Infrastructure as Code
    ├── modules/                       # وحدات قابلة لإعادة الاستخدام (VPC, ALB, ECS, RDS, WAF, etc.)
    ├── envs/dev/                      # بيئة التطوير السحابية (Fargate Spot)
    ├── envs/prod/                     # بيئة الإنتاج السحابية (High Availability)
    └── scripts/                       # سكريبتات الدعم والأتمتة
```

---

## تشغيل المشروع محلياً — Quick Start

### المتطلبات
- **Docker** v20.10+
- **Docker Compose** v2.0+

### خطوات التشغيل

```bash
# 1. الدخول لمجلد المشروع
cd AuraBank

# 2. تشغيل جميع الخدمات والواجهات بضغطة واحدة
docker compose up --build
```

### الروابط المحلية

| الخدمة | الرابط | الوصف |
|--------|--------|-------|
| **بوابة العملاء (Customer Portal)** | [http://localhost:8080](http://localhost:8080) | الواجهة الرئيسية للعملاء |
| **بوابة الخزينة (Teller Portal)** | [http://localhost:8081](http://localhost:8081) | واجهة الموظفين والعمليات |
| **بوابة الـ API (API Gateway)** | [http://localhost:8000](http://localhost:8000) | نقطة الوصول المركزية |
| **فحص الجاهزية (Health Check)** | [http://localhost:8000/ready](http://localhost:8000/ready) | مراقبة صحة الخدمات |

### بيانات الدخول التجريبية (Demo Credentials)

**حسابات العملاء:**

| الاسم | البريد الإلكتروني | كلمة المرور | رقم الحساب | نوع الحساب |
|-------|------------------|------------|------------|-----------|
| أحمد محمد | `demo@aurabank.eg` | `demo123` | `AURA-DEMO0001` | Premium (125,750.50 EGP) |
| نور علي | `nour.ali@gmail.com` | `nour123` | `AURA-ABC12345` | Standard (22,000.00 EGP) |
| تامر حسن | `tamer.h@outlook.com` | `tamer456` | `AURA-BIZ77890` | Business (480,000.00 EGP) |

**حسابات الموظفين:**

| اسم المستخدم | كلمة المرور | الدور (Role) | الفرع |
|------------|------------|--------------|-------|
| `Rafat Ashraf K` | `teller123` | Teller (صراف) | التجمع الخامس |
| `s.ahmed` | `teller456` | Supervisor (مشرف) | المعادي |
| `k.abdallah` | `admin789` | Admin (مدير نظام) | الإدارة العامة |

---

## النشر السحابي — AWS Production

يتم نشر النظام بالكامل تلقائياً بواسطة **Jenkins** مع **Terraform**:

```bash
# 1. Bootstrap Remote State (S3 Bucket + DynamoDB Table)
./terraform/scripts/bootstrap_state.sh dev us-east-1

# 2. تطبيق البنية التحتية
cd terraform/envs/dev
terraform init && terraform apply -var-file=terraform.tfvars

# 3. بناء ورفع حاويات الـ Docker إلى AWS ECR
./terraform/scripts/push_images.sh dev us-east-1 YOUR_ACCOUNT_ID v1.0.0

# 4. تشغيل Lambda لتهيئة جداول قواعد البيانات على RDS
aws lambda invoke --function-name aurabank-dev-db-init --region us-east-1 /tmp/out.json
```

---

## وثائق المشروع التفصيلية

- 📘 [توثيق معمارية الـ Backend والـ Endpoints بالتفصيل](./README.backend.md)
- 🎨 [توثيق معمارية واجهات المستخدم والـ Frontend](./README.frontend.md)
- ⚙️ [توثيق الـ DevOps والـ CI/CD والـ Pipelines](./README_devops.md)
- ☁️ [توثيق موارد AWS السحابية بالتفصيل](./INFRASTRUCTURE-on-AWS.md)
- 🏗️ [دليل الـ Terraform Modules والنشر](./terraform/README.md)

---

<div align="center">

**Aura Bank — Enterprise Cloud Banking Microservices System**  
*Built with FastAPI · PostgreSQL · Docker · AWS ECS Fargate · Terraform · Jenkins*

</div>
