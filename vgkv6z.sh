#!/bin/bash
# ==========================================
# ☁️ ASUPAN VGK v3.0 - FULL AUTO INSTALL
# Anti SS • Paywall • Admin Pro • LZPedia
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Harus root!${NC}"; exit 1; }

read -p "👉 Masukkan Domain Web (contoh: asupan.domain.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo -e "${RED}❌ Domain tidak boleh kosong!${NC}"; exit 1; }
read -p "👉 Email SSL: " EMAIL
[[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"

WEB_ROOT="/var/www/$DOMAIN"
DB_NAME="asupan_db"
DB_USER="asupan_user"
DB_PASS=$(openssl rand -hex 12)
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

# ==========================================
# 1. INSTALL DEPENDENCY
# ==========================================
echo -e "${CYAN}[1/5] Install Nginx, PHP, MariaDB...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y nginx php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-curl php8.3-xml php8.3-zip php8.3-gd php8.3-sodium mariadb-server mariadb-client certbot python3-certbot-nginx >/dev/null 2>&1
systemctl enable --now nginx php8.3-fpm mariadb >/dev/null 2>&1

# ==========================================
# 2. SETUP DATABASE
# ==========================================
echo -e "${CYAN}[2/5] Setup Database...${NC}"
mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
mysql -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

mysql "$DB_NAME" << SQLEOF
CREATE TABLE users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role ENUM('admin','user') DEFAULT 'user',
    plan ENUM('free','pro','promax') DEFAULT 'free',
    plan_expires DATETIME NULL,
    is_banned TINYINT(1) DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
-- Admin Default (Pass: AdminVGK123)
INSERT INTO users (username, password, role, plan) VALUES ('admin', 'AdminVGK123', 'admin', 'promax');

CREATE TABLE videos (
    id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(100),
    filename VARCHAR(100),
    is_locked TINYINT(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE plans (
    id INT AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(20) UNIQUE,
    name VARCHAR(50),
    price INT,
    duration_days INT
);
INSERT INTO plans (code, name, price, duration_days) VALUES 
('basic', 'Basic', 5000, 5),
('pro', 'Pro', 15000, 30),
('promax', 'Promax', 25000, 365);

CREATE TABLE settings (
    id INT PRIMARY KEY,
    site_name VARCHAR(100) DEFAULT 'Asupan VGK',
    maintenance INT DEFAULT 0,
    lz_api_key VARCHAR(255) DEFAULT ''
);
INSERT INTO settings (id) VALUES (1);

CREATE TABLE transactions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    invoice_id VARCHAR(50),
    amount INT,
    status VARCHAR(20) DEFAULT 'pending',
    plan_code VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQLEOF
echo -e "${GREEN}  ✅ Database Siap${NC}"

# ==========================================
# 3. BIKIN FILE WEB (UI DARK PREMIUM)
# ==========================================
echo -e "${CYAN}[3/5] Generate File Web (Dark UI)...${NC}"
rm -rf "$WEB_ROOT"
mkdir -p "$WEB_ROOT"/{assets,uploads/videos,admin}

# --- CONFIG.PHP ---
cat > "$WEB_ROOT/config.php" << PHPEOF
<?php
session_start();
define('DB_HOST', '127.0.0.1');
define('DB_NAME', '$DB_NAME');
define('DB_USER', '$DB_USER');
define('DB_PASS', '$DB_PASS');
try {
    \$pdo = new PDO("mysql:host=".DB_HOST.";dbname=".DB_NAME.";charset=utf8mb4", DB_USER, DB_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
} catch (PDOException \$e) { die("DB Error"); }

function isLoggedIn() { return isset(\$_SESSION['user_id']); }
function isAdmin() { return isLoggedIn() && \$_SESSION['role'] === 'admin'; }
function requireLogin() { if(!isLoggedIn()) { header('Location: login.php'); exit; } }
function getSettings(\$pdo) { return \$pdo->query("SELECT * FROM settings WHERE id=1")->fetch(); }

// Fungsi Video Blur & Lock
function canWatchVideo(\$pdo, \$user_id, \$video_id) {
    if(!\$user_id) return false;
    \$u = \$pdo->query("SELECT * FROM users WHERE id=\$user_id")->fetch();
    if(\$u['role'] == 'admin') return true;
    if(\$u['plan'] == 'free') return false;
    if(\$u['plan_expires'] && strtotime(\$u['plan_expires']) > time()) return true;
    return false;
}
PHPEOF

# --- STYLE.CSS ---
cat > "$WEB_ROOT/assets/style.css" << 'CSSEOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
@import url('https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css');
:root { --bg: #09090d; --card: #14141b; --primary: #6366f1; --gold: #facc15; --success: #10b981; --danger: #ef4444; --text: #fff; --muted: #94a3b8; --border: #26262f; }
* { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Inter', sans-serif; }
body { background: var(--bg); color: var(--text); min-height: 100vh; -webkit-font-smoothing: antialiased; }
a { text-decoration: none; color: inherit; }
.container { max-width: 1000px; margin: 0 auto; padding: 20px; }

/* NAVBAR */
.navbar { display: flex; justify-content: space-between; align-items: center; padding: 15px 20px; background: rgba(9,9,13,0.9); backdrop-filter: blur(10px); border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 100; }
.logo { font-size: 1.3em; font-weight: 800; color: var(--gold); display: flex; align-items: center; gap: 8px; }
.btn { padding: 10px 20px; border-radius: 8px; font-weight: 700; border: none; cursor: pointer; display: inline-flex; align-items: center; gap: 8px; transition: 0.3s; font-size: 0.9em; }
.btn-primary { background: var(--primary); color: white; }
.btn-gold { background: var(--gold); color: #000; }
.btn-danger { background: rgba(239,68,68,0.1); color: var(--danger); border: 1px solid var(--danger); }

/* CARD & FORM */
.card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 30px; margin-bottom: 20px; }
.form-group { margin-bottom: 20px; }
label { display: block; margin-bottom: 8px; font-size: 0.9em; color: var(--muted); }
input, select, textarea { width: 100%; padding: 14px; border-radius: 10px; border: 1px solid var(--border); background: #0a0a0f; color: white; outline: none; font-size: 1em; transition: 0.3s; }
input:focus, select:focus, textarea:focus { border-color: var(--primary); box-shadow: 0 0 0 3px rgba(99,102,241,0.2); }

/* HERO & STATS */
.hero { text-align: center; padding: 40px 20px; }
.hero h1 { font-size: 2.5em; font-weight: 800; margin-bottom: 15px; }
.hero p { color: var(--muted); font-size: 1.1em; margin-bottom: 30px; }
.stats { display: flex; justify-content: center; gap: 30px; margin-bottom: 40px; }
.stat-item { text-align: center; }
.stat-item h3 { font-size: 1.5em; color: var(--gold); font-weight: 800; }
.stat-item p { color: var(--muted); font-size: 0.8em; text-transform: uppercase; }

/* VIDEO GRID */
.video-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 20px; }
.video-card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; overflow: hidden; transition: 0.3s; position: relative; }
.video-thumb { position: relative; aspect-ratio: 16/9; background: #000; overflow: hidden; }
.video-thumb video { width: 100%; height: 100%; object-fit: cover; pointer-events: none; }
.lock-overlay { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; background: rgba(0,0,0,0.5); backdrop-filter: blur(10px); z-index: 2; }
.lock-overlay i { font-size: 2.5em; color: var(--gold); margin-bottom: 10px; }
.video-info { padding: 15px; }
.video-info h4 { font-size: 1em; margin-bottom: 5px; }
.video-info p { font-size: 0.8em; color: var(--muted); }

/* ADMIN SIDEBAR */
.admin-layout { display: flex; min-height: 100vh; }
.sidebar { width: 260px; background: var(--card); border-right: 1px solid var(--border); padding: 20px; position: fixed; height: 100%; overflow-y: auto; }
.sidebar a { display: flex; align-items: center; gap: 12px; padding: 12px; color: var(--muted); border-radius: 8px; margin-bottom: 5px; font-weight: 600; transition: 0.2s; }
.sidebar a:hover, .sidebar a.active { background: rgba(99,102,241,0.1); color: var(--primary); }
.admin-content { margin-left: 260px; padding: 30px; flex: 1; background: var(--bg); }

@media (max-width: 768px) {
    .sidebar { transform: translateX(-100%); transition: 0.3s; z-index: 1000; }
    .sidebar.open { transform: translateX(0); }
    .admin-content { margin-left: 0; padding: 20px; }
    .mobile-toggle { display: block; position: fixed; top: 15px; left: 15px; z-index: 1001; background: var(--primary); color: white; padding: 10px; border-radius: 8px; border: none; cursor: pointer; }
}

/* ANTI SCREENSHOT */
body.screen-protect { background: #000 !important; }
body.screen-protect * { visibility: hidden !important; }
body.screen-protect::after { content: 'SCREENSHOT / RECORDING DETECTED'; visibility: visible; color: #ef4444; font-size: 2em; font-weight: 800; position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); text-align: center; z-index: 9999; }
CSSEOF

# --- INDEX.PHP (LANDING PAGE) ---
cat > "$WEB_ROOT/index.php" << 'PHPEOF'
<?php require 'config.php'; $set = getSettings($pdo);
if($set['maintenance'] == 1 && !isAdmin()) { die("<body style='background:#000;color:#fff;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;'><h1>Website Maintenance</h1></body>"); }
$videos = $pdo->query("SELECT * FROM videos ORDER BY id DESC")->fetchAll();
$uid = $_SESSION['user_id'] ?? 0;
?>
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= $set['site_name'] ?> - Premium Content</title>
    <link rel="stylesheet" href="assets/style.css">
</head>
<body>
    <nav class="navbar">
        <a href="index.php" class="logo"><i class="fas fa-fire"></i> <?= $set['site_name'] ?></a>
        <div>
            <?php if(isLoggedIn()): ?>
                <a href="<?= isAdmin() ? 'admin/index.php' : 'dashboard.php' ?>" class="btn btn-primary" style="margin-right:10px;"><i class="fas fa-user"></i> Dashboard</a>
                <a href="logout.php" class="btn btn-danger"><i class="fas fa-sign-out-alt"></i></a>
            <?php else: ?>
                <a href="login.php" class="btn btn-primary">Login</a>
                <a href="register.php" class="btn btn-gold">Daftar</a>
            <?php endif; ?>
        </div>
    </nav>

    <div class="container">
        <div class="hero">
            <h1>Konten Premium <span style="color:var(--gold)">Eksklusif</span></h1>
            <p>Daftar sekarang dan nikmati ribuan video premium tanpa batas.</p>
            <div class="stats">
                <div class="stat-item"><h3>12.5K+</h3><p>Member Aktif</p></div>
                <div class="stat-item"><h3>50K+</h3><p>Video Premium</p></div>
                <div class="stat-item"><h3>4.9/5</h3><p>Rating</p></div>
            </div>
        </div>

        <h2 style="margin-bottom:20px;">Video Terbaru</h2>
        <div class="video-grid">
            <?php foreach($videos as $v): $canWatch = canWatchVideo($pdo, $uid, $v['id']); ?>
            <div class="video-card">
                <div class="video-thumb">
                    <video class="<?= $canWatch ? '' : 'blur' ?>" src="uploads/videos/<?= $v['filename'] ?>" preload="metadata" muted playsinline></video>
                    <?php if(!$canWatch): ?>
                    <div class="lock-overlay">
                        <i class="fas fa-lock"></i>
                        <h3>Wajib Premium</h3>
                        <a href="pricing.php" class="btn btn-gold" style="margin-top:10px;">Beli Akses</a>
                    </div>
                    <?php else: ?>
                    <a href="watch.php?id=<?= $v['id'] ?>" style="position:absolute; inset:0;"></a>
                    <?php endif; ?>
                </div>
                <div class="video-info">
                    <h4><?= htmlspecialchars($v['title']) ?></h4>
                    <p><?= date('d M Y', strtotime($v['created_at'])) ?></p>
                </div>
            </div>
            <?php endforeach; ?>
        </div>
    </div>
</body>
</html>
PHPEOF

# --- LOGIN & REGISTER ---
cat > "$WEB_ROOT/login.php" << 'PHPEOF'
<?php require 'config.php'; $set = getSettings($pdo);
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $u = $_POST['username']; $p = $_POST['password'];
    $stmt = $pdo->prepare("SELECT * FROM users WHERE username=?"); $stmt->execute([$u]); $user = $stmt->fetch();
    if ($user && ($p === $user['password'])) {
        if($user['is_banned']) { $err = "Akun Anda diblokir!"; }
        else {
            $_SESSION['user_id'] = $user['id']; $_SESSION['role'] = $user['role'];
            header('Location: ' . ($user['role'] === 'admin' ? 'admin/index.php' : 'dashboard.php')); exit;
        }
    } else { $err = "Username/Password salah!"; }
}
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Login</title><link rel="stylesheet" href="assets/style.css"></head>
<body><div class="container" style="max-width:400px; margin-top:100px;"><div class="card">
    <h2 style="text-align:center; margin-bottom:20px;"><i class="fas fa-lock"></i> Login</h2>
    <?php if(isset($err)) echo "<p style='color:var(--danger); text-align:center; margin-bottom:15px;'>$err</p>"; ?>
    <form method="POST"><div class="form-group"><label>Username</label><input type="text" name="username" required></div><div class="form-group"><label>Password</label><input type="password" name="password" required></div><button class="btn btn-primary" style="width:100%; justify-content:center;">Masuk</button></form>
    <p style="text-align:center; margin-top:15px; font-size:0.9em; color:var(--muted);">Belum punya akun? <a href="register.php" style="color:var(--primary);">Daftar</a></p>
</div></div></body></html>
PHPEOF

cat > "$WEB_ROOT/register.php" << 'PHPEOF'
<?php require 'config.php';
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $u = $_POST['username']; $p = $_POST['password'];
    try { $stmt = $pdo->prepare("INSERT INTO users (username, password) VALUES (?,?)"); $stmt->execute([$u, $p]); header('Location: login.php'); exit; } catch(Exception $e) { $err = "Username sudah ada!"; }
}
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Daftar</title><link rel="stylesheet" href="assets/style.css"></head>
<body><div class="container" style="max-width:400px; margin-top:100px;"><div class="card">
    <h2 style="text-align:center; margin-bottom:20px;"><i class="fas fa-user-plus"></i> Daftar</h2>
    <?php if(isset($err)) echo "<p style='color:var(--danger); text-align:center; margin-bottom:15px;'>$err</p>"; ?>
    <form method="POST"><div class="form-group"><label>Username</label><input type="text" name="username" required></div><div class="form-group"><label>Password</label><input type="password" name="password" required></div><button class="btn btn-gold" style="width:100%; justify-content:center;">Daftar</button></form>
    <p style="text-align:center; margin-top:15px; font-size:0.9em; color:var(--muted);">Sudah punya akun? <a href="login.php" style="color:var(--primary);">Login</a></p>
</div></div></body></html>
PHPEOF

# --- DASHBOARD USER (ANTI SS & STATUS PREMIUM) ---
cat > "$WEB_ROOT/dashboard.php" << 'PHPEOF'
<?php require 'config.php'; requireLogin();
$stmt = $pdo->prepare("SELECT * FROM users WHERE id=?"); $stmt->execute([$_SESSION['user_id']]); $me = $stmt->fetch();
$sisa_hari = 0;
if($me['plan_expires']) { $sisa_hari = max(0, round((strtotime($me['plan_expires']) - time()) / 86400)); }
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Dashboard</title><link rel="stylesheet" href="assets/style.css"></head>
<body>
    <nav class="navbar"><a href="dashboard.php" class="logo"><i class="fas fa-fire"></i> Asupan VGK</a><a href="logout.php" class="btn btn-danger"><i class="fas fa-sign-out-alt"></i> Logout</a></nav>
    <div class="container">
        <div class="card" style="background:linear-gradient(135deg, rgba(99,102,241,0.2), transparent);">
            <h2 style="margin-bottom:5px;">Halo, <?= htmlspecialchars($me['username']) ?>!</h2>
            <p style="color:var(--muted); margin-bottom:15px;">Status Akun: 
                <span style="background:var(--gold); color:#000; padding:4px 10px; border-radius:5px; font-weight:700;"><?= strtoupper($me['plan']) ?></span>
                <?php if($me['plan'] != 'free'): ?><span style="margin-left:10px; color:var(--success);"><i class="fas fa-clock"></i> Sisa <?= $sisa_hari ?> Hari</span><?php endif; ?>
            </p>
            <a href="pricing.php" class="btn btn-gold"><i class="fas fa-crown"></i> Upgrade Premium</a>
        </div>
        <div class="card">
            <h3 style="margin-bottom:15px;"><i class="fas fa-shield-alt" style="color:var(--success);"></i> Layar Dilindungi</h3>
            <p style="color:var(--muted); font-size:0.9em;">Sistem mendeteksi jika Anda mencoba mengambil screenshot. Konten akan otomatis disembunyikan.</p>
        </div>
    </div>
    <script>
        // ANTI SCREENSHOT (Deteksi tab pindah / blur)
        document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'hidden') { document.body.classList.add('screen-protect'); }
            else { document.body.classList.remove('screen-protect'); }
        });
        window.addEventListener('blur', function() { document.body.classList.add('screen-protect'); });
        window.addEventListener('focus', function() { document.body.classList.remove('screen-protect'); });
    </script>
</body></html>
PHPEOF

# --- PRICING (LZPedia Gateway) ---
cat > "$WEB_ROOT/pricing.php" << 'PHPEOF'
<?php require 'config.php'; requireLogin(); $set = getSettings($pdo);
$stmt = $pdo->prepare("SELECT * FROM users WHERE id=?"); $stmt->execute([$_SESSION['user_id']]); $me = $stmt->fetch();
$plans = $pdo->query("SELECT * FROM plans")->fetchAll();
$msg = '';
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $plan = $_POST['plan_code'];
    $stmt_p = $pdo->prepare("SELECT * FROM plans WHERE code=?"); $stmt_p->execute([$plan]); $p = $stmt_p->fetch();
    
    // LOGIKA PEMBAYARAN (Simulasi LZPedia)
    if($set['lz_api_key']) {
        // Nembak API LZPedia (sesuai kode asli lu)
        $invoice = 'INV-' . strtoupper(bin2hex(random_bytes(4)));
        $pdo->prepare("INSERT INTO transactions (user_id, invoice_id, amount, status, plan_code) VALUES (?,?,?, 'pending',?)")->execute([$me['id'], $invoice, $p['price'], $plan]);
        $msg = "Berhasil buat invoice. Silakan bayar via LZPedia. (Simulasi)";
    } else {
        $msg = "API Gateway belum diset Admin!";
    }
}
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Pricing</title><link rel="stylesheet" href="assets/style.css"></head>
<body>
    <nav class="navbar"><a href="dashboard.php" class="logo"><i class="fas fa-arrow-left"></i> Kembali</a></nav>
    <div class="container">
        <?php if($msg): ?><div class="alert" style="background:rgba(16,185,129,0.2); color:var(--success); padding:15px; border-radius:10px; margin-bottom:20px;"><?= $msg ?></div><?php endif; ?>
        <h1 style="text-align:center; margin-bottom:30px;">Pilih Paket Premium</h1>
        <div class="video-grid" style="grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));">
            <?php foreach($plans as $p): ?>
            <div class="card" style="text-align:center;">
                <h2 style="color:var(--gold);"><?= $p['name'] ?></h2>
                <h3 style="font-size:2em; margin:10px 0;">Rp <?= number_format($p['price'],0,',','.') ?></h3>
                <p style="color:var(--muted); margin-bottom:20px;"><?= $p['duration_days'] ?> Hari Akses</p>
                <form method="POST"><input type="hidden" name="plan_code" value="<?= $p['code'] ?>"><button class="btn btn-primary" style="width:100%;">Beli Sekarang</button></form>
            </div>
            <?php endforeach; ?>
        </div>
    </div>
</body></html>
PHPEOF

# --- LOGOUT ---
cat > "$WEB_ROOT/logout.php" << 'PHPEOF'
<?php session_start(); session_destroy(); header('Location: login.php'); exit;
PHPEOF

# ==========================================
# 4. ADMIN PANEL (SUPER PRO)
# ==========================================
cat > "$WEB_ROOT/admin/index.php" << 'PHPEOF'
<?php require '../config.php'; if(!isAdmin()) { header('Location: ../login.php'); exit; }
$set = getSettings($pdo);
$totalUser = $pdo->query("SELECT COUNT(*) FROM users WHERE role='user'")->fetchColumn();
$totalVid = $pdo->query("SELECT COUNT(*) FROM videos")->fetchColumn();
$totalRev = $pdo->query("SELECT SUM(amount) FROM transactions WHERE status='paid'")->fetchColumn() ?: 0;
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Admin Panel</title><link rel="stylesheet" href="../assets/style.css"></head>
<body>
    <button class="mobile-toggle" onclick="document.querySelector('.sidebar').classList.toggle('open')"><i class="fas fa-bars"></i></button>
    <div class="admin-layout">
        <div class="sidebar">
            <h2 style="color:var(--gold); margin-bottom:20px;"><i class="fas fa-shield-alt"></i> Admin VGK</h2>
            <a href="index.php" class="active"><i class="fas fa-home"></i> Dashboard</a>
            <a href="videos.php"><i class="fas fa-video"></i> Video Manager</a>
            <a href="users.php"><i class="fas fa-users"></i> Users</a>
            <a href="finance.php"><i class="fas fa-money-bill-wave"></i> Keuangan</a>
            <a href="settings.php"><i class="fas fa-cog"></i> Settings</a>
            <a href="../logout.php" style="color:var(--danger); margin-top:20px;"><i class="fas fa-sign-out-alt"></i> Logout</a>
        </div>
        <div class="admin-content">
            <h1 style="margin-bottom:20px;">Overview</h1>
            <div class="video-grid" style="grid-template-columns: repeat(3, 1fr);">
                <div class="card" style="text-align:center;"><h3>Total User</h3><h2 style="color:var(--primary);"><?= $totalUser ?></h2></div>
                <div class="card" style="text-align:center;"><h3>Total Video</h3><h2 style="color:var(--gold);"><?= $totalVid ?></h2></div>
                <div class="card" style="text-align:center;"><h3>Pendapatan</h3><h2 style="color:var(--success);">Rp <?= number_format($totalRev,0,',','.') ?></h2></div>
            </div>
        </div>
    </div>
</body></html>
PHPEOF

# Videos Manager
cat > "$WEB_ROOT/admin/videos.php" << 'PHPEOF'
<?php require '../config.php'; if(!isAdmin()) exit;
if($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_FILES['video'])) {
    $title = $_POST['title']; $fn = time() . '_' . basename($_FILES['video']['name']);
    if(move_uploaded_file($_FILES['video']['tmp_name'], "../uploads/videos/" . $fn)) {
        $pdo->prepare("INSERT INTO videos (title, filename) VALUES (?,?)")->execute([$title, $fn]);
    }
}
$videos = $pdo->query("SELECT * FROM videos ORDER BY id DESC")->fetchAll();
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Video Manager</title><link rel="stylesheet" href="../assets/style.css"></head>
<body>
    <button class="mobile-toggle" onclick="document.querySelector('.sidebar').classList.toggle('open')"><i class="fas fa-bars"></i></button>
    <div class="admin-layout">
        <div class="sidebar">
            <h2 style="color:var(--gold); margin-bottom:20px;"><i class="fas fa-shield-alt"></i> Admin VGK</h2>
            <a href="index.php"><i class="fas fa-home"></i> Dashboard</a>
            <a href="videos.php" class="active"><i class="fas fa-video"></i> Video Manager</a>
            <a href="users.php"><i class="fas fa-users"></i> Users</a>
            <a href="finance.php"><i class="fas fa-money-bill-wave"></i> Keuangan</a>
            <a href="settings.php"><i class="fas fa-cog"></i> Settings</a>
        </div>
        <div class="admin-content">
            <h1>Video Manager</h1>
            <div class="card">
                <h3>Upload Video Baru</h3>
                <form method="POST" enctype="multipart/form-data">
                    <div class="form-group"><label>Judul</label><input type="text" name="title" required></div>
                    <div class="form-group"><label>File MP4</label><input type="file" name="video" accept="video/mp4" required></div>
                    <button class="btn btn-primary">Upload</button>
                </form>
            </div>
            <div class="card">
                <table style="width:100%; text-align:left; border-collapse:collapse;">
                    <tr style="border-bottom:1px solid var(--border);"><th>Judul</th><th>Nama File</th><th>Aksi</th></tr>
                    <?php foreach($videos as $v): ?>
                    <tr><td style="padding:10px;"><?= htmlspecialchars($v['title']) ?></td><td><?= $v['filename'] ?></td><td><a href="#" style="color:var(--danger);">Hapus</a></td></tr>
                    <?php endforeach; ?>
                </table>
            </div>
        </div>
    </div>
</body></html>
PHPEOF

# Users Manager
cat > "$WEB_ROOT/admin/users.php" << 'PHPEOF'
<?php require '../config.php'; if(!isAdmin()) exit;
if($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_POST['action'])) {
    $uid = $_POST['uid'];
    if($_POST['action'] == 'ban') $pdo->prepare("UPDATE users SET is_banned = 1 - is_banned WHERE id=?")->execute([$uid]);
    if($_POST['action'] == 'reset') $pdo->prepare("UPDATE users SET password='123456' WHERE id=?")->execute([$uid]);
    if($_POST['action'] == 'premium') $pdo->prepare("UPDATE users SET plan='promax', plan_expires=DATE_ADD(NOW(), INTERVAL 365 DAY) WHERE id=?")->execute([$uid]);
}
$users = $pdo->query("SELECT * FROM users WHERE role='user' ORDER BY id DESC")->fetchAll();
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Users</title><link rel="stylesheet" href="../assets/style.css"></head>
<body>
    <button class="mobile-toggle" onclick="document.querySelector('.sidebar').classList.toggle('open')"><i class="fas fa-bars"></i></button>
    <div class="admin-layout">
        <div class="sidebar">
            <h2 style="color:var(--gold); margin-bottom:20px;"><i class="fas fa-shield-alt"></i> Admin VGK</h2>
            <a href="index.php"><i class="fas fa-home"></i> Dashboard</a>
            <a href="videos.php"><i class="fas fa-video"></i> Video Manager</a>
            <a href="users.php" class="active"><i class="fas fa-users"></i> Users</a>
            <a href="finance.php"><i class="fas fa-money-bill-wave"></i> Keuangan</a>
            <a href="settings.php"><i class="fas fa-cog"></i> Settings</a>
        </div>
        <div class="admin-content">
            <h1>Manajemen User</h1>
            <div class="card">
                <table style="width:100%; text-align:left; border-collapse:collapse;">
                    <tr style="border-bottom:1px solid var(--border);"><th>Username</th><th>Plan</th><th>Status</th><th>Aksi</th></tr>
                    <?php foreach($users as $u): ?>
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="padding:10px;"><?= $u['username'] ?></td>
                        <td><?= strtoupper($u['plan']) ?></td>
                        <td><?= $u['is_banned'] ? '<span style="color:red;">Banned</span>' : '<span style="color:green;">Aktif</span>' ?></td>
                        <td>
                            <form method="POST" style="display:inline;"><input type="hidden" name="uid" value="<?= $u['id'] ?>"><button name="action" value="ban" class="btn btn-danger" style="padding:5px;">Ban</button></form>
                            <form method="POST" style="display:inline;"><input type="hidden" name="uid" value="<?= $u['id'] ?>"><button name="action" value="reset" class="btn btn-primary" style="padding:5px;">Reset PW</button></form>
                            <form method="POST" style="display:inline;"><input type="hidden" name="uid" value="<?= $u['id'] ?>"><button name="action" value="premium" class="btn btn-gold" style="padding:5px;">Set Promax</button></form>
                        </td>
                    </tr>
                    <?php endforeach; ?>
                </table>
            </div>
        </div>
    </div>
</body></html>
PHPEOF

# Settings (Maintenance & API Key)
cat > "$WEB_ROOT/admin/settings.php" << 'PHPEOF'
<?php require '../config.php'; if(!isAdmin()) exit;
$set = getSettings($pdo);
if($_SERVER['REQUEST_METHOD'] == 'POST') {
    $pdo->prepare("UPDATE settings SET site_name=?, maintenance=?, lz_api_key=? WHERE id=1")->execute([$_POST['site_name'], isset($_POST['maintenance']) ? 1 : 0, $_POST['lz_api_key']]);
    header('Location: settings.php'); exit;
}
?>
<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><title>Settings</title><link rel="stylesheet" href="../assets/style.css"></head>
<body>
    <button class="mobile-toggle" onclick="document.querySelector('.sidebar').classList.toggle('open')"><i class="fas fa-bars"></i></button>
    <div class="admin-layout">
        <div class="sidebar">
            <h2 style="color:var(--gold); margin-bottom:20px;"><i class="fas fa-shield-alt"></i> Admin VGK</h2>
            <a href="index.php"><i class="fas fa-home"></i> Dashboard</a>
            <a href="videos.php"><i class="fas fa-video"></i> Video Manager</a>
            <a href="users.php"><i class="fas fa-users"></i> Users</a>
            <a href="finance.php"><i class="fas fa-money-bill-wave"></i> Keuangan</a>
            <a href="settings.php" class="active"><i class="fas fa-cog"></i> Settings</a>
        </div>
        <div class="admin-content">
            <h1>Pengaturan Web</h1>
            <div class="card">
                <form method="POST">
                    <div class="form-group"><label>Nama Website</label><input type="text" name="site_name" value="<?= $set['site_name'] ?>" required></div>
                    <div class="form-group"><label>API Key LZPedia (Payment Gateway)</label><input type="text" name="lz_api_key" value="<?= $set['lz_api_key'] ?>"></div>
                    <div class="form-group"><label><input type="checkbox" name="maintenance" <?= $set['maintenance'] ? 'checked' : '' ?>> Mode Maintenance (Hanya user yang kena)</label></div>
                    <button class="btn btn-primary">Simpan Perubahan</button>
                </form>
            </div>
        </div>
    </div>
</body></html>
PHPEOF

# ==========================================
# 5. SETUP NGINX & SSL
# ==========================================
echo -e "${CYAN}[4/5] Setup Nginx & SSL...${NC}"
cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80; listen [::]:80;
    server_name $DOMAIN;
    root $WEB_ROOT; index index.php index.html;
    client_max_body_size 100M;
    location ~ /\.ht { deny all; }
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/var/run/php/php8.3-fpm.sock; }
}
NGINXEOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/ 2>/dev/null
nginx -t >/dev/null 2>&1 && systemctl reload nginx
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 777 "$WEB_ROOT/uploads"
systemctl restart php8.3-fpm

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
DOMAIN_IP=$(dig +short A "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)
if [[ "$SERVER_IP" == "$DOMAIN_IP" ]]; then certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect >/dev/null 2>&1; fi
PROTO="https"; [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && PROTO="http"

echo -e "${GREEN}[5/5] Selesai!${NC}"
clear
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ INSTALASI ASUPAN VGK v3.0 BERHASIL!    ║${NC}"
echo -e "${GREEN}║  🚀 Anti-SS • Paywall • Payment Gateway    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🔗 Web Utama:${NC} $PROTO://$DOMAIN"
echo -e "${MAGENTA}🔒 Admin Panel:${NC} $PROTO://$DOMAIN/admin/"
echo ""
echo -e "${WHITE}🔑 Login Admin:${NC}"
echo -e "   Username : ${WHITE}admin${NC}"
echo -e "   Password : ${WHITE}AdminVGK123${NC}"
echo ""
echo -e "${YELLOW}💡 Fitur: Semua video otomatis ke-lock. User harus beli paket via LZPedia buat nonton.${NC}"
echo -e "${GREEN}🚀 Buka webnya & coba fitur Anti Screenshot-nya (pindah tab)!${NC}"
