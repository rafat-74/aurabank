# 🎨 README — Frontend

> توثيق كامل لطبقة الـ frontend في Aura Bank — هيكل الـ UI، تدفق البيانات، الصفحات، والقرارات التقنية.

---

## نظرة عامة

يتكون الـ frontend من **تطبيقين Single-Page** مبنيين بـ Vanilla HTML/CSS/JS — بدون أي framework خارجي. كل تطبيق يُقدَّم عبر Nginx كـ static files.

| التطبيق | المنفذ | المستخدم |
|---------|--------|---------|
| `frontend-customers` | `:3000` | العملاء |
| `frontend-teller` | `:3001` | موظفو الخزينة |

---

## التقنيات المستخدمة

- **HTML5** — Single-file SPA (كل التطبيق في `index.html` واحد)
- **CSS3** — CSS Variables، Flexbox، Grid، Animations
- **JavaScript (ES2020+)** — async/await، fetch API، sessionStorage
- **Nginx** — Static file server لكل frontend
- **لا يوجد** React / Vue / Angular / jQuery

---

## frontend-customers — بوابة العملاء

### هيكل الـ SPA
الـ app كله ملف `index.html` واحد. التنقل بين الصفحات يتم بإخفاء/إظهار divs:
```javascript
function showPage(page) {
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.getElementById(`page-${page}`).style.display = 'block';
  if (page === 'notifications') loadNotifications();
  if (page === 'dashboard') loadMyAccount();
}
```

### الصفحات

| الصفحة | الـ ID | الوصف |
|--------|--------|-------|
| Landing | `page-landing` | الصفحة الرئيسية قبل تسجيل الدخول |
| Login | `page-login` | تسجيل الدخول |
| Register | `page-register` | إنشاء حساب جديد |
| Dashboard | `page-dashboard` | لوحة التحكم الرئيسية + الرصيد |
| Transactions | `page-transactions` | سجل المعاملات |
| Transfer | `page-transfer` | تحويل الأموال |
| Pay Bill | `page-pay-bill` | دفع الفواتير |
| Exchange | `page-exchange` | صرف العملات |
| Cards | `page-cards` | البطاقات البنكية |
| Goals | `page-goals` | أهداف الادخار |
| Loans | `page-loans` | القروض |
| Portfolio | `page-portfolio` | المحفظة الاستثمارية |
| Notifications | `page-notifications` | الإشعارات |
| Settings | `page-settings` | الإعدادات |

### إدارة الحالة (State Management)
```javascript
const DB = {
  currentUser: null,      // بيانات المستخدم الحالي + accountId + balance
  users: [],              // cache مؤقت
  addTransaction(uid, tx) { ... }
};

const TOKEN = {
  get()    { return sessionStorage.getItem('aura_token'); },
  set(t)   { sessionStorage.setItem('aura_token', t); },
  clear()  { sessionStorage.removeItem('aura_token'); }
};
```

### خط سير تسجيل الدخول
```
doLogin() →
  1. POST /api/auth/login {email, password}
  2. TOKEN.set(res.token)
  3. DB.currentUser = res.user
  4. loadMyAccount() →
       GET /api/accounts/me
       GET /api/transactions/{accountId}
  5. showPage('dashboard')
```

### خط سير التحويل
```
doTransfer() →
  1. validation (amount > 0, to != from)
  2. POST /api/transactions/transfer
     {fromAccountId, toAccountNumber, amount, note}
  3. DB.currentUser.balance -= amount  (optimistic update)
  4. DB.addTransaction(...)
  5. showToast('تم التحويل بنجاح')
  6. showPage('dashboard')
  → Notification يصل في loadNotifications() القادمة
```

### نظام الإشعارات في الـ Frontend
```javascript
async function loadNotifications() {
  const d = await apiCall('GET', `/api/notifications/${DB.currentUser.id}`);
  if (d && d.notifications) DB.currentUser.notifications = d.notifications;
  // render في page-notifications
}
// يُستدعى عند:
// - فتح صفحة الإشعارات
// - بعد كل عملية ناجحة
```

---

## frontend-teller — بوابة الخزينة

### الصفحات الرئيسية

| الصفحة | الوصف |
|--------|-------|
| Login | تسجيل دخول الموظف (username + password) |
| Dashboard | إحصاءات اليوم + ملخص سريع |
| Accounts | جدول جميع الحسابات مع بحث وتصفية |
| Account Detail | تفاصيل حساب + العمليات المتاحة |
| Teller Log | سجل عمليات الخزينة اليوم |
| Audit Log | سجل المراجعة الكامل |

### خط سير عملية إيداع (Teller)
```
tellerDeposit() →
  1. اختيار حساب من القائمة
  2. إدخال المبلغ والملاحظة
  3. POST /api/teller/deposit
     {accountId, amount, note, tellerName, tellerId, customerName}
  4. تحديث العرض المحلي
  5. تسجيل في audit-log تلقائياً
  6. → transactions-service يسجل في teller_log + يرسل إشعار للعميل
```

### polling الإشعارات للصفحة الرئيسية
```javascript
// الـ teller dashboard يستدعي teller-log-today كل 30 ثانية
setInterval(() => {
  loadTellerLogToday();
}, 30000);
```

---

## التصميم والـ UI

### Color Palette
```css
:root {
  --bg:            #080c0e;   /* خلفية داكنة فحمي Obsidian */
  --surface:       #101820;   /* Cards & Panels */
  --emerald:       #10b981;   /* اللون الرئيسي الفخم (Emerald Wealth) */
  --emerald-light: #34d399;   /* تفاصيل وتمييز النصوص والأيقونات */
  --green:         #10b981;   /* عمليات ناجحة / إيداع */
  --red:           #f43f5e;   /* تحذيرات / سحب */
  --text:          #f8fafc;   /* نصوص ساطعة واضحة */
  --text-muted:    #8b9cb0;
}
```

### مكونات الـ UI المكررة
- **Toast notifications** — `showToast(msg, type)` — تظهر 3 ثوانٍ
- **Spinner** — `showSpinner(msg) / hideSpinner()` — أثناء API calls
- **Error display** — `showError(element, msg)` — inline في النماذج
- **Money formatter** — `formatMoney(n)` — أرقام بفواصل + EGP

---

## التحديات والحلول في الـ Frontend

### 🟡 Challenge #1 — Optimistic Updates vs Server State
العمليات المالية تُحدَّث محلياً فوراً للمستخدم لكن الرصيد الحقيقي يأتي من الـ server في `loadMyAccount()` القادمة. هذا يعطي UX سريع مع ضمان الدقة.

### 🟡 Challenge #2 — Race Condition في التسجيل
بعد التسجيل، accounts-service يحتاج وقتاً لإنشاء الحساب. الحل: retry loop:
```javascript
for (let i = 0; i < 3; i++) {
  const a = await loadMyAccount();
  if (a && a.account) break;
  await new Promise(r => setTimeout(r, 800));
}
```

### 🟡 Challenge #3 — Session Persistence
JWT محفوظ في `sessionStorage` (وليس `localStorage`) — يُمحى عند إغلاق التبويب. عند إعادة فتح الصفحة يُقرأ الـ token ويُستعاد الـ session.

---

## ملف nginx.conf للـ Frontend
```nginx
server {
  listen 80;
  root /usr/share/nginx/html;
  index index.html;
  location / {
    try_files $uri $uri/ /index.html;  # SPA fallback
  }
}
```
