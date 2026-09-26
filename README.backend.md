# 🔧 README — Backend & Microservices

> توثيق تقني كامل لطبقة الـ backend في Aura Bank — المعمارية، كل service، خط سير العمليات، المشاكل والحلول.

---

## المعمارية العامة

يعتمد Aura Bank على **Microservices Architecture** بشكل صارم:
- كل service مستقلة تماماً ولها قاعدة بيانات PostgreSQL خاصة بها
- التواصل بين الـ services يتم فقط عبر HTTP (لا يوجد shared DB أو shared memory)
- الـ API Gateway هو نقطة الدخول الوحيدة من الخارج — يتحقق من الـ JWT ويوجه الطلبات

---

## الـ Services التفصيلية

### 1. API Gateway (`:8000`)
**الملف:** `services/api-gateway/main.py`

**المسؤوليات:**
- التحقق من الـ JWT في كل طلب محمي
- تطبيق Rate Limiting (60 req/min للمستخدم، 10 req/min لـ login)
- توجيه الطلبات للـ service المناسبة عبر `httpx.AsyncClient`
- تسجيل كل طلب بـ Request ID فريد مع وقت الاستجابة
- RBAC: تمييز صلاحيات customer / teller / supervisor / admin

**خط سير طلب نموذجي:**
```
Client → Nginx → API Gateway
    → decode_token()           # فك JWT واستخراج role + sub
    → require_auth() / require_employee()
    → proxy(request, TARGET_URL, path)    # إعادة توجيه كامل مع headers
    → Service → DB
    → JSONResponse ← Service ← Gateway ← Client
```

**Endpoints الرئيسية:**
| المسار | الصلاحية | الهدف |
|--------|---------|-------|
| `POST /api/auth/login` | public | auth-service |
| `GET /api/accounts/me` | customer | accounts-service |
| `POST /api/transactions/transfer` | customer | transactions-service |
| `GET /api/teller/accounts` | employee | accounts-service |
| `GET /api/notifications/{user_id}` | customer | notifications-service |
| `GET /api/admin/employees` | admin/supervisor | auth-service |

---

### 2. Auth Service (`:8001`) — `auth-db`
**الملف:** `services/auth-service/main.py`

**الجداول:**
```sql
users (id, email, password_hash, first_name, last_name, phone, nid, role, created_at)
employees (id, name, username, password_hash, role, branch, created_at)
audit_log (id, actor, action, target, created_at)
```

**الوظائف الرئيسية:**

| Endpoint | الوصف |
|----------|-------|
| `POST /auth/register` | تسجيل عميل جديد + إنشاء account في accounts-service |
| `POST /auth/login` | تسجيل الدخول → JWT |
| `POST /auth/login-employee` | تسجيل دخول موظف → JWT |
| `POST /auth/change-password` | تغيير كلمة المرور بعد التحقق من القديمة |
| `POST /auth/forgot-password` | إعادة تعيين كلمة المرور |
| `GET /internal/employees` | (internal) قائمة الموظفين للمدراء |
| `POST /internal/employees` | (internal) إنشاء موظف جديد |

**خط سير التسجيل:**
```
register() →
  1. hash password (bcrypt)
  2. INSERT INTO users
  3. httpx.POST → accounts-service /internal/create-account  (إنشاء حساب تلقائي)
  4. make_token(user_id, "customer")
  5. return {token, user}
```

**JWT:**
```python
payload = {"sub": user_id, "role": "customer", "exp": now + 7days}
token = jwt.encode(payload, JWT_SECRET, algorithm="HS256")
```

---

### 3. Accounts Service (`:8002`) — `accounts-db`
**الملف:** `services/accounts-service/main.py`

**الجداول:**
```sql
accounts (id, user_id, account_number, account_type, balance, card_number,
          frozen, savings, created_at, updated_at)
cards (id, account_id, user_id, card_type, card_number_masked,
       expiry_month, expiry_year, color, created_at)
savings_goals (id, account_id, name, target_amount, current_amount,
               deadline, status, created_at)
loans (id, account_id, loan_type, amount, interest_rate, duration_months,
       monthly_payment, status, created_at)
portfolio (id, account_id, symbol, shares, avg_price, created_at)
```

**Endpoints الرئيسية:**

| Endpoint | الوصف |
|----------|-------|
| `GET /accounts/user/{user_id}` | جلب حساب العميل مع بطاقاته وأهدافه |
| `GET /accounts/{account_id}` | جلب حساب بالـ ID |
| `POST /internal/create-account` | إنشاء حساب جديد (يُستدعى من auth-service) |
| `POST /internal/update-balance` | تحديث الرصيد (يُستدعى فقط من transactions-service) |
| `GET /internal/find-account` | البحث برقم الحساب أو user_id |
| `POST /accounts/{id}/freeze` | تجميد الحساب |
| `POST /accounts/{id}/unfreeze` | إلغاء التجميد |

**آلية تحديث الرصيد (مع transaction lock):**
```python
# FOR UPDATE يمنع race conditions عند العمليات المتزامنة
SELECT id, balance, frozen FROM accounts WHERE id=%s FOR UPDATE
new_balance = current + delta
if new_balance < 0: raise HTTPException(400, "رصيد غير كافٍ")
UPDATE accounts SET balance=%s WHERE id=%s
```

---

### 4. Transactions Service (`:8003`) — `transactions-db`
**الملف:** `services/transactions-service/main.py`

