#!/bin/bash
# ==================================================
# RenVGK PREMIUM v3.0 - FULL UPDATE
# - Encrypted API Key (Sodium)
# - Split panel: user (/admin) & core (/x-panel-core)
# - Blur paywall video + unlock
# - Pricing: Basic 5d / Pro 1mo / Promax 1yr
# ==================================================
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

clear
cat <<'BANNER'
   ___              __     __  ______ __
  / _ \___ ___  ___/ /_   / / / / ___// /_
 / , _/ -_) _ \/ _  / _ \/ /_/ / (_ / __/
/_/|_|\__/_//_/\_,_/\___/\__, /\___/_/
                        /____/  PREMIUM v3.0
BANNER

[[ $EUID -eq 0 ]] || { echo -e "${RED}Jalankan sebagai root!${NC}"; exit 1; }

LOG="/var/log/renvgk-update-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo -e "${RED}❌ ERROR baris $LINENO. Log: $LOG${NC}"' ERR

for CMD in php mysql openssl curl python3 nginx systemctl; do
    command -v "$CMD" >/dev/null || { echo -e "${RED}Dependency hilang: $CMD${NC}"; exit 1; }
done
php -r 'exit(extension_loaded("sodium") ? 0 : 1);' || { echo -e "${RED}PHP Sodium belum ada!${NC}"; exit 1; }

# ---------- Domain ----------
DEFAULT_DOMAIN=$(grep -rhoP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/ 2>/dev/null | head -1 | awk '{print $1}' || true)
read -rp "Domain RenVGK [${DEFAULT_DOMAIN:-}]: " DOMAIN
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || { echo -e "${RED}Domain invalid${NC}"; exit 1; }

ROOT="/var/www/$DOMAIN"
WEB="$ROOT/public"
ADMIN="$ROOT/admin"
CORE="$ROOT/x-panel-core"
INC="$ROOT/includes"
KEYDIR="/etc/renvgk"
KEYFILE="$KEYDIR/$DOMAIN.key"

[[ -f "$INC/config.php" ]] || { echo -e "${RED}Instalasi RenVGK tidak ditemukan di $ROOT${NC}"; exit 1; }

# ---------- 0. Backup ----------
echo -e "${CYAN}[0/9] Backup...${NC}"
BACKUP_DIR="/root/renvgk-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
mysqldump --single-transaction renvgk_db > "$BACKUP_DIR/renvgk_db.sql" 2>/dev/null || echo -e "${YELLOW}⚠️  Backup DB gagal (lanjut)${NC}"
cp -a "$INC" "$BACKUP_DIR/includes" 2>/dev/null || true
cp -a "$ADMIN" "$BACKUP_DIR/admin" 2>/dev/null || true
echo -e "${GREEN}✅ Backup: $BACKUP_DIR${NC}"

# ---------- 1. Enkripsi API ----------
echo -e "${CYAN}[1/9] Menyiapkan enkripsi API...${NC}"
mkdir -p "$KEYDIR"; chmod 750 "$KEYDIR"
if [[ ! -f "$KEYFILE" ]]; then
    openssl rand -hex 32 > "$KEYFILE"
    echo -e "${GREEN}🔑 Key baru dibuat${NC}"
else
    echo -e "${YELLOW}🔑 Key sudah ada (tidak ditimpa)${NC}"
fi
chown root:www-data "$KEYFILE"; chmod 640 "$KEYFILE"

COL_TYPE=$(mysql -N -B renvgk_db -e "SELECT DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='renvgk_db' AND TABLE_NAME='settings' AND COLUMN_NAME='apikey';" 2>/dev/null || echo "")
[[ -n "$COL_TYPE" ]] || { echo -e "${RED}Tabel settings.apikey tidak ditemukan${NC}"; exit 1; }
if [[ "$COL_TYPE" != "text" && "$COL_TYPE" != "mediumtext" && "$COL_TYPE" != "longtext" ]]; then
    mysql renvgk_db -e "ALTER TABLE settings MODIFY apikey TEXT;"
fi

# ---------- 2. Config security ----------
echo -e "${CYAN}[2/9] Update config...${NC}"
cp "$INC/config.php" "$INC/config.php.backup.$(date +%s)"

if ! grep -q 'RENVGK V3 SECURITY' "$INC/config.php"; then
cat >> "$INC/config.php" << 'PHP'

/* ========== RENVGK V3 SECURITY ========== */
define('RENVGK_KEY_FILE', '/etc/renvgk/' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . '.key');

function renvgkEncryptionKey() {
    $file = RENVGK_KEY_FILE;
    if (!is_file($file)) throw new RuntimeException('Encryption key tidak ditemukan');
    $key = hex2bin(trim(file_get_contents($file)));
    if ($key === false || strlen($key) !== SODIUM_CRYPTO_SECRETBOX_KEYBYTES)
        throw new RuntimeException('Encryption key tidak valid');
    return $key;
}
function encryptLzApiKey($v) {
    $n = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    return 'enc:' . base64_encode($n . sodium_crypto_secretbox($v, $n, renvgkEncryptionKey()));
}
function getLzApiKey() {
    global $pdo;
    $v = $pdo->query("SELECT apikey FROM settings WHERE id=1")->fetchColumn();
    if (!$v) return '';
    if (strpos($v, 'enc:') !== 0) return $v;
    $d = base64_decode(substr($v, 4), true);
    if ($d === false) throw new RuntimeException('Ciphertext invalid');
    $n = substr($d, 0, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    $c = substr($d, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    $r = sodium_crypto_secretbox_open($c, $n, renvgkEncryptionKey());
    if ($r === false) throw new RuntimeException('Decrypt gagal');
    return $r;
}
function saveLzApiKey($v) {
    global $pdo;
    $pdo->prepare("UPDATE settings SET apikey=? WHERE id=1")->execute([encryptLzApiKey(trim($v))]);
}
function lzApiGet($endpoint) {
    $key = getLzApiKey();
    if (!$key) throw new RuntimeException('API Key belum diatur');
    $url = 'https://app.lzpedia.my.id/api/' . $endpoint . '?apikey=' . rawurlencode($key);
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20, CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    $r = curl_exec($ch);
    if ($r === false) { $e = curl_error($ch); curl_close($ch); throw new RuntimeException($e); }
    $s = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    if ($s < 200 || $s >= 300) throw new RuntimeException('LZPedia HTTP ' . $s);
    $j = json_decode($r, true);
    if (!is_array($j)) throw new RuntimeException('Response invalid');
    return $j;
}
PHP
fi
sed -i "s|'localhost'|'$DOMAIN'|" "$INC/config.php" 2>/dev/null || true

# ---------- 3. Pricing, Plans & Video Unlock tables ----------
echo -e "${CYAN}[3/9] Membuat tabel paket & unlock...${NC}"
mysql renvgk_db <<'SQL'
CREATE TABLE IF NOT EXISTS plans (
    id INT AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(32) NOT NULL UNIQUE,
    name VARCHAR(64) NOT NULL,
    price INT NOT NULL,
    duration_days INT NOT NULL,
    video_limit INT NOT NULL,           -- 0 = unlimited
    update_limit_per_day INT NOT NULL,  -- 0 = unlimited
    description TEXT,
    active TINYINT(1) DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO plans (code,name,price,duration_days,video_limit,update_limit_per_day,description) VALUES
('basic','Basic',5000,5,3,1,'5 hari akses. Update video terbatas hanya video 1-3.'),
('pro','Pro',15000,30,10,1,'1 bulan akses. Update hingga 10 video per hari.'),
('promax','Promax',25000,365,0,0,'1 tahun akses. Video permanen & update terus-menerus.')
ON DUPLICATE KEY UPDATE name=VALUES(name),price=VALUES(price),duration_days=VALUES(duration_days),
    video_limit=VALUES(video_limit),update_limit_per_day=VALUES(update_limit_per_day),description=VALUES(description);

CREATE TABLE IF NOT EXISTS user_subscriptions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    plan_code VARCHAR(32) NOT NULL,
    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL,
    active TINYINT(1) DEFAULT 1,
    INDEX (user_id, active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS video_unlocks (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    video_id INT NOT NULL,
    unlocked_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_user_video (user_id, video_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS core_admins (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(64) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    last_login DATETIME NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL

# ---------- 4. Auth helper core panel ----------
echo -e "${CYAN}[4/9] Setup core panel...${NC}"
mkdir -p "$CORE"; chmod 750 "$CORE"

cat > "$INC/core-auth.php" << 'PHP'
<?php
if (session_status() === PHP_SESSION_NONE) {
    session_name('RENVGK_CORE');
    session_set_cookie_params([
        'lifetime' => 0,
        'path'     => '/x-panel-core',
        'secure'   => !empty($_SERVER['HTTPS']),
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    session_start();
}
function coreAdmin() {
    if (empty($_SESSION['core_admin_id']) || empty($_SESSION['core_fp'])) {
        header('Location: /x-panel-core/login.php'); exit;
    }
    if ($_SESSION['core_fp'] !== hash('sha256', $_SERVER['HTTP_USER_AGENT'] ?? '')) {
        session_destroy(); header('Location: /x-panel-core/login.php'); exit;
    }
}
function coreLogin($pdo, $user, $pass) {
    $stmt = $pdo->prepare("SELECT id, password_hash FROM core_admins WHERE username=?");
    $stmt->execute([$user]);
    $row = $stmt->fetch();
    if (!$row) return false;
    if (!password_verify($pass, $row['password_hash'])) return false;
    session_regenerate_id(true);
    $_SESSION['core_admin_id'] = (int)$row['id'];
    $_SESSION['core_fp'] = hash('sha256', $_SERVER['HTTP_USER_AGENT'] ?? '');
    $pdo->prepare("UPDATE core_admins SET last_login=NOW() WHERE id=?")->execute([$row['id']]);
    return true;
}
function coreLogout() {
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', time()-42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
    }
    session_destroy();
}
PHP

# login.php
cat > "$CORE/login.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
$err = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!verifyCsrf($_POST['csrf'] ?? '')) die('CSRF failed');
    $u = trim($_POST['username'] ?? '');
    $p = $_POST['password'] ?? '';
    if (coreLogin($pdo, $u, $p)) { header('Location: index.php'); exit; }
    $err = 'Login gagal';
}
?>
<!DOCTYPE html><html><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Core Panel</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:radial-gradient(circle at top,#1e1b4b,#09090d);color:#fff;font-family:system-ui}
.box{width:100%;max-width:380px;padding:30px;background:#111116;border:1px solid #2a2a35;border-radius:18px}
h1{font-size:20px;margin:0 0 18px;color:#facc15;letter-spacing:.5px}
input{width:100%;padding:12px;margin-bottom:12px;background:#0a0a0f;border:1px solid #333;color:#fff;border-radius:10px;box-sizing:border-box}
button{width:100%;padding:12px;background:#facc15;color:#000;font-weight:700;border:0;border-radius:10px;cursor:pointer}
.err{color:#fb7185;font-size:13px;margin-bottom:10px}
</style></head><body>
<form class="box" method="POST">
<h1>RENVGK CORE</h1>
<?php if($err): ?><div class="err"><?=htmlspecialchars($err)?></div><?php endif; ?>
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input name="username" placeholder="Username" required autocomplete="username">
<input name="password" type="password" placeholder="Password" required autocomplete="current-password">
<button>Masuk</button>
</form></body></html>
PHP

# logout.php
cat > "$CORE/logout.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
coreLogout(); header('Location: login.php'); exit;
PHP

# index.php — dashboard core
cat > "$CORE/index.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
coreAdmin();

$totalUsers = $pdo->query("SELECT COUNT(*) FROM users")->fetchColumn() ?: 0;
$activeSub  = $pdo->query("SELECT COUNT(*) FROM user_subscriptions WHERE active=1 AND expires_at>NOW()")->fetchColumn() ?: 0;
$unlocks    = $pdo->query("SELECT COUNT(*) FROM video_unlocks")->fetchColumn() ?: 0;
$revenue    = $pdo->query("SELECT COALESCE(SUM(amount),0) FROM transactions WHERE status='paid'")->fetchColumn() ?: 0;

$apiOk = false; $apiMsg = '';
try { $b = lzApiGet('balance'); $apiOk = true; $apiMsg = 'Saldo: '.rupiah($b['balance'] ?? 0); }
catch (Throwable $e) { $apiMsg = $e->getMessage(); }

function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Core Panel</title>
<style>
body{margin:0;background:#09090d;color:#fff;font-family:system-ui}
nav{padding:14px 20px;background:#111116;border-bottom:1px solid #22222c;display:flex;justify-content:space-between;align-items:center}
nav a{color:#999;text-decoration:none;margin-left:16px;font-size:14px}
nav a:hover{color:#facc15}
.wrap{max-width:1100px;margin:30px auto;padding:0 20px}
h1{margin:0 0 20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px}
.card{background:#14141b;border:1px solid #26262f;border-radius:14px;padding:20px}
.card small{color:#888;font-size:12px}
.card h2{margin:8px 0 0;font-size:22px}
.ok{color:#4ade80}.warn{color:#fb7185}
.btn{display:inline-block;padding:10px 16px;background:#facc15;color:#000;font-weight:700;border-radius:10px;text-decoration:none;margin-right:8px}
</style></head><body>
<nav><strong style="color:#facc15">RENVGK CORE</strong>
<div><a href="users.php">Users</a><a href="plans.php">Plans</a><a href="finance.php">Finance</a><a href="logout.php">Logout</a></div></nav>
<div class="wrap">
<h1>Dashboard</h1>
<div class="grid">
<div class="card"><small>Total User</small><h2><?=number_format($totalUsers)?></h2></div>
<div class="card"><small>Langganan Aktif</small><h2><?=number_format($activeSub)?></h2></div>
<div class="card"><small>Video Ter-unlock</small><h2><?=number_format($unlocks)?></h2></div>
<div class="card"><small>Pendapatan</small><h2 class="ok"><?=rupiah($revenue)?></h2></div>
</div>
<div class="card" style="margin-top:20px">
<small>LZPedia Gateway</small>
<h2 class="<?=$apiOk?'ok':'warn'?>" style="font-size:16px;margin-top:8px"><?=h($apiMsg)?></h2>
</div>
<div style="margin-top:24px"><a class="btn" href="/admin/">Ke Panel User</a></div>
</div></body></html>
PHP

# users.php
cat > "$CORE/users.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
coreAdmin();
$rows = $pdo->query("SELECT id,username,email,created_at FROM users ORDER BY id DESC LIMIT 200")->fetchAll();
function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Users</title>
<style>
body{margin:0;background:#09090d;color:#fff;font-family:system-ui}
nav{padding:14px 20px;background:#111116;border-bottom:1px solid #22222c;display:flex;justify-content:space-between}
nav a{color:#999;text-decoration:none;margin-left:16px;font-size:14px}
.wrap{max-width:1100px;margin:30px auto;padding:0 20px}
table{width:100%;border-collapse:collapse;background:#14141b;border-radius:12px;overflow:hidden}
th,td{padding:12px;text-align:left;border-bottom:1px solid #22222c;font-size:14px}
th{background:#1a1a22;color:#facc15}
</style></head><body>
<nav><strong style="color:#facc15">RENVGK CORE</strong>
<div><a href="index.php">Dashboard</a><a href="logout.php">Logout</a></div></nav>
<div class="wrap"><h1>Users (<?=count($rows)?>)</h1>
<table><tr><th>ID</th><th>Username</th><th>Email</th><th>Dibuat</th></tr>
<?php foreach($rows as $r): ?><tr>
<td><?=$r['id']?></td><td><?=h($r['username'])?></td><td><?=h($r['email'])?></td><td><?=h($r['created_at'])?></td>
</tr><?php endforeach; ?>
</table></div></body></html>
PHP

# plans.php
cat > "$CORE/plans.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
coreAdmin();
$msg='';
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['code'])) {
    if (!verifyCsrf($_POST['csrf']??'')) die('CSRF');
    $st = $pdo->prepare("UPDATE plans SET price=?,duration_days=?,video_limit=?,update_limit_per_day=?,description=? WHERE code=?");
    $st->execute([
        (int)$_POST['price'],(int)$_POST['duration_days'],
        (int)$_POST['video_limit'],(int)$_POST['update_limit_per_day'],
        trim($_POST['description']), $_POST['code']
    ]);
    $msg='Tersimpan';
}
$plans = $pdo->query("SELECT * FROM plans ORDER BY id")->fetchAll();
function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Plans</title>
<style>
body{margin:0;background:#09090d;color:#fff;font-family:system-ui}
nav{padding:14px 20px;background:#111116;border-bottom:1px solid #22222c;display:flex;justify-content:space-between}
nav a{color:#999;text-decoration:none;margin-left:16px;font-size:14px}
.wrap{max-width:900px;margin:30px auto;padding:0 20px}
.card{background:#14141b;border:1px solid #26262f;border-radius:14px;padding:20px;margin-bottom:16px}
input,textarea{width:100%;padding:10px;margin:6px 0 12px;background:#0a0a0f;border:1px solid #333;color:#fff;border-radius:8px;box-sizing:border-box}
button{padding:10px 18px;background:#facc15;color:#000;border:0;border-radius:8px;font-weight:700;cursor:pointer}
label{font-size:12px;color:#999}
h3{margin:0 0 14px;color:#facc15}
</style></head><body>
<nav><strong style="color:#facc15">RENVGK CORE</strong>
<div><a href="index.php">Dashboard</a><a href="logout.php">Logout</a></div></nav>
<div class="wrap"><h1>Paket</h1>
<?php if($msg): ?><div class="card" style="color:#4ade80"><?=h($msg)?></div><?php endif; ?>
<?php foreach($plans as $p): ?>
<form class="card" method="POST">
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input type="hidden" name="code" value="<?=h($p['code'])?>">
<h3><?=h($p['name'])?> (<?=h($p['code'])?>)</h3>
<label>Harga (Rp)</label><input name="price" type="number" value="<?=$p['price']?>">
<label>Durasi (hari)</label><input name="duration_days" type="number" value="<?=$p['duration_days']?>">
<label>Limit Video (0=unlimited)</label><input name="video_limit" type="number" value="<?=$p['video_limit']?>">
<label>Limit Update/Hari (0=unlimited)</label><input name="update_limit_per_day" type="number" value="<?=$p['update_limit_per_day']?>">
<label>Deskripsi</label><textarea name="description" rows="3"><?=h($p['description'])?></textarea>
<button>Simpan</button>
</form>
<?php endforeach; ?>
</div></body></html>
PHP

# finance.php — pindahan dari admin
cat > "$CORE/finance.php" << 'PHP'
<?php
require __DIR__ . '/../includes/config.php';
require __DIR__ . '/../includes/core-auth.php';
coreAdmin();

$success=''; $error='';
if ($_SERVER['REQUEST_METHOD']==='POST') {
    if (!verifyCsrf($_POST['csrf']??'')) die('CSRF');
    if (isset($_POST['save_api'])) {
        $key = trim($_POST['apikey']??'');
        if (strlen($key)<10 || strlen($key)>500) { $error='API Key tidak valid'; }
        else { try { saveLzApiKey($key); $success='API Key tersimpan (encrypted)'; } catch(Throwable $e){ $error='Gagal menyimpan'; } }
    }
}
$balance=null;$methods=null;$apiErr='';
if (getLzApiKey()) {
    try { $balance=lzApiGet('balance'); $methods=lzApiGet('withdraw/methods'); }
    catch(Throwable $e){ $apiErr=$e->getMessage(); }
}
$total   = $pdo->query("SELECT COUNT(*) FROM transactions")->fetchColumn();
$paid    = $pdo->query("SELECT COUNT(*) FROM transactions WHERE status='paid'")->fetchColumn();
$pending = $pdo->query("SELECT COUNT(*) FROM transactions WHERE status='pending'")->fetchColumn();
$revenue = $pdo->query("SELECT COALESCE(SUM(amount),0) FROM transactions WHERE status='paid'")->fetchColumn();
function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Finance</title>
<style>
body{margin:0;background:#09090d;color:#fff;font-family:system-ui}
nav{padding:14px 20px;background:#111116;border-bottom:1px solid #22222c;display:flex;justify-content:space-between}
nav a{color:#999;text-decoration:none;margin-left:16px;font-size:14px}
.wrap{max-width:1000px;margin:30px auto;padding:0 20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px}
.card{background:#14141b;border:1px solid #26262f;border-radius:14px;padding:20px}
.card small{color:#888;font-size:12px}
.card h2{margin:8px 0 0;font-size:20px}
.ok{color:#4ade80}.warn{color:#fb7185}
input{width:100%;padding:12px;margin:10px 0;background:#0a0a0f;border:1px solid #333;color:#fff;border-radius:8px;box-sizing:border-box}
button{padding:12px 20px;background:#facc15;color:#000;border:0;border-radius:8px;font-weight:700;cursor:pointer}
table{width:100%;border-collapse:collapse;margin-top:14px}
th,td{padding:10px;text-align:left;border-bottom:1px solid #22222c;font-size:14px}
th{color:#facc15}
</style></head><body>
<nav><strong style="color:#facc15">RENVGK CORE</strong>
<div><a href="index.php">Dashboard</a><a href="logout.php">Logout</a></div></nav>
<div class="wrap">
<h1>Finance</h1>
<?php if($success): ?><div class="card ok"><?=h($success)?></div><?php endif; ?>
<?php if($error): ?><div class="card warn"><?=h($error)?></div><?php endif; ?>
<div class="grid">
<div class="card"><small>Total Transaksi</small><h2><?=number_format($total)?></h2></div>
<div class="card"><small>Paid</small><h2 class="ok"><?=$paid?></h2></div>
<div class="card"><small>Pending</small><h2><?=$pending?></h2></div>
<div class="card"><small>Pendapatan</small><h2 class="ok"><?=rupiah($revenue)?></h2></div>
</div>

<div class="card" style="margin-top:20px">
<h3 style="margin-top:0;color:#facc15">LZPedia Gateway</h3>
<?php if($balance && isset($balance['balance'])): ?>
<p>Saldo: <strong class="ok"><?=rupiah($balance['balance'])?></strong></p>
<p style="color:#999">Username: <?=h($balance['username']??'-')?> | Email: <?=h($balance['email']??'-')?></p>
<?php else: ?><p style="color:#999">Saldo belum tersedia.</p><?php endif; ?>
<?php if($apiErr): ?><p class="warn">API Error: <?=h($apiErr)?></p><?php endif; ?>
</div>

<div class="card" style="margin-top:20px">
<h3 style="margin-top:0;color:#facc15">Ganti API Key</h3>
<form method="POST">
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input type="password" name="apikey" placeholder="API Key LZPedia baru" required autocomplete="new-password">
<button name="save_api">Simpan & Enkripsi</button>
</form>
</div>

<div class="card" style="margin-top:20px">
<h3 style="margin-top:0;color:#facc15">Transaksi Terbaru</h3>
<table><tr><th>Invoice</th><th>Nominal</th><th>Status</th></tr>
<?php foreach($pdo->query("SELECT invoice_id,amount,status FROM transactions ORDER BY id DESC LIMIT 20")->fetchAll() as $r): ?>
<tr><td><?=h($r['invoice_id'])?></td><td><?=rupiah($r['amount'])?></td><td><?=h($r['status'])?></td></tr>
<?php endforeach; ?>
</table>
</div>
</div></body></html>
PHP

chown -R www-data:www-data "$CORE"
chmod 750 "$CORE"

# Admin awal
CORE_ADMIN_USER="core$(openssl rand -hex 3)"
CORE_ADMIN_PASS=$(openssl rand -base64 15 | tr -d '/+=' | cut -c1-18)
CORE_ADMIN_HASH=$(php -r "echo password_hash('$CORE_ADMIN_PASS', PASSWORD_ARGON2ID);")
mysql renvgk_db -e "INSERT IGNORE INTO core_admins (username,password_hash) VALUES ('$CORE_ADMIN_USER','$CORE_ADMIN_HASH');"

# ---------- 5. Pricing front (halaman publik) ----------
echo -e "${CYAN}[5/9] Halaman pricing...${NC}"
cat > "$WEB/pricing.php" << 'PHP'
<?php
require '../includes/config.php';
$plans = $pdo->query("SELECT * FROM plans WHERE active=1 ORDER BY price")->fetchAll();
function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');}
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Paket RenVGK</title>
<style>
body{margin:0;background:radial-gradient(circle at top,#1e1b4b,#09090d 60%);color:#fff;font-family:system-ui;min-height:100vh}
.wrap{max-width:1100px;margin:0 auto;padding:60px 20px}
h1{text-align:center;font-size:36px;margin:0 0 8px}
.sub{text-align:center;color:#999;margin-bottom:40px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:20px}
.plan{background:#12121a;border:1px solid #26262f;border-radius:18px;padding:28px;position:relative;transition:.2s}
.plan:hover{transform:translateY(-4px);border-color:#facc15}
.plan.featured{border-color:#facc15;box-shadow:0 0 30px rgba(250,204,21,.15)}
.badge{position:absolute;top:-12px;right:20px;background:#facc15;color:#000;font-size:11px;font-weight:800;padding:5px 12px;border-radius:20px}
.plan h2{font-size:22px;margin:0 0 6px;color:#facc15}
.price{font-size:36px;font-weight:800;margin:10px 0 4px}
.price small{font-size:14px;color:#888;font-weight:400}
.desc{color:#aaa;font-size:14px;margin:14px 0 20px;line-height:1.5;min-height:60px}
ul{list-style:none;padding:0;margin:0 0 20px}
li{padding:6px 0;color:#ccc;font-size:14px}
li:before{content:"✓ ";color:#4ade80;font-weight:700}
.btn{display:block;text-align:center;padding:12px;background:#facc15;color:#000;border-radius:10px;text-decoration:none;font-weight:700}
.btn:hover{background:#fde047}
.back{text-align:center;margin-top:40px}
.back a{color:#999;text-decoration:none}
</style></head><body>
<div class="wrap">
<h1>Pilih Paket Kamu</h1>
<p class="sub">Update video terus-menerus. Semua akses instan.</p>
<div class="grid">
<?php foreach($plans as $i => $p):
    $features = [];
    if ($p['code']==='basic') {
        $features = ['Akses 5 hari','Video 1-3 saja','Update 1 video/hari'];
    } elseif ($p['code']==='pro') {
        $features = ['Akses 1 bulan','Hingga 10 video/hari','Semua video terbaru'];
    } else {
        $features = ['Akses 1 tahun (permanen)','Unlimited video','Update terus-menerus','Prioritas support'];
    }
?>
<div class="plan <?=$p['code']==='pro'?'featured':''?>">
<?php if($p['code']==='pro'): ?><div class="badge">POPULER</div><?php endif; ?>
<h2><?=h($p['name'])?></h2>
<div class="price"><?=rupiah($p['price'])?><small> / <?=$p['duration_days']?> hari</small></div>
<div class="desc"><?=h($p['description'])?></div>
<ul><?php foreach($features as $f): ?><li><?=h($f)?></li><?php endforeach; ?></ul>
<a class="btn" href="premium.php?plan=<?=h($p['code'])?>">Pilih <?=h($p['name'])?></a>
</div>
<?php endforeach; ?>
</div>
<div class="back"><a href="index.php">← Kembali</a></div>
</div></body></html>
PHP

# ---------- 6. Helper blur & unlock ----------
echo -e "${CYAN}[6/9] Helper blur & unlock...${NC}"
cat > "$INC/video-access.php" << 'PHP'
<?php
function currentUserId() { return (int)($_SESSION['user_id'] ?? 0); }

function userHasUnlock(PDO $pdo, int $userId, int $videoId): bool {
    if ($userId <= 0) return false;
    $st = $pdo->prepare("SELECT 1 FROM video_unlocks WHERE user_id=? AND video_id=? LIMIT 1");
    $st->execute([$userId, $videoId]);
    return (bool)$st->fetchColumn();
}

function userActivePlan(PDO $pdo, int $userId): ?array {
    if ($userId <= 0) return null;
    $st = $pdo->prepare("SELECT s.*, p.code, p.name, p.video_limit, p.update_limit_per_day, p.duration_days
        FROM user_subscriptions s JOIN plans p ON p.code=s.plan_code
        WHERE s.user_id=? AND s.active=1 AND s.expires_at>NOW()
        ORDER BY s.id DESC LIMIT 1");
    $st->execute([$userId]);
    $r = $st->fetch();
    return $r ?: null;
}

function videoIsUnlocked(PDO $pdo, int $userId, int $videoId): bool {
    if (userHasUnlock($pdo, $userId, $videoId)) return true;
    $plan = userActivePlan($pdo, $userId);
    if (!$plan) return false;
    if ((int)$plan['video_limit'] === 0) return true; // unlimited
    // basic: hanya video 1-3
    if ($plan['code'] === 'basic') return $videoId >= 1 && $videoId <= 3;
    return false;
}

function unlockVideo(PDO $pdo, int $userId, int $videoId): bool {
    $st = $pdo->prepare("INSERT IGNORE INTO video_unlocks (user_id,video_id) VALUES (?,?)");
    return $st->execute([$userId, $videoId]);
}

// CSS blur filter
function videoBlurClass(bool $unlocked): string {
    return $unlocked ? '' : 'video-blur';
}
PHP

cat >> "$WEB/assets/style.css" <<'CSS'

/* RenVGK Blur Paywall */
.video-wrap{position:relative;border-radius:16px;overflow:hidden}
.video-blur{filter:blur(18px) brightness(.6);pointer-events:none;user-select:none}
.lock-overlay{position:absolute;inset:0;display:flex;flex-direction:column;
align-items:center;justify-content:center;background:rgba(9,9,13,.55);
backdrop-filter:blur(4px);color:#fff;text-align:center;padding:20px;z-index:5}
.lock-overlay .lock-icon{font-size:42px;margin-bottom:10px}
.lock-overlay h3{margin:0 0 8px;font-size:18px}
.lock-overlay p{margin:0 0 14px;color:#ccc;font-size:13px;max-width:320px}
.lock-overlay .btn-unlock{padding:10px 22px;background:#facc15;color:#000;
font-weight:700;border-radius:10px;text-decoration:none}
.lock-overlay .btn-unlock:hover{background:#fde047}
CSS

# ---------- 7. Patch video frontend (index.php) ----------
echo -e "${CYAN}[7/9] Patch video frontend...${NC}"

# Cari file yang menampilkan video (index.php / video.php / premium.php)
for VFILE in "$WEB/index.php" "$WEB/video.php"; do
    [[ -f "$VFILE" ]] || continue
    # Backup
    cp "$VFILE" "$VFILE.bak.$(date +%s)"
    # Inject require video-access + helper di atas
    if ! grep -q 'video-access.php' "$VFILE"; then
        python3 - "$VFILE" << 'PY'
import sys, re
path = sys.argv[1]
with open(path, encoding='utf-8') as f: data = f.read()
# Setelah require config.php
data = data.replace(
    "require '../includes/config.php';",
    "require '../includes/config.php';\nrequire '../includes/video-access.php';",
    1
)
with open(path, 'w', encoding='utf-8') as f: f.write(data)
PY
    fi
done

# ---------- 8. Patch premium.php (pricing flow) ----------
echo -e "${CYAN}[8/9] Patch premium flow...${NC}"
if [[ -f "$WEB/premium.php" ]]; then
    cp "$WEB/premium.php" "$WEB/premium.php.bak.$(date +%s)"
    sed -i 's|\$set = \$pdo->query("SELECT apikey FROM settings WHERE id=1")->fetchColumn();|$set = getLzApiKey();|' "$WEB/premium.php" || true
fi

# ---------- 9. Permission & lint ----------
echo -e "${CYAN}[9/9] Permission & lint...${NC}"
chown -R www-data:www-data "$ROOT"
chown root:www-data "$KEYFILE"; chmod 640 "$KEYFILE"
chmod 750 "$INC"; chmod 640 "$INC/config.php"
find "$WEB/uploads/videos" -type d -exec chmod 750 {} \; 2>/dev/null || true
find "$WEB/uploads/videos" -type f -exec chmod 640 {} \; 2>/dev/null || true
chmod 750 "$CORE"

for F in "$INC/config.php" "$INC/core-auth.php" "$INC/video-access.php" \
         "$CORE/login.php" "$CORE/index.php" "$CORE/users.php" "$CORE/plans.php" "$CORE/finance.php" \
         "$WEB/pricing.php"; do
    [[ -f "$F" ]] && php -l "$F" >/dev/null || { echo -e "${RED}Syntax error: $F${NC}"; exit 1; }
done
echo -e "${GREEN}✅ Semua file lolos php -l${NC}"

systemctl reload nginx

# ---------- Ringkasan ----------
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN} RENVGK v3.0 UPDATE SELESAI${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Website     : https://$DOMAIN"
echo "Pricing     : https://$DOMAIN/pricing.php"
echo "User Panel  : https://$DOMAIN/admin/"
echo "Core Panel  : https://$DOMAIN/x-panel-core/login.php"
echo ""
echo -e "${YELLOW}🔐 ADMIN CORE (SIMPAN!)${NC}"
echo " Username : $CORE_ADMIN_USER"
echo " Password : $CORE_ADMIN_PASS"
echo ""
echo -e "${YELLOW}📦 PAKET${NC}"
echo " Basic   : Rp 5.000 / 5 hari   (video 1-3 saja)"
echo " Pro     : Rp 15.000 / 1 bulan (s/d 10 video/hari)"
echo " Promax  : Rp 25.000 / 1 tahun (permanen, update terus)"
echo ""
echo -e "${YELLOW}📝 Backup: $BACKUP_DIR${NC}"
echo -e "${YELLOW}📄 Log   : $LOG${NC}"
echo ""
