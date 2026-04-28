# Litespeed-Purge-All

Bash script สำหรับ trigger **LiteSpeed Cache Purge All** บน WordPress ผ่าน WP-CLI  
รองรับทั้ง Purge ทุก domain บนเซิร์ฟเวอร์ หรือเลือกเฉพาะ cPanel Account  
ตรวจสอบผล Cloudflare purge แยกต่างหาก พร้อม Telegram notification

---

## รันคำสั่งเดียว (ไม่ต้องดาวน์โหลด)

> **หมายเหตุ:** ต้องรันด้วยสิทธิ์ root เสมอ

```bash
bash <(curl -sL https://raw.githubusercontent.com/AnonymousVS/Litespeed-Purge-All/main/litespeed-purge-all.sh)
```

---

## การติดตั้ง

```bash
curl -sL https://raw.githubusercontent.com/AnonymousVS/Litespeed-Purge-All/main/litespeed-purge-all.sh \
    -o /usr/local/sbin/litespeed-purge-all.sh

chmod +x /usr/local/sbin/litespeed-purge-all.sh
```

รัน:
```bash
litespeed-purge-all.sh
```

---

## เมนูการใช้งาน

```
╔══════════════════════════════════════════════════════════════╗
║  LiteSpeed Purge All  v2.2.0                                ║
║  Server: ns5041423                                           ║
╚══════════════════════════════════════════════════════════════╝

  เลือกโหมด Purge:

  [1]  Purge ทุก Domain บนเซิร์ฟเวอร์
  [2]  Purge เฉพาะ cPanel Account ที่เลือก

  [0]  ออก
```

เมื่อเลือก **[2]** จะแสดงรายชื่อ cPanel accounts พร้อมจำนวน domain:

```
  เลือก cPanel Account:
  ─────────────────────────────────────────────
  [ 1]  cpuser1              850 domain(s)
  [ 2]  cpuser2              720 domain(s)
  [ 3]  cpuser3              612 domain(s)
  ─────────────────────────────────────────────
```

---

## Telegram Notification

แก้ค่าตรงบนสุดของ script:

```bash
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN="your_bot_token"
TELEGRAM_CHAT_ID="your_chat_id"
```

ตัวอย่างข้อความที่ได้รับ:

```
✅ LiteSpeed Purge All
🖥 Server: ns5041423
🕐 เสร็จ: 2026-04-28 17:30:00

📊 ผลลัพธ์:
├ Total      : 2846
├ ✅ Success  : 2840
├ ⚠️ CF issue : 4
└ ❌ Failed   : 2
```

---

## ผลลัพธ์ที่เป็นไปได้

| สถานะ | เงื่อนไข |
|-------|---------|
| ✅ **SUCCESS** | LiteSpeed purge OK + (CF OK หรือ CF ไม่ได้ configure) |
| ⚠️ **CF PURGE FAILED** | LiteSpeed OK + Cloudflare ติดต่อได้แต่ purge ไม่ผ่าน |
| ⚠️ **CF CONN FAILED** | LiteSpeed OK + Cloudflare ติดต่อไม่ได้เลย |
| ⚠️ **CF UNCONFIRMED** | LiteSpeed OK + CF configure แต่ไม่มี notices ใน DB |
| ❌ **FAILED** | LiteSpeed purge เอง fail |

---

## Log Files

```
/var/log/ls-purge-all/
├── purge_YYYYMMDD_HHMMSS.log          ← full log ทุก domain
└── purge_FAIL_YYYYMMDD_HHMMSS.log     ← เฉพาะ domain ที่มีปัญหา
```

---

## ความต้องการของระบบ

| รายการ | รายละเอียด |
|--------|-----------|
| OS | AlmaLinux 9 / CentOS / RHEL |
| Control Panel | cPanel/WHM |
| WP-CLI | 2.x+ |
| LiteSpeed Cache Plugin | 4.x / 5.x / 6.x / 7.x |
| สิทธิ์ | root |

---

## โครงสร้างไฟล์ใน Repo

```
Litespeed-Purge-All/
├── litespeed-purge-all.sh
└── README.md
```