**الجداول:**
```sql
transactions (id, account_id, from_account_id, to_account_id, type, sub_type,
              description, amount, currency, balance_after, status,
              performed_by, performed_by_id, reference_number, created_at)
teller_log (id, teller_id, teller_name, account_id, customer_name,
            operation, amount, description, created_at)
audit_log (id, actor_name, actor_id, actor_role, action, created_at)
```

**Endpoints الرئيسية:**

| Endpoint | الوصف |
|----------|-------|
| `POST /transactions/deposit` | إيداع نقدي |
| `POST /transactions/withdraw` | سحب نقدي |
| `POST /transactions/transfer` | تحويل بين حسابات |
| `POST /transactions/pay-bill` | دفع فاتورة |
| `POST /transactions/exchange` | صرف عملات |
| `GET /transactions/teller-log` | سجل عمليات الخزينة الكامل |
| `GET /transactions/teller-log-today` | سجل عمليات اليوم |
| `GET /transactions/teller-weekly` | إحصاءات 7 أيام |
| `GET /transactions/audit-log` | سجل المراجعة |
| `GET /transactions/{account_id}` | معاملات حساب معين |

**خط سير عملية إيداع:**
```
deposit() →
  1. call_accounts(POST /internal/update-balance, delta=+amount)
  2. record() → INSERT INTO transactions
  3. INSERT INTO teller_log (إذا كان موظف)
  4. commit()
  5. call_accounts(GET /accounts/{acc_id}) → get user_id
  6. notify(user_id, "إيداع ناجح", ...)  → notifications-service
  7. return {ok, newBalance, transaction}
```

**أسعار العملات (ثابتة في الكود):**
```python
RATES = {"EGP":1, "USD":0.0204, "EUR":0.0188, "GBP":0.016,
         "SAR":0.0765, "AED":0.0749, "KWD":0.00626}
```

---

### 5. Notifications Service (`:8004`) — `notifications-db`
**الملف:** `services/notifications-service/main.py`

**الجداول:**
```sql
notifications (id, user_id, title, body, type, read, created_at)
```

**Endpoints:**

| Endpoint | الوصف |
|----------|-------|
| `POST /internal/create` | إنشاء إشعار جديد (يُستدعى من services أخرى) |
| `GET /notifications/{user_id}` | جلب إشعارات مستخدم + عدد غير المقروءة |
| `PUT /notifications/{user_id}/read/{id}` | تعليم إشعار كمقروء |
| `PUT /notifications/{user_id}/read-all` | تعليم الكل كمقروء |

**تدفق الإشعار:**
```
transactions-service → POST http://notifications-service:8004/internal/create
                              {user_id, title, body, type}
                        → INSERT INTO notifications
                        
frontend → GET /api/notifications/{user_id}
         → API Gateway → GET /notifications/{user_id}
         → SELECT * FROM notifications WHERE user_id=? ORDER BY created_at DESC
```

---

## المشاكل التي واجهناها والحلول

### 🔴 Bug #1 — Route Ordering في FastAPI (500 Error على teller-log-today)

**المشكلة:**
```python
# ❌ المسار الديناميكي كان أول — يلتقط كل شيء
@app.get("/transactions/{account_id}")   # line 123
@app.get("/transactions/teller-log-today")  # line 354 — لا يُوصل إليها!
```
FastAPI يطابق المسارات بالترتيب. عند طلب `/transactions/teller-log-today` كان يمسكه المسار الديناميكي ويمرر `"teller-log-today"` كـ UUID للـ PostgreSQL فيفشل.

**الخطأ في الـ logs:**
```
psycopg2.errors.InvalidTextRepresentation:
invalid input syntax for type uuid: "teller-log-today"
```

**الحل:**
نقل `@app.get("/transactions/{account_id}")` إلى **آخر الملف** بعد جميع المسارات الثابتة.

---

### 🔴 Bug #2 — Cross-Database JOIN (مخالفة لمعمارية الـ Microservices)

**المشكلة:**
```sql
-- في transactions-service يستعمل transactions-db
-- لكن يحاول JOIN مع جدول accounts الموجود في accounts-db!
SELECT tl.*, a.account_number
FROM teller_log tl
LEFT JOIN accounts a ON a.id = tl.account_id  -- ❌ مستحيل!
```

**الحل:**
حذف الـ JOIN — كل service تقرأ فقط من قاعدة بياناتها الخاصة. إذا احتجنا `account_number` نجلبه عبر HTTP call لـ accounts-service.

---

### 🟡 Bug #3 — صمت أخطاء الإشعارات

**المشكلة:**
```python
except: pass  # ← يخفي كل الأخطاء بدون تسجيل
```

**الحل:**
```python
except Exception as e:
    log.warning(f"Notify error: {e}")
```
بالإضافة إلى إضافة التحقق من status code داخل `notify()`.

---

### 🟡 Bug #4 — التحويل لا يُشعر المُرسِل

**المشكلة:** عملية التحويل كانت تُشعر المستقبل فقط، والمُرسِل لا يرى أي إشعار.

**الحل:** إضافة `notify()` للمُرسِل بعد اكتمال عملية التحويل.

---

## ملاحظات أمنية

- `/internal/*` endpoints غير مكشوفة في الـ API Gateway — للاستخدام الداخلي فقط بين الـ services
- كل قاعدة بيانات على شبكة Docker منفصلة عن الـ frontend
- الـ JWT Secret يُضبط عبر environment variable
- bcrypt rounds افتراضي للـ password hashing
