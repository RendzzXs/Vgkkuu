#!/bin/bash
# ==================================================
# RenVGK PREMIUM v5.0 - FULL AUTO INSTALL
# Domain : asupanvgkpanel.nebuladnezar.web.id
# ==================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

R='\033[0;31m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
clear
cat <<'BANNER'
   ___              __     __  ______ __
  / _ \___ ___  ___/ /_   / / / / ___// /_
 / , _/ -_) _ \/ _  / _ \/ /_/ / (_ / __/
/_/|_|\__/_//_/\_,_/\___/\__, /\___/_/
                        /____/  PREMIUM v5.0
BANNER

[[ $EUID -eq 0 ]] || { echo -e "${R}Root only!${N}"; exit 1; }
LOG="/var/log/renvgk-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo -e "${R}❌ ERROR baris $LINENO. Log: $LOG${N}"' ERR

# ---------- Domain ----------
DEF="asupanvgkpanel.nebuladnezar.web.id"
read -rp "Domain [$DEF]: " DOMAIN
DOMAIN="${DOMAIN:-$DEF}"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || { echo -e "${R}Domain invalid${N}"; exit 1; }

ROOT="/var/www/$DOMAIN"
WEB="$ROOT/public"; ADMIN="$ROOT/admin"; CORE="$ROOT/x-panel-core"; INC="$ROOT/includes"
KEYDIR="/etc/renvgk"; KEYFILE="$KEYDIR/$DOMAIN.key"

# ==================================================
# 1. DEPENDENCIES
# ==================================================
echo -e "${C}[1/12] Dependency...${N}"
apt-get update -y
apt-get install -y nginx mariadb-server php-fpm php-mysql php-curl php-mbstring \
    php-xml php-zip php-sodium php-gd php-intl openssl curl python3 default-mysql-client unzip
systemctl enable --now nginx mariadb
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHPFPMSVC="php${PHPV}-fpm"
systemctl enable --now "$PHPFPMSVC" 2>/dev/null || systemctl enable --now php-fpm

# ==================================================
# 2. DATABASE
# ==================================================
echo -e "${C}[2/12] Database...${N}"
DB_PASS=$(openssl rand -hex 12)
mysql -e "CREATE DATABASE IF NOT EXISTS renvgk_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'renvgk'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "ALTER USER 'renvgk'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON renvgk_db.* TO 'renvgk'@'localhost'; FLUSH PRIVILEGES;"

mysql renvgk_db <<'SQL'
CREATE TABLE IF NOT EXISTS users (
 id INT AUTO_INCREMENT PRIMARY KEY,
 username VARCHAR(64) NOT NULL UNIQUE,
 email VARCHAR(128) NOT NULL UNIQUE,
 password_hash VARCHAR(255) NOT NULL,
 banned TINYINT(1) DEFAULT 0,
 suspended_until DATETIME NULL,
 created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS settings (
 id INT AUTO_INCREMENT PRIMARY KEY,
 apikey TEXT, site_name VARCHAR(128) DEFAULT 'RenVGK',
 updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT IGNORE INTO settings (id,apikey) VALUES (1,'');

CREATE TABLE IF NOT EXISTS videos (
 id INT AUTO_INCREMENT PRIMARY KEY,
 title VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
 thumb VARCHAR(255) NULL, locked TINYINT(1) DEFAULT 1,
 is_premium TINYINT(1) DEFAULT 1,
 created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS plans (
 id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(32) UNIQUE, name VARCHAR(64),
 price INT, duration_days INT, video_limit INT DEFAULT 3,
 update_limit_per_day INT DEFAULT 1, description TEXT, active TINYINT(1) DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO plans (code,name,price,duration_days,video_limit,update_limit_per_day,description) VALUES
('basic','Basic',5000,5,3,1,'5 hari akses. Video 1-3 saja.'),
('pro','Pro',15000,30,10,1,'1 bulan akses. Sampai 10 video/hari.'),
('promax','Promax',25000,365,0,0,'1 tahun akses. Permanen & update terus.')
ON DUPLICATE KEY UPDATE name=VALUES(name),price=VALUES(price);

CREATE TABLE IF NOT EXISTS transactions (
 id INT AUTO_INCREMENT PRIMARY KEY, user_id INT, invoice_id VARCHAR(64),
 amount INT, status VARCHAR(16) DEFAULT 'pending',
 plan_code VARCHAR(32) NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_subscriptions (
 id INT AUTO_INCREMENT PRIMARY KEY, user_id INT, plan_code VARCHAR(32),
 started_at DATETIME DEFAULT CURRENT_TIMESTAMP, expires_at DATETIME NOT NULL,
 active TINYINT(1) DEFAULT 1, INDEX (user_id,active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS video_unlocks (
 id INT AUTO_INCREMENT PRIMARY KEY, user_id INT, video_id INT,
 unlocked_at DATETIME DEFAULT CURRENT_TIMESTAMP,
 UNIQUE KEY uq_uv (user_id,video_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS core_admins (
 id INT AUTO_INCREMENT PRIMARY KEY, username VARCHAR(64) UNIQUE,
 password_hash VARCHAR(255), last_login DATETIME NULL,
 created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audit_log (
 id INT AUTO_INCREMENT PRIMARY KEY, actor VARCHAR(64), action VARCHAR(128),
 detail TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS fake_stats (
 id INT PRIMARY KEY DEFAULT 1,
 base_users INT DEFAULT 500, base_premium INT DEFAULT 120,
 tick_users_per_min INT DEFAULT 1, tick_premium_per_min INT DEFAULT 1,
 last_tick DATETIME DEFAULT CURRENT_TIMESTAMP, total_ticks INT DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT IGNORE INTO fake_stats (id) VALUES (1);
SQL

# ==================================================
# 3. DIRECTORY & KEY
# ==================================================
echo -e "${C}[3/12] Direktori & key...${N}"
mkdir -p "$WEB/assets" "$WEB/uploads/videos" "$WEB/uploads/thumbs" "$ADMIN" "$CORE" "$INC" "$KEYDIR"
chmod 750 "$KEYDIR"
[[ -f "$KEYFILE" ]] || openssl rand -hex 32 > "$KEYFILE"
chown root:www-data "$KEYFILE"; chmod 640 "$KEYFILE"

# ==================================================
# 4. CONFIG
# ==================================================
echo -e "${C}[4/12] Config PHP...${N}"
cat > "$INC/config.php" << PHP
<?php
declare(strict_types=1);
session_name('RENVGK_USER');
if (session_status() === PHP_SESSION_NONE) {
    session_set_cookie_params([
        'lifetime'=>0,'path'=>'/','secure'=>!empty(\$_SERVER['HTTPS']),
        'httponly'=>true,'samesite'=>'Lax',
    ]);
    session_start();
}
const DB_HOST='localhost'; const DB_NAME='renvgk_db';
const DB_USER='renvgk';    const DB_PASS='$DB_PASS';

try {
    \$pdo = new PDO(
        'mysql:host='.DB_HOST.';dbname='.DB_NAME.';charset=utf8mb4',
        DB_USER, DB_PASS,
        [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]
    );
} catch (Throwable \$e) { http_response_code(500); die('DB error'); }

function h(\$v){return htmlspecialchars((string)\$v,ENT_QUOTES,'UTF-8');}
function rupiah(\$n){return 'Rp '.number_format((int)\$n,0,',','.');}
function formatCompact(int \$n):string{
    if(\$n>=1_000_000_000)return rtrim(rtrim(number_format(\$n/1_000_000_000,1,'.',','),'0'),'.').'M';
    if(\$n>=1_000_000)    return rtrim(rtrim(number_format(\$n/1_000_000,1,'.',','),'0'),'.').'jt';
    if(\$n>=1_000)        return rtrim(rtrim(number_format(\$n/1_000,1,'.',','),'0'),'.').'rb';
    return (string)\$n;
}
function generateCsrf():string{
    if(empty(\$_SESSION['csrf']))\$_SESSION['csrf']=bin2hex(random_bytes(24));
    return \$_SESSION['csrf'];
}
function verifyCsrf(\$t):bool{return !empty(\$_SESSION['csrf'])&&hash_equals(\$_SESSION['csrf'],(string)\$t);}

function currentUser():?array{
    global \$pdo;
    if(empty(\$_SESSION['user_id']))return null;
    \$st=\$pdo->prepare('SELECT * FROM users WHERE id=?'); \$st->execute([\$_SESSION['user_id']]);
    \$u=\$st->fetch(); if(!\$u)return null;
    if((int)\$u['banned']===1)return null;
    if(!empty(\$u['suspended_until'])&&strtotime(\$u['suspended_until'])>time())return null;
    return \$u;
}
function requireUser(){if(!currentUser()){header('Location: /login.php');exit;}}

define('RENVGK_KEY_FILE','$KEYFILE');
function renvgkEncryptionKey(){
    \$k=hex2bin(trim(file_get_contents(RENVGK_KEY_FILE)));
    if(\$k===false||strlen(\$k)!==SODIUM_CRYPTO_SECRETBOX_KEYBYTES)throw new RuntimeException('Key invalid');
    return \$k;
}
function encryptLzApiKey(\$v){
    \$n=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    return 'enc:'.base64_encode(\$n.sodium_crypto_secretbox(\$v,\$n,renvgkEncryptionKey()));
}
function getLzApiKey(){
    global \$pdo;
    \$v=\$pdo->query('SELECT apikey FROM settings WHERE id=1')->fetchColumn();
    if(!\$v)return '';
    if(strpos(\$v,'enc:')!==0)return \$v;
    \$d=base64_decode(substr(\$v,4),true); if(\$d===false)throw new RuntimeException('Cipher invalid');
    \$n=substr(\$d,0,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    \$c=substr(\$d,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    \$r=sodium_crypto_secretbox_open(\$c,\$n,renvgkEncryptionKey());
    if(\$r===false)throw new RuntimeException('Decrypt failed');
    return \$r;
}
function saveLzApiKey(\$v){
    global \$pdo;
    \$pdo->prepare('UPDATE settings SET apikey=? WHERE id=1')->execute([encryptLzApiKey(trim(\$v))]);
}
function lzApiGet(\$ep){
    \$k=getLzApiKey(); if(!\$k)throw new RuntimeException('API Key belum diatur');
    \$ch=curl_init('https://app.lzpedia.my.id/api/'.\$ep.'?apikey='.rawurlencode(\$k));
    curl_setopt_array(\$ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>20,
        CURLOPT_CONNECTTIMEOUT=>10,CURLOPT_SSL_VERIFYPEER=>true,CURLOPT_SSL_VERIFYHOST=>2]);
    \$r=curl_exec(\$ch);
    if(\$r===false){\$e=curl_error(\$ch);curl_close(\$ch);throw new RuntimeException(\$e);}
    \$s=curl_getinfo(\$ch,CURLINFO_HTTP_CODE); curl_close(\$ch);
    if(\$s<200||\$s>=300)throw new RuntimeException('HTTP '.\$s);
    \$j=json_decode(\$r,true); if(!is_array(\$j))throw new RuntimeException('JSON invalid');
    return \$j;
}
function fakeStatsCurrent(PDO \$pdo):array{
    \$row=\$pdo->query("SELECT * FROM fake_stats WHERE id=1")->fetch();
    if(!\$row)return['users'=>0,'premium'=>0];
    \$el=max(0,time()-strtotime(\$row['last_tick']));
    \$t=intdiv(\$el,60);
    if(\$t>0){
        \$pdo->prepare("UPDATE fake_stats SET total_ticks=total_ticks+?, last_tick=DATE_ADD(last_tick,INTERVAL ? MINUTE) WHERE id=1")
            ->execute([\$t,\$t]);
        \$row['total_ticks']=(int)\$row['total_ticks']+\$t;
    }
    \$k=(int)\$row['total_ticks'];
    return['users'=>(int)\$row['base_users']+\$k*(int)\$row['tick_users_per_min'],
           'premium'=>(int)\$row['base_premium']+\$k*(int)\$row['tick_premium_per_min']];
}
function logAction(\$actor,\$action,\$detail=''){
    global \$pdo;
    \$pdo->prepare("INSERT INTO audit_log (actor,action,detail) VALUES (?,?,?)")
        ->execute([\$actor,\$action,\$detail]);
}

require_once __DIR__.'/video-access.php';
require_once __DIR__.'/core-auth.php';
PHP

cat > "$INC/video-access.php" << 'PHP'
<?php
function currentUserId():int{return (int)($_SESSION['user_id']??0);}
function userHasUnlock(PDO $pdo,int $uid,int $vid):bool{
    if($uid<=0)return false;
    $st=$pdo->prepare("SELECT 1 FROM video_unlocks WHERE user_id=? AND video_id=?");
    $st->execute([$uid,$vid]); return (bool)$st->fetchColumn();
}
function userActivePlan(PDO $pdo,int $uid):?array{
    if($uid<=0)return null;
    $st=$pdo->prepare("SELECT s.*,p.code,p.name,p.video_limit,p.update_limit_per_day
        FROM user_subscriptions s JOIN plans p ON p.code=s.plan_code
        WHERE s.user_id=? AND s.active=1 AND s.expires_at>NOW() ORDER BY s.id DESC LIMIT 1");
    $st->execute([$uid]); $r=$st->fetch(); return $r?:null;
}
function videoIsUnlocked(PDO $pdo,int $uid,int $vid):bool{
    if(userHasUnlock($pdo,$uid,$vid))return true;
    $p=userActivePlan($pdo,$uid); if(!$p)return false;
    if((int)$p['video_limit']===0)return true;
    if($p['code']==='basic')return $vid>=1&&$vid<=3;
    return false;
}
function videoBlurClass(bool $u):string{return $u?'':'video-blur';}
PHP

cat > "$INC/core-auth.php" << 'PHP'
<?php
function coreSessionStart(){
    if(session_status()===PHP_SESSION_ACTIVE)return;
    session_name('RENVGK_CORE');
    session_set_cookie_params(['lifetime'=>0,'path'=>'/x-panel-core',
        'secure'=>!empty($_SERVER['HTTPS']),'httponly'=>true,'samesite'=>'Strict']);
    session_start();
}
function coreAdmin(){
    coreSessionStart();
    if(empty($_SESSION['core_admin_id'])){header('Location: login.php');exit;}
}
function coreLogin(PDO $pdo,string $u,string $p):bool{
    coreSessionStart();
    $st=$pdo->prepare("SELECT id,password_hash FROM core_admins WHERE username=?");
    $st->execute([$u]); $r=$st->fetch();
    if(!$r||!password_verify($p,$r['password_hash']))return false;
    session_regenerate_id(true);
    $_SESSION['core_admin_id']=(int)$r['id'];
    $pdo->prepare("UPDATE core_admins SET last_login=NOW() WHERE id=?")->execute([$r['id']]);
    return true;
}
function coreLogout(){coreSessionStart();$_SESSION=[];session_destroy();}
PHP

# ==================================================
# 5. CSS
# ==================================================
echo -e "${C}[5/12] CSS...${N}"
cat > "$WEB/assets/style.css" << 'CSS'
:root{--bg:#09090d;--card:#14141b;--border:#26262f;--txt:#fff;--muted:#999;--gold:#facc15;--green:#4ade80;--red:#fb7185}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--gold);text-decoration:none}
.container{max-width:1280px;margin:0 auto;padding:20px}
.btn{display:inline-block;padding:10px 18px;background:var(--gold);color:#000;font-weight:700;border-radius:10px;border:0;cursor:pointer;font-size:14px}
.btn:hover{background:#fde047}
.btn-block{display:block;width:100%;text-align:center}
input,textarea,select{width:100%;padding:12px;background:#0a0a0f;border:1px solid var(--border);color:var(--txt);border-radius:10px;font-family:inherit;font-size:14px}
input:focus,textarea:focus{outline:none;border-color:var(--gold)}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px}
.navbar{position:sticky;top:0;z-index:50;background:rgba(9,9,13,.85);backdrop-filter:blur(12px);border-bottom:1px solid var(--border)}
.nav-inner{max-width:1280px;margin:0 auto;padding:14px 20px;display:flex;justify-content:space-between;align-items:center;gap:12px}
.logo{font-weight:800;color:var(--gold);letter-spacing:.5px}
.nav-links{display:flex;gap:8px;align-items:center}
.nav-links a{color:var(--muted);font-size:14px;padding:8px 12px;border-radius:8px}
.nav-links a:hover{color:var(--gold);background:#1a1a22}
.vgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
@media(max-width:1200px){.vgrid{grid-template-columns:repeat(3,1fr)}}
@media(max-width:800px){.vgrid{grid-template-columns:repeat(2,1fr)}}
@media(max-width:500px){.vgrid{grid-template-columns:repeat(2,1fr);gap:10px}}
.vcard{background:var(--card);border:1px solid var(--border);border-radius:14px;overflow:hidden;transition:.2s;animation:fadeUp .5s ease both}
.vcard:hover{transform:translateY(-3px);border-color:var(--gold)}
.vcard .thumb{position:relative;aspect-ratio:16/9;background:#000;overflow:hidden}
.vcard .thumb video,.vcard .thumb img{width:100%;height:100%;object-fit:cover;display:block}
.vcard .meta{padding:12px}
.vcard .meta h4{margin:0 0 6px;font-size:14px;line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.vcard .meta small{color:var(--muted);font-size:12px}
@keyframes fadeUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:none}}
.video-wrap{position:relative;border-radius:14px;overflow:hidden;background:#000}
.video-blur{filter:blur(20px) brightness(.5);pointer-events:none;user-select:none;transform:scale(1.05)}
.lock-overlay{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;background:rgba(9,9,13,.4);color:#fff;text-align:center;padding:16px;z-index:5}
.lock-overlay .lock-icon{font-size:38px;margin-bottom:8px}
.lock-overlay h3{margin:0 0 6px;font-size:16px}
.lock-overlay p{margin:0 0 12px;color:#ccc;font-size:12px;max-width:280px}
.lock-overlay .btn-unlock{padding:9px 18px;background:var(--gold);color:#000;font-weight:700;border-radius:10px;font-size:13px}
.admin-nav{position:fixed;top:0;left:0;right:0;height:56px;background:rgba(9,9,13,.9);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 16px;gap:12px;z-index:100}
.hamburger{width:40px;height:40px;display:flex;flex-direction:column;justify-content:center;gap:5px;cursor:pointer;background:transparent;border:0;padding:8px;border-radius:8px}
.hamburger span{display:block;height:3px;background:var(--gold);border-radius:2px;transition:.25s}
.hamburger.open span:nth-child(1){transform:translateY(8px) rotate(45deg)}
.hamburger.open span:nth-child(2){opacity:0}
.hamburger.open span:nth-child(3){transform:translateY(-8px) rotate(-45deg)}
.admin-title{font-weight:800;color:var(--gold)}
.drawer{position:fixed;top:56px;left:0;bottom:0;width:260px;background:#0f0f15;border-right:1px solid var(--border);transform:translateX(-100%);transition:.25s;z-index:99;padding:16px 12px;overflow-y:auto}
.drawer.open{transform:translateX(0)}
.drawer a{display:block;padding:12px 14px;color:#ccc;border-radius:10px;font-size:14px;margin-bottom:4px}
.drawer a:hover{background:#1a1a22;color:var(--gold)}
.drawer a.active{background:#1a1a22;color:var(--gold);font-weight:700}
.drawer .group{font-size:11px;text-transform:uppercase;color:#555;padding:12px 14px 6px;letter-spacing:1px}
.admin-content{padding:76px 20px 20px;transition:.25s}
.admin-content.shift{margin-left:260px}
@media(max-width:768px){.admin-content.shift{margin-left:0}}
.overlay{position:fixed;inset:56px 0 0 0;background:rgba(0,0,0,.5);opacity:0;pointer-events:none;transition:.25s;z-index:98}
.overlay.show{opacity:1;pointer-events:auto}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px}
.stat{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px}
.stat small{color:var(--muted);font-size:12px}
.stat h2{margin:8px 0 0;font-size:22px}
table{width:100%;border-collapse:collapse}
th,td{padding:10px;text-align:left;border-bottom:1px solid var(--border);font-size:13px}
th{color:var(--gold);font-weight:700;background:#1a1a22}
.alert{padding:12px 16px;border-radius:10px;margin-bottom:14px;font-size:14px}
.alert-ok{background:#0f2a1a;border:1px solid #1e5a35;color:var(--green)}
.alert-err{background:#2a0f16;border:1px solid #5a1e2a;color:var(--red)}
.fake-live{display:inline-flex;align-items:center;gap:10px;padding:10px 16px;background:#14141b;border:1px solid #26262f;border-radius:100px;font-size:13px;color:#ccc;margin-bottom:22px}
.fake-live .dot{width:8px;height:8px;background:#4ade80;border-radius:50%;animation:pulse 1.6s infinite}
@keyframes pulse{0%,100%{box-shadow:0 0 0 0 rgba(74,222,128,.6)}50%{box-shadow:0 0 0 8px rgba(74,222,128,0)}}
.faq-item{background:var(--card);border:1px solid var(--border);border-radius:12px;margin-bottom:10px;overflow:hidden}
.faq-q{padding:16px 20px;cursor:pointer;font-weight:600;display:flex;justify-content:space-between;align-items:center;font-size:14px}
.faq-q:after{content:'+';color:var(--gold);font-size:20px;transition:.2s}
.faq-item.open .faq-q:after{transform:rotate(45deg)}
.faq-a{padding:0 20px;max-height:0;overflow:hidden;color:#bbb;font-size:14px;line-height:1.6;transition:.25s}
.faq-item.open .faq-a{max-height:400px;padding:0 20px 16px}
footer{background:#0a0a0f;border-top:1px solid var(--border);padding:30px 20px;margin-top:60px;text-align:center;color:#666;font-size:13px}
footer a{color:var(--gold);margin:0 8px}
CSS

# ==================================================
# 6. USER PAGES
# ==================================================
echo -e "${C}[6/12] User pages...${N}"

cat > "$WEB/index.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
$user=currentUser();
$videos=$pdo->query("SELECT * FROM videos ORDER BY id DESC")->fetchAll();
$fs=fakeStatsCurrent($pdo);
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RenVGK - Video Premium</title>
<link rel="stylesheet" href="assets/style.css">
</head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links">
<a href="pricing.php">Paket</a>
<a href="faq.php">FAQ</a>
<a href="about.php">Tentang</a>
<?php if($user): ?><a href="logout.php">Logout</a>
<?php else: ?><a href="login.php">Login</a>
<a href="register.php" style="background:#facc15;color:#000;font-weight:700">Daftar</a>
<?php endif; ?>
</div></div></nav>
<div class="container">
<div class="fake-live"><span class="dot"></span>
<strong><?=formatCompact($fs['users'])?></strong> pembeli aktif · 
<strong style="color:#facc15"><?=formatCompact($fs['premium'])?></strong> member premium
</div>
<h1 style="margin:14px 0 8px">Video Terbaru</h1>
<p style="color:#999;margin-bottom:24px">Koleksi video premium. Scroll untuk lihat semua.</p>
<?php if(!$videos): ?>
<div class="card" style="text-align:center;padding:60px 20px"><p style="color:#999">Belum ada video.</p></div>
<?php else: ?>
<div class="vgrid">
<?php foreach($videos as $v): $unlocked=videoIsUnlocked($pdo,currentUserId(),(int)$v['id']); ?>
<div class="vcard">
<div class="thumb">
<video class="<?=videoBlurClass($unlocked)?>" src="/uploads/videos/<?=h($v['filename'])?>" preload="metadata" muted playsinline></video>
<?php if(!$unlocked): ?>
<div class="lock-overlay"><div class="lock-icon">🔒</div>
<h3>Video Terkunci</h3><p>Beli paket untuk membuka</p>
<a class="btn-unlock" href="pricing.php">Buka Sekarang</a></div>
<?php else: ?>
<a href="watch.php?id=<?=$v['id']?>" style="position:absolute;inset:0"></a>
<?php endif; ?>
</div>
<div class="meta"><h4><?=h($v['title'])?></h4>
<small><?=h(date('d M Y',strtotime($v['created_at'])))?></small></div>
</div>
<?php endforeach; ?>
</div>
<?php endif; ?>
</div>
<footer>
<a href="about.php">Tentang</a> · <a href="faq.php">FAQ</a> · <a href="pricing.php">Paket</a>
<p style="margin-top:14px">© <?=date('Y')?> RenVGK. All rights reserved.</p>
</footer>
</body></html>
PHP

cat > "$WEB/login.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
if(currentUser()){header('Location: index.php');exit;}
$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $u=trim($_POST['username']??''); $p=$_POST['password']??'';
    $st=$pdo->prepare("SELECT * FROM users WHERE username=? OR email=?");
    $st->execute([$u,$u]); $row=$st->fetch();
    if(!$row||!password_verify($p,$row['password_hash']))$err='Username atau password salah';
    elseif((int)$row['banned']===1)$err='Akun diblokir permanen';
    elseif(!empty($row['suspended_until'])&&strtotime($row['suspended_until'])>time())$err='Akun disuspend sampai '.$row['suspended_until'];
    else{session_regenerate_id(true);$_SESSION['user_id']=(int)$row['id'];header('Location: index.php');exit;}
}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Login</title>
<link rel="stylesheet" href="assets/style.css"></head>
<body style="display:flex;align-items:center;justify-content:center;min-height:100vh">
<form class="card" method="POST" style="width:100%;max-width:380px;margin:20px">
<h2 style="margin:0 0 18px;color:#facc15">Login RenVGK</h2>
<?php if($err):?><div class="alert alert-err"><?=h($err)?></div><?php endif;?>
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input name="username" placeholder="Username / Email" required style="margin-bottom:12px">
<input name="password" type="password" placeholder="Password" required style="margin-bottom:16px">
<button class="btn btn-block">Masuk</button>
<p style="text-align:center;color:#999;margin-top:14px;font-size:13px">Belum punya akun? <a href="register.php">Daftar</a></p>
</form></body></html>
PHP

cat > "$WEB/register.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
if(currentUser()){header('Location: index.php');exit;}
$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $u=trim($_POST['username']??''); $e=trim($_POST['email']??''); $p=$_POST['password']??'';
    if(strlen($u)<3||strlen($u)>32)$err='Username 3-32 karakter';
    elseif(!filter_var($e,FILTER_VALIDATE_EMAIL))$err='Email tidak valid';
    elseif(strlen($p)<6)$err='Password minimal 6 karakter';
    else{
        try{
            $st=$pdo->prepare("INSERT INTO users (username,email,password_hash) VALUES (?,?,?)");
            $st->execute([$u,$e,password_hash($p,PASSWORD_ARGON2ID)]);
            header('Location: login.php');exit;
        }catch(PDOException $ex){$err='Username atau email sudah dipakai';}
    }
}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Daftar</title>
<link rel="stylesheet" href="assets/style.css"></head>
<body style="display:flex;align-items:center;justify-content:center;min-height:100vh">
<form class="card" method="POST" style="width:100%;max-width:380px;margin:20px">
<h2 style="margin:0 0 18px;color:#facc15">Daftar Akun</h2>
<?php if($err):?><div class="alert alert-err"><?=h($err)?></div><?php endif;?>
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input name="username" placeholder="Username" required style="margin-bottom:12px">
<input name="email" type="email" placeholder="Email" required style="margin-bottom:12px">
<input name="password" type="password" placeholder="Password (min 6)" required style="margin-bottom:16px">
<button class="btn btn-block">Daftar</button>
<p style="text-align:center;color:#999;margin-top:14px;font-size:13px">Sudah punya akun? <a href="login.php">Login</a></p>
</form></body></html>
PHP

cat > "$WEB/logout.php" << 'PHP'
<?php require __DIR__.'/../includes/config.php'; $_SESSION=[]; session_destroy(); header('Location: index.php'); exit;
PHP

cat > "$WEB/watch.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
requireUser();
$id=(int)($_GET['id']??0);
$st=$pdo->prepare("SELECT * FROM videos WHERE id=?"); $st->execute([$id]); $v=$st->fetch();
if(!$v){http_response_code(404);die('Video tidak ditemukan');}
if(!videoIsUnlocked($pdo,currentUserId(),$id)){header('Location: pricing.php');exit;}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title><?=h($v['title'])?></title>
<link rel="stylesheet" href="assets/style.css"></head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links"><a href="index.php">← Kembali</a></div></div></nav>
<div class="container" style="max-width:900px">
<h2 style="margin:24px 0 16px"><?=h($v['title'])?></h2>
<div class="video-wrap"><video src="/uploads/videos/<?=h($v['filename'])?>" controls autoplay style="width:100%;display:block"></video></div>
<p style="color:#999;margin-top:14px">Dipublikasikan <?=h($v['created_at'])?></p>
</div></body></html>
PHP

cat > "$WEB/pricing.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
$plans=$pdo->query("SELECT * FROM plans WHERE active=1 ORDER BY price")->fetchAll();
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Paket RenVGK</title><link rel="stylesheet" href="assets/style.css">
<style>.pgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:20px}
.plan{background:#12121a;border:1px solid #26262f;border-radius:18px;padding:28px;position:relative}
.plan.featured{border-color:#facc15;box-shadow:0 0 30px rgba(250,204,21,.15)}
.badge{position:absolute;top:-12px;right:20px;background:#facc15;color:#000;font-size:11px;font-weight:800;padding:5px 12px;border-radius:20px}
.price{font-size:36px;font-weight:800;margin:10px 0}
.price small{font-size:14px;color:#888;font-weight:400}
ul{list-style:none;padding:0;margin:20px 0}
li{padding:6px 0;color:#ccc;font-size:14px}
li:before{content:"✓ ";color:#4ade80;font-weight:700}</style>
</head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links"><a href="index.php">Home</a><a href="faq.php">FAQ</a></div></div></nav>
<div class="container" style="padding:60px 20px">
<h1 style="text-align:center;font-size:36px;margin:0 0 8px">Pilih Paket</h1>
<p style="text-align:center;color:#999;margin-bottom:40px">Update video terus-menerus</p>
<div class="pgrid">
<?php foreach($plans as $p):
$f = $p['code']==='basic'?['Akses 5 hari','Video 1-3 saja','Update 1 video/hari']:
    ($p['code']==='pro'?['Akses 1 bulan','Sampai 10 video/hari','Semua video baru']:
    ['Akses 1 tahun','Unlimited video','Update terus-menerus','Prioritas support']);
?>
<div class="plan <?=$p['code']==='pro'?'featured':''?>">
<?php if($p['code']==='pro'):?><div class="badge">POPULER</div><?php endif;?>
<h2 style="color:#facc15"><?=h($p['name'])?></h2>
<div class="price"><?=rupiah($p['price'])?><small> / <?=$p['duration_days']?> hari</small></div>
<p style="color:#999;font-size:14px"><?=h($p['description'])?></p>
<ul><?php foreach($f as $x):?><li><?=h($x)?></li><?php endforeach;?></ul>
<a class="btn btn-block" href="premium.php?plan=<?=h($p['code'])?>">Pilih <?=h($p['name'])?></a>
</div>
<?php endforeach;?>
</div></div></body></html>
PHP

cat > "$WEB/premium.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
requireUser();
$code=$_GET['plan']??'';
$st=$pdo->prepare("SELECT * FROM plans WHERE code=?"); $st->execute([$code]); $p=$st->fetch();
if(!$p){header('Location: pricing.php');exit;}
$user=currentUser();

if($_SERVER['REQUEST_METHOD']==='POST'){
    try{
        $amount=(int)$p['price'];
        $apiKey=getLzApiKey(); if(!$apiKey)throw new RuntimeException('API Gateway belum diatur admin');
        $invoice='INV-'.strtoupper(bin2hex(random_bytes(5)));
        $ch=curl_init('https://app.lzpedia.my.id/api/invoice/create');
        curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_POST=>true,CURLOPT_TIMEOUT=>20,
            CURLOPT_HTTPHEADER=>['Content-Type: application/json'],
            CURLOPT_POSTFIELDS=>json_encode(['apikey'=>$apiKey,'amount'=>$amount,
                'description'=>'Paket '.$p['name'].' - '.$user['username'],
                'reference'=>$invoice])]);
        $r=curl_exec($ch); curl_close($ch);
        $j=json_decode($r,true);
        if(is_array($j)&&isset($j['payment_url'])){
            $pdo->prepare("INSERT INTO transactions (user_id,invoice_id,amount,status,plan_code) VALUES (?,?,?, 'pending',?)")
                ->execute([$user['id'],$j['reference']??$invoice,$amount,$code]);
            header('Location: '.$j['payment_url']);exit;
        }
        $err='Gagal membuat invoice: '.($j['message']??'unknown');
    }catch(Throwable $e){$err=$e->getMessage();}
}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Checkout</title>
<link rel="stylesheet" href="assets/style.css"></head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links"><a href="pricing.php">← Paket</a></div></div></nav>
<div class="container" style="max-width:480px;padding-top:60px">
<div class="card">
<h2 style="margin:0 0 8px;color:#facc15">Checkout</h2>
<p style="color:#999;margin:0 0 20px">Konfirmasi pembelian paket</p>
<?php if(!empty($err)):?><div class="alert alert-err"><?=h($err)?></div><?php endif;?>
<div style="background:#0a0a0f;padding:16px;border-radius:10px;margin-bottom:20px">
<div style="display:flex;justify-content:space-between;margin-bottom:8px"><span style="color:#999">Paket</span><strong><?=h($p['name'])?></strong></div>
<div style="display:flex;justify-content:space-between;margin-bottom:8px"><span style="color:#999">Durasi</span><strong><?=$p['duration_days']?> hari</strong></div>
<div style="display:flex;justify-content:space-between"><span style="color:#999">Total</span><strong style="color:#facc15"><?=rupiah($p['price'])?></strong></div>
</div>
<form method="POST"><button class="btn btn-block">Bayar Sekarang</button></form>
</div></div></body></html>
PHP

cat > "$WEB/faq.php" << 'PHP'
<?php require __DIR__.'/../includes/config.php'; ?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FAQ</title><link rel="stylesheet" href="assets/style.css"></head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links"><a href="index.php">Home</a><a href="pricing.php">Paket</a><a href="about.php">Tentang</a></div>
</div></nav>
<div class="container" style="max-width:800px;padding:50px 20px">
<h1 style="margin-bottom:24px">FAQ</h1>
<?php $faqs=[
['Apa itu RenVGK?','RenVGK adalah platform video premium dengan update konten terbaru. Semua video di-lock secara otomatis dan hanya bisa dibuka dengan paket aktif.'],
['Bagaimana cara membeli paket?','Klik menu Paket, pilih paket (Basic / Pro / Promax), lalu lakukan pembayaran via gateway LZPedia. Setelah lunas, akses langsung aktif otomatis.'],
['Apa perbedaan tiap paket?','Basic Rp 5.000/5 hari (video 1-3 saja, update 1/hari). Pro Rp 15.000/bulan (sampai 10 video/hari). Promax Rp 25.000/tahun (permanen, unlimited, update terus-menerus).'],
['Apakah bisa ganti password?','Bisa. Hubungi admin via halaman Tentang untuk reset password.'],
['Kenapa video masih blur?','Video blur artinya belum ter-unlock. Pastikan paketmu masih aktif atau video termasuk dalam paket (Basic hanya video 1-3).'],
['Bisa refund?','Tidak. Semua pembelian bersifat final karena konten digital langsung bisa diakses setelah pembayaran.'],
['Metode pembayaran apa?','QRIS, e-wallet, dan virtual account via LZPedia gateway. Semua transaksi aman & terenkripsi.'],
['Berapa lama akses aktif?','Sesuai paket: Basic 5 hari, Pro 30 hari, Promax 365 hari sejak pembayaran terverifikasi.'],
]; foreach($faqs as $f): ?>
<div class="faq-item" onclick="this.classList.toggle('open')">
<div class="faq-q"><?=h($f[0])?></div>
<div class="faq-a"><?=h($f[1])?></div>
</div>
<?php endforeach; ?>
</div></body></html>
PHP

cat > "$WEB/about.php" << 'PHP'
<?php require __DIR__.'/../includes/config.php'; ?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tentang</title><link rel="stylesheet" href="assets/style.css"></head><body>
<nav class="navbar"><div class="nav-inner">
<a class="logo" href="index.php">RENVGK</a>
<div class="nav-links"><a href="index.php">Home</a><a href="pricing.php">Paket</a><a href="faq.php">FAQ</a></div>
</div></nav>
<div class="container" style="max-width:760px;padding:50px 20px">
<h1>Tentang RenVGK</h1>
<div class="card" style="margin-top:20px">
<p style="color:#ccc;line-height:1.8">RenVGK adalah platform streaming video premium yang dirancang untuk memberikan pengalaman menonton terbaik dengan update konten terus-menerus. Setiap video dirancang eksklusif dan dilindungi sistem keamanan berlapis.</p>
<p style="color:#ccc;line-height:1.8">Kami berkomitmen menghadirkan konten berkualitas tinggi dengan sistem pembayaran aman, akses cepat, dan harga terjangkau.</p>
<h3 style="margin-top:24px;color:#facc15">Kenapa pilih RenVGK?</h3>
<ul style="color:#ccc;line-height:1.8">
<li>Update video harian</li>
<li>Sistem pembayaran otomatis 24/7</li>
<li>Enkripsi API key berlapis (Sodium)</li>
<li>Akses instan setelah pembayaran</li>
<li>Support responsif</li>
</ul>
<h3 style="margin-top:24px;color:#facc15">Kontak</h3>
<p style="color:#ccc">Email: <a href="mailto:support@renvgk.id">support@renvgk.id</a></p>
<p style="color:#ccc">Telegram: <a href="#">@renvgk_support</a></p>
</div></div></body></html>
PHP

# ==================================================
# 7. ADMIN (USER PANEL) - BASIC
# ==================================================
echo -e "${C}[7/12] Admin user panel...${N}"
cat > "$ADMIN/index.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
requireUser();
header('Location: /');
exit;
PHP

# ==================================================
# 8. CORE PANEL (/x-panel-core)
# ==================================================
echo -e "${C}[8/12] Core panel...${N}"
chmod 750 "$CORE"

cat > "$CORE/login.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    if(coreLogin($pdo,trim($_POST['username']??''),$_POST['password']??'')){
        header('Location: index.php');exit;
    }
    $err='Login gagal';
}
?>
<!DOCTYPE html><html><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Core Login</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:radial-gradient(circle at top,#1e1b4b,#09090d);color:#fff;font-family:system-ui}
.box{width:100%;max-width:380px;padding:30px;background:#111116;border:1px solid #2a2a35;border-radius:18px}
h1{font-size:20px;margin:0 0 18px;color:#facc15}
input{width:100%;padding:12px;margin-bottom:12px;background:#0a0a0f;border:1px solid #333;color:#fff;border-radius:10px;box-sizing:border-box}
button{width:100%;padding:12px;background:#facc15;color:#000;font-weight:700;border:0;border-radius:10px;cursor:pointer}
.err{color:#fb7185;font-size:13px;margin-bottom:10px}
</style></head><body>
<form class="box" method="POST">
<h1>RENVGK CORE</h1>
<?php if($err):?><div class="err"><?=h($err)?></div><?php endif;?>
<input type="hidden" name="csrf" value="<?=generateCsrf()?>">
<input name="username" placeholder="Username" required autocomplete="username">
<input name="password" type="password" placeholder="Password" required autocomplete="current-password">
<button>Masuk</button>
</form></body></html>
PHP

cat > "$CORE/logout.php" << 'PHP'
<?php require __DIR__.'/../includes/config.php'; coreLogout(); header('Location: login.php'); exit;
PHP

# Layout helper
cat > "$CORE/_layout.php" << 'PHP'
<?php
function coreRender($title,$active,$content){
$nav=[
 'dashboard'=>['index.php','Dashboard','📊'],
 'videos'=>['videos.php','Video','🎬'],
 'users'=>['users.php','Users','👥'],
 'finance'=>['finance.php','Keuangan','💰'],
 'plans'=>['plans.php','Paket','💎'],
 'apikey'=>['apikey.php','API Gateway','🔑'],
 'settings'=>['settings.php','Pengaturan','⚙️'],
];
?>
<!DOCTYPE html><html><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?=h($title)?> - Core</title>
<link rel="stylesheet" href="/assets/style.css">
</head><body>
<div class="admin-nav">
<button class="hamburger" id="hbg" onclick="toggleDrawer()"><span></span><span></span><span></span></button>
<div class="admin-title">RENVGK CORE</div>
</div>
<div class="drawer" id="drawer">
<div class="group">Menu</div>
<?php foreach($nav as $k=>$n): ?>
<a href="<?=$n[0]?>" class="<?=$active===$k?'active':''?>"><?=$n[2]?> <?=$n[1]?></a>
<?php endforeach;?>
<div class="group">Akun</div>
<a href="logout.php">🚪 Logout</a>
</div>
<div class="overlay" id="ovl" onclick="toggleDrawer()"></div>
<div class="admin-content" id="ctn">
<?=$content?>
</div>
<script>
function toggleDrawer(){
  const d=document.getElementById('drawer');
  const c=document.getElementById('ctn');
  const h=document.getElementById('hbg');
  const o=document.getElementById('ovl');
  d.classList.toggle('open');
  c.classList.toggle('shift');
  h.classList.toggle('open');
  o.classList.toggle('show');
}
</script>
</body></html>
<?php }
PHP

# Dashboard
cat > "$CORE/index.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$totalUsers = (int)$pdo->query("SELECT COUNT(*) FROM users")->fetchColumn();
$activeSub  = (int)$pdo->query("SELECT COUNT(*) FROM user_subscriptions WHERE active=1 AND expires_at>NOW()")->fetchColumn();
$totalVids  = (int)$pdo->query("SELECT COUNT(*) FROM videos")->fetchColumn();
$revenue    = (int)$pdo->query("SELECT COALESCE(SUM(amount),0) FROM transactions WHERE status='paid'")->fetchColumn();
$fs = fakeStatsCurrent($pdo);

$content = '
<h1 style="margin:0 0 8px">Dashboard</h1>
<p style="color:#999;margin-bottom:24px">Overview sistem</p>
<div class="grid">
<div class="stat"><small>Total User Real</small><h2>'.number_format($totalUsers).'</h2></div>
<div class="stat"><small>Langganan Aktif</small><h2>'.number_format($activeSub).'</h2></div>
<div class="stat"><small>Total Video</small><h2>'.number_format($totalVids).'</h2></div>
<div class="stat"><small>Pendapatan</small><h2 style="color:#4ade80">'.rupiah($revenue).'</h2></div>
</div>
<div class="card" style="margin-top:20px">
<h3 style="margin:0 0 14px;color:#facc15">📈 Live Counter (Public)</h3>
<p style="color:#999;font-size:13px;margin-bottom:14px">Angka yang dilihat pengunjung di halaman utama.</p>
<div class="grid">
<div class="stat"><small>Pembeli Aktif</small><h2>'.formatCompact($fs['users']).'</h2></div>
<div class="stat"><small>Member Premium</small><h2 style="color:#facc15">'.formatCompact($fs['premium']).'</h2></div>
</div>
<p style="color:#666;font-size:12px;margin-top:12px">+1 user/menit · +1 premium/menit (auto increment)</p>
</div>
<div class="card" style="margin-top:20px">
<h3 style="margin:0 0 14px;color:#facc15">Transaksi Terbaru</h3>
<table><tr><th>Invoice</th><th>Nominal</th><th>Status</th><th>Waktu</th></tr>';
foreach($pdo->query("SELECT invoice_id,amount,status,created_at FROM transactions ORDER BY id DESC LIMIT 8")->fetchAll() as $r){
    $content .= '<tr><td>'.h($r['invoice_id']).'</td><td>'.rupiah($r['amount']).'</td><td>'.h($r['status']).'</td><td>'.h($r['created_at']).'</td></tr>';
}
$content .= '</table></div>';

coreRender('Dashboard','dashboard',$content);
PHP

# Videos management
cat > "$CORE/videos.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$msg='';$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    if(isset($_POST['upload'])){
        $title=trim($_POST['title']??'');
        if(!$title||empty($_FILES['video']['name'])){$err='Judul & file wajib';}
        else{
            $ext=strtolower(pathinfo($_FILES['video']['name'],PATHINFO_EXTENSION));
            if(!in_array($ext,['mp4','webm','mov','mkv'],true)){$err='Format harus mp4/webm/mov/mkv';}
            elseif($_FILES['video']['size']>500*1024*1024){$err='Maks 500MB';}
            else{
                $fn=bin2hex(random_bytes(8)).'.'.$ext;
                $dest=$GLOBALS['WEB'] ?? '/var/www/'.$_SERVER['HTTP_HOST'].'/public';
                $dest.='/uploads/videos/'.$fn;
                if(move_uploaded_file($_FILES['video']['tmp_name'],$dest)){
                    $pdo->prepare("INSERT INTO videos (title,filename,locked,is_premium) VALUES (?,?,1,1)")
                        ->execute([$title,$fn]);
                    logAction('admin','upload_video',$title);
                    $msg='Video diupload & otomatis di-lock';
                }else{$err='Gagal simpan file';}
            }
        }
    }
    if(isset($_POST['toggle'])){
        $id=(int)$_POST['id'];
        $pdo->prepare("UPDATE videos SET locked=1-locked WHERE id=?")->execute([$id]);
        $msg='Status lock diubah';
    }
    if(isset($_POST['delete'])){
        $id=(int)$_POST['id'];
        $st=$pdo->prepare("SELECT filename FROM videos WHERE id=?"); $st->execute([$id]);
        $f=$st->fetchColumn();
        if($f){@unlink('/var/www/'.$_SERVER['HTTP_HOST'].'/public/uploads/videos/'.$f);}
        $pdo->prepare("DELETE FROM videos WHERE id=?")->execute([$id]);
        $msg='Video dihapus';
    }
}

$videos=$pdo->query("SELECT * FROM videos ORDER BY id DESC")->fetchAll();

$content='<h1 style="margin:0 0 8px">Manajemen Video</h1>
<p style="color:#999;margin-bottom:24px">Upload otomatis di-lock (paywall)</p>';
if($msg)$content.='<div class="alert alert-ok">'.h($msg).'</div>';
if($err)$content.='<div class="alert alert-err">'.h($err).'</div>';
$content.='<div class="card" style="margin-bottom:20px">
<h3 style="margin:0 0 14px;color:#facc15">Upload Video Baru</h3>
<form method="POST" enctype="multipart/form-data">
<input type="hidden" name="csrf" value="'.generateCsrf().'">
<input name="title" placeholder="Judul video" required style="margin-bottom:12px">
<input type="file" name="video" accept="video/*" required style="margin-bottom:12px">
<button class="btn" name="upload">Upload (Auto-Lock)</button>
</form></div>
<div class="card"><h3 style="margin:0 0 14px;color:#facc15">Daftar Video ('.count($videos).')</h3>
<div style="overflow-x:auto"><table>
<tr><th>ID</th><th>Judul</th><th>File</th><th>Lock</th><th>Aksi</th></tr>';
foreach($videos as $v){
    $content.='<tr><td>'.$v['id'].'</td><td>'.h($v['title']).'</td><td style="font-size:11px;color:#666">'.h($v['filename']).'</td>
<td>'.((int)$v['locked']?'🔒 Locked':'🔓 Unlocked').'</td>
<td><form method="POST" style="display:inline"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$v['id'].'">
<button class="btn" style="padding:5px 10px;font-size:12px" name="toggle">Toggle</button></form>
<form method="POST" style="display:inline" onsubmit="return confirm(\'Hapus?\')"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$v['id'].'">
<button class="btn" style="padding:5px 10px;font-size:12px;background:#fb7185" name="delete">Hapus</button></form></td></tr>';
}
$content.='</table></div></div>';

coreRender('Video','videos',$content);
PHP

# Users management (ban/suspend/change pass)
cat > "$CORE/users.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$msg='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $id=(int)($_POST['id']??0);
    if(isset($_POST['ban'])){
        $pdo->prepare("UPDATE users SET banned=1-banned WHERE id=?")->execute([$id]);
        logAction('admin','toggle_ban',"user=$id");
        $msg='Ban status diubah';
    }
    if(isset($_POST['suspend'])){
        $days=(int)($_POST['days']??7);
        $pdo->prepare("UPDATE users SET suspended_until=DATE_ADD(NOW(),INTERVAL ? DAY) WHERE id=?")->execute([$days,$id]);
        logAction('admin','suspend',"user=$id days=$days");
        $msg='User disuspend '.$days.' hari';
    }
    if(isset($_POST['unsuspend'])){
        $pdo->prepare("UPDATE users SET suspended_until=NULL WHERE id=?")->execute([$id]);
        $msg='Suspend dicabut';
    }
    if(isset($_POST['change_pass'])){
        $new=trim($_POST['new_pass']??'');
        if(strlen($new)<6){$msg='Password minimal 6 karakter';}
        else{
            $pdo->prepare("UPDATE users SET password_hash=? WHERE id=?")
                ->execute([password_hash($new,PASSWORD_ARGON2ID),$id]);
            logAction('admin','change_pass',"user=$id");
            $msg='Password diubah';
        }
    }
    if(isset($_POST['delete'])){
        $pdo->prepare("DELETE FROM users WHERE id=?")->execute([$id]);
        logAction('admin','delete_user',"user=$id");
        $msg='User dihapus';
    }
}

$users=$pdo->query("SELECT * FROM users ORDER BY id DESC LIMIT 500")->fetchAll();

$content='<h1 style="margin:0 0 8px">Manajemen User</h1>
<p style="color:#999;margin-bottom:24px">Total '.count($users).' user</p>';
if($msg)$content.='<div class="alert alert-ok">'.h($msg).'</div>';
$content.='<div class="card"><div style="overflow-x:auto"><table>
<tr><th>ID</th><th>Username</th><th>Email</th><th>Status</th><th>Aksi</th></tr>';
foreach($users as $u){
    $status='✅ Aktif';
    if((int)$u['banned'])$status='🚫 Banned';
    elseif(!empty($u['suspended_until'])&&strtotime($u['suspended_until'])>time())
        $status='⏸️ Suspend s/d '.date('d M',strtotime($u['suspended_until']));
    $content.='<tr><td>'.$u['id'].'</td><td>'.h($u['username']).'</td><td>'.h($u['email']).'</td><td>'.$status.'</td>
<td style="white-space:nowrap">
<form method="POST" style="display:inline"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$u['id'].'">
<button class="btn" style="padding:4px 8px;font-size:11px" name="ban">'.((int)$u['banned']?'Unban':'Ban').'</button></form>
<form method="POST" style="display:inline"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$u['id'].'"><input type="hidden" name="days" value="7">
<button class="btn" style="padding:4px 8px;font-size:11px;background:#fb923c" name="suspend">Suspend 7d</button></form>
<form method="POST" style="display:inline"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$u['id'].'">
<button class="btn" style="padding:4px 8px;font-size:11px;background:#64748b" name="unsuspend">Copot</button></form>
<form method="POST" style="display:inline"><input type="hidden" name="csrf" value="'.generateCsrf().'"><input type="hidden" name="id" value="'.$u['id'].'">
<input name="new_pass" placeholder="PW baru" style="width:100px;padding:4px;font-size:11px;display:inline-block">
<button class="btn" style="padding:4px 8px;font-size:11px;background:#4ade80;color:#000" name="change_pass">Ganti</button></form>
</td></tr>';
}
$content.='</table></div></div>';

coreRender('Users','users',$content);
PHP

# Finance
cat > "$CORE/finance.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$total=(int)$pdo->query("SELECT COUNT(*) FROM transactions")->fetchColumn();
$paid=(int)$pdo->query("SELECT COUNT(*) FROM transactions WHERE status='paid'")->fetchColumn();
$revenue=(int)$pdo->query("SELECT COALESCE(SUM(amount),0) FROM transactions WHERE status='paid'")->fetchColumn();

$content='<h1 style="margin:0 0 24px">Keuangan</h1>
<div class="grid">
<div class="stat"><small>Total Transaksi</small><h2>'.number_format($total).'</h2></div>
<div class="stat"><small>Paid</small><h2 style="color:#4ade80">'.$paid.'</h2></div>
<div class="stat"><small>Pendapatan</small><h2 style="color:#4ade80">'.rupiah($revenue).'</h2></div>
</div>
<div class="card" style="margin-top:20px"><h3 style="margin:0 0 14px;color:#facc15">20 Transaksi Terbaru</h3>
<div style="overflow-x:auto"><table><tr><th>Invoice</th><th>Amount</th><th>Status</th><th>Waktu</th></tr>';
foreach($pdo->query("SELECT invoice_id,amount,status,created_at FROM transactions ORDER BY id DESC LIMIT 20")->fetchAll() as $r){
    $content.='<tr><td>'.h($r['invoice_id']).'</td><td>'.rupiah($r['amount']).'</td><td>'.h($r['status']).'</td><td>'.h($r['created_at']).'</td></tr>';
}
$content.='</table></div></div>';
coreRender('Keuangan','finance',$content);
PHP

# Plans
cat > "$CORE/plans.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$msg='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $st=$pdo->prepare("UPDATE plans SET price=?,duration_days=?,video_limit=?,update_limit_per_day=?,description=? WHERE code=?");
    $st->execute([(int)$_POST['price'],(int)$_POST['duration_days'],(int)$_POST['video_limit'],
        (int)$_POST['update_limit_per_day'],trim($_POST['description']),$_POST['code']]);
    $msg='Tersimpan';
}
$plans=$pdo->query("SELECT * FROM plans ORDER BY id")->fetchAll();
$content='<h1 style="margin:0 0 24px">Paket</h1>';
if($msg)$content.='<div class="alert alert-ok">'.h($msg).'</div>';
foreach($plans as $p){
    $content.='<form class="card" method="POST" style="margin-bottom:16px">
<input type="hidden" name="csrf" value="'.generateCsrf().'">
<input type="hidden" name="code" value="'.h($p['code']).'">
<h3 style="margin:0 0 14px;color:#facc15">'.h($p['name']).' ('.h($p['code']).')</h3>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px">
<div><label style="font-size:12px;color:#999">Harga</label><input name="price" type="number" value="'.$p['price'].'"></div>
<div><label style="font-size:12px;color:#999">Durasi (hari)</label><input name="duration_days" type="number" value="'.$p['duration_days'].'"></div>
<div><label style="font-size:12px;color:#999">Limit Video (0=∞)</label><input name="video_limit" type="number" value="'.$p['video_limit'].'"></div>
<div><label style="font-size:12px;color:#999">Update/hari</label><input name="update_limit_per_day" type="number" value="'.$p['update_limit_per_day'].'"></div>
</div>
<div style="margin-top:12px"><label style="font-size:12px;color:#999">Deskripsi</label><textarea name="description" rows="2">'.h($p['description']).'</textarea></div>
<button class="btn" style="margin-top:12px">Simpan</button>
</form>';
}
coreRender('Paket','plans',$content);
PHP

# API Key
cat > "$CORE/apikey.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$msg='';$err='';$balance=null;$apiErr='';
if($_SERVER['REQUEST_METHOD']==='POST'&&isset($_POST['save'])){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $k=trim($_POST['apikey']??'');
    if(strlen($k)<10||strlen($k)>500)$err='API Key invalid';
    else{try{saveLzApiKey($k);$msg='API Key tersimpan (encrypted)';}catch(Throwable $e){$err='Gagal: '.$e->getMessage();}}
}
if(getLzApiKey()){
    try{$balance=lzApiGet('balance');}catch(Throwable $e){$apiErr=$e->getMessage();}
}
$content='<h1 style="margin:0 0 24px">API Gateway LZPedia</h1>';
if($msg)$content.='<div class="alert alert-ok">'.h($msg).'</div>';
if($err)$content.='<div class="alert alert-err">'.h($err).'</div>';
if($balance&&isset($balance['balance'])){
    $content.='<div class="card" style="margin-bottom:20px"><h3 style="margin:0 0 12px;color:#facc15">Saldo Gateway</h3>
<p style="font-size:24px;font-weight:800;color:#4ade80">'.rupiah($balance['balance']).'</p>
<p style="color:#999">User: '.h($balance['username']??'-').' | Email: '.h($balance['email']??'-').'</p></div>';
}
if($apiErr)$content.='<div class="alert alert-err">API: '.h($apiErr).'</div>';
$content.='<div class="card"><h3 style="margin:0 0 12px;color:#facc15">Ganti API Key</h3>
<p style="color:#999;font-size:13px;margin-bottom:14px">Disimpan terenkripsi (Sodium secretbox). Kunci di luar public_html.</p>
<form method="POST"><input type="hidden" name="csrf" value="'.generateCsrf().'">
<input type="password" name="apikey" placeholder="API Key baru" required autocomplete="new-password">
<button class="btn" style="margin-top:12px" name="save">Simpan & Enkripsi</button>
</form></div>';
coreRender('API Gateway','apikey',$content);
PHP

# Settings (fake stats control)
cat > "$CORE/settings.php" << 'PHP'
<?php
require __DIR__.'/../includes/config.php';
require __DIR__.'/_layout.php';
coreAdmin();

$msg='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!verifyCsrf($_POST['csrf']??''))die('CSRF');
    $pdo->prepare("UPDATE fake_stats SET base_users=?,base_premium=?,tick_users_per_min=?,tick_premium_per_min=? WHERE id=1")
        ->execute([(int)$_POST['base_users'],(int)$_POST['base_premium'],
            (int)$_POST['tick_users'],(int)$_POST['tick_premium']]);
    $msg='Tersimpan';
}
$fs=$pdo->query("SELECT * FROM fake_stats WHERE id=1")->fetch();
$content='<h1 style="margin:0 0 24px">Pengaturan</h1>';
if($msg)$content.='<div class="alert alert-ok">'.h($msg).'</div>';
$content.='<form class="card" method="POST">
<h3 style="margin:0 0 14px;color:#facc15">📈 Live Counter (Fake Stats)</h3>
<p style="color:#999;font-size:13px;margin-bottom:14px">Angka ini tampil di halaman publik. Real stat Anda tetap ada di dashboard (khusus admin).</p>
<input type="hidden" name="csrf" value="'.generateCsrf().'">
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px">
<div><label style="font-size:12px;color:#999">Base Users</label><input name="base_users" type="number" value="'.$fs['base_users'].'"></div>
<div><label style="font-size:12px;color:#999">Base Premium</label><input name="base_premium" type="number" value="'.$fs['base_premium'].'"></div>
<div><label style="font-size:12px;color:#999">+Users/menit</label><input name="tick_users" type="number" value="'.$fs['tick_users_per_min'].'"></div>
<div><label style="font-size:12px;color:#999">+Premium/menit</label><input name="tick_premium" type="number" value="'.$fs['tick_premium_per_min'].'"></div>
</div>
<button class="btn" style="margin-top:12px">Simpan</button>
</form>';
coreRender('Pengaturan','settings',$content);
PHP

# Create admin
CORE_USER="core$(openssl rand -hex 3)"
CORE_PASS=$(openssl rand -base64 15 | tr -d '/+=' | cut -c1-18)
CORE_HASH=$(php -r "echo password_hash('$CORE_PASS', PASSWORD_ARGON2ID);")
mysql renvgk_db -e "INSERT IGNORE INTO core_admins (username,password_hash) VALUES ('$CORE_USER','$CORE_HASH');"

# ==================================================
# 9. NGINX VHOST
# ==================================================
echo -e "${C}[9/12] Nginx vhost...${N}"
cat > "/etc/nginx/sites-available/$DOMAIN" << NGINX
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB;
    index index.php;

    client_max_body_size 500M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
        fastcgi_read_timeout 300;
    }
    location ~ /\. { deny all; }
    location ~* \.(mp4|webm|mov|mkv)\$ {
        add_header Accept-Ranges bytes;
    }
}
NGINX
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# SSL (try certbot if available)
if command -v certbot >/dev/null; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect || echo -e "${Y}SSL gagal (lanjut HTTP)${N}"
fi

# ==================================================
# 10. SEED DEMO VIDEO (opsional)
# ==================================================
echo -e "${C}[10/12] Seed video placeholder...${N}"
DEMO_DIR="$WEB/uploads/videos"
mkdir -p "$DEMO_DIR"
if command -v ffmpeg >/dev/null; then
    for i in 1 2 3 4 5; do
        [[ -f "$DEMO_DIR/demo$i.mp4" ]] || \
            ffmpeg -f lavfi -i "color=c=0x14141b:s=640x360:d=3" -vf "drawtext=text='Demo Video $i':fontcolor=#facc15:fontsize=48:x=(w-text_w)/2:y=(h-text_h)/2" \
                -c:v libx264 -t 3 -pix_fmt yuv420p "$DEMO_DIR/demo$i.mp4" -y 2>/dev/null || true
    done
fi
for i in 1 2 3 4 5; do
    [[ -f "$DEMO_DIR/demo$i.mp4" ]] && \
        mysql renvgk_db -e "INSERT IGNORE INTO videos (id,title,filename,locked,is_premium) VALUES ($i,'Demo Video $i','demo$i.mp4',1,1);" || true
done

# ==================================================
# 11. PERMISSIONS
# ==================================================
echo -e "${C}[11/12] Permissions...${N}"
chown -R www-data:www-data "$ROOT"
chmod 750 "$INC" "$CORE"
chmod 640 "$INC/config.php"
chmod 750 "$WEB/uploads/videos" "$WEB/uploads/thumbs"
find "$WEB/uploads" -type f -exec chmod 640 {} \;
chown root:www-data "$KEYFILE"; chmod 640 "$KEYFILE"

# ==================================================
# 12. LINT & SELESAI
# ==================================================
echo -e "${C}[12/12] Lint...${N}"
for F in "$INC/config.php" "$INC/video-access.php" "$INC/core-auth.php" \
         "$WEB/index.php" "$WEB/login.php" "$WEB/register.php" "$WEB/logout.php" \
         "$WEB/watch.php" "$WEB/pricing.php" "$WEB/premium.php" "$WEB/faq.php" "$WEB/about.php" \
         "$CORE/login.php" "$CORE/logout.php" "$CORE/_layout.php" "$CORE/index.php" \
         "$CORE/videos.php" "$CORE/users.php" "$CORE/finance.php" "$CORE/plans.php" \
         "$CORE/apikey.php" "$CORE/settings.php"; do
    php -l "$F" >/dev/null 2>&1 || { echo -e "${R}❌ Syntax: $F${N}"; php -l "$F"; exit 1; }
done
echo -e "${G}✅ Semua file lolos php -l${N}"

systemctl reload nginx

echo ""
echo -e "${G}===========================================${N}"
echo -e "${G} 🎉 RENVGK v5.0 INSTALL SELESAI${N}"
echo -e "${G}===========================================${N}"
echo ""
echo "🌐 Website     : http://$DOMAIN"
echo "💎 Pricing     : http://$DOMAIN/pricing.php"
echo "❓ FAQ         : http://$DOMAIN/faq.php"
echo "ℹ️  Tentang     : http://$DOMAIN/about.php"
echo "🔐 Core Panel  : http://$DOMAIN/x-panel-core/login.php"
echo ""
echo -e "${Y}━━━ ADMIN CORE LOGIN (SIMPAN!) ━━━${N}"
echo " Username : $CORE_USER"
echo " Password : $CORE_PASS"
echo ""
echo -e "${Y}━━━ PAKET ━━━${N}"
echo " Basic   : Rp 5.000  / 5 hari   (video 1-3 saja)"
echo " Pro     : Rp 15.000 / 1 bulan  (sampai 10 video/hari)"
echo " Promax  : Rp 25.000 / 1 tahun  (permanen, update terus)"
echo ""
echo -e "${Y}━━━ LANGKAH SELANJUTNYA ━━━${N}"
echo " 1. Login ke /x-panel-core/"
echo " 2. Menu API Gateway → masukkan API Key LZPedia"
echo " 3. Menu Video → upload video (auto-lock)"
echo " 4. Cek Dashboard → live counter (fake) + real stats"
echo " 5. Test pembelian di /pricing.php"
echo ""
echo -e "${Y}━━━ CATATAN ━━━${N}"
echo " • Fake counter: +1 user & +1 premium/menit otomatis."
echo " • Angka nyata hanya terlihat di dashboard admin."
echo " • User biasa tidak bisa lihat real stats."
echo " • Ubah fake stats di: /x-panel-core/settings.php"
echo " • Backup DB: mysqldump renvgk_db > backup.sql"
echo " • Log install: $LOG"
echo ""
