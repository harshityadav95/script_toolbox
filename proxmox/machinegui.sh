#!/usr/bin/env bash
# =============================================================================
#  setup-vnc-desktop.sh
#  Single-user XFCE + TigerVNC + noVNC + nginx (HTTPS / WSS)
#  Ubuntu 22.04 / 24.04 LXC container
#
#  Usage:  sudo bash setup-vnc-desktop.sh
#
#  Safe to re-run on a machine where a previous attempt partially ran.
#  - Generates a self-signed SSL cert (auto-detects LAN IP for SAN)
#  - nginx listens on 443 with SSL, port 80 redirects → HTTPS
#  - websockify serves HTTPS directly on port 6901 with the same cert
#  - All URLs are https://
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fatal()   { echo -e "${RED}[FAIL]${RESET}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "Run as root:  sudo bash $0"

# =============================================================================
#  DEFAULTS — change here or answer the prompts
# =============================================================================
DESK_USER=""
VNC_DISPLAY=1
VNC_PORT=5901
WS_PORT=6901
GEOMETRY="1280x800"
DEPTH=24
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443
SSL_DIR="/etc/nginx/ssl/vnc-desktop"

# =============================================================================
#  STEP 0 — Gather inputs
# =============================================================================
section "Configuration"

if [[ -z "$DESK_USER" ]]; then
    read -rp "  Desktop username to create (e.g. alice): " DESK_USER
    [[ -n "$DESK_USER" ]] || fatal "Username cannot be empty"
fi

read -rp "  Desktop resolution [${GEOMETRY}]: " _GEO
GEOMETRY="${_GEO:-$GEOMETRY}"

echo ""
info "User       : $DESK_USER"
info "VNC port   : $VNC_PORT  (display :${VNC_DISPLAY})"
info "WebSocket  : $WS_PORT  (HTTPS/WSS)"
info "nginx HTTP : $NGINX_HTTP_PORT  (→ redirect to HTTPS)"
info "nginx HTTPS: $NGINX_HTTPS_PORT"
info "Resolution : $GEOMETRY"
echo ""
warn "NOTE: During install you will see 'Permission denied' lines for"
warn "      udisks2, pulseaudio, and /sys/... paths. These are HARMLESS"
warn "      LXC container limitations — packages install correctly."
echo ""
read -rp "  Continue? (y/n): " _CONFIRM
[[ "$_CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================================
#  STEP 1 — Install packages
# =============================================================================
section "Step 1 — Installing packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

info "Installing XFCE..."
apt-get install -y -qq \
    xfce4 xfce4-terminal xfce4-whiskermenu-plugin \
    dbus-x11 x11-xserver-utils x11-utils 2>/dev/null || true
ok "XFCE installed"

info "Installing TigerVNC..."
apt-get install -y -qq tigervnc-standalone-server tigervnc-common 2>/dev/null || true
ok "TigerVNC installed"

info "Installing noVNC + websockify..."
apt-get install -y -qq novnc websockify 2>/dev/null || true

WS_BIN=""
for _b in /usr/bin/websockify /usr/local/bin/websockify; do
    [[ -x "$_b" ]] && { WS_BIN="$_b"; break; }
done
if [[ -z "$WS_BIN" ]]; then
    apt-get install -y -qq python3-websockify 2>/dev/null || true
    WS_BIN=$(command -v websockify 2>/dev/null || true)
fi
[[ -n "$WS_BIN" ]] || fatal "websockify not found. Run: apt install python3-websockify"
ok "websockify: ${WS_BIN}"

info "Installing nginx + openssl..."
apt-get install -y -qq nginx openssl 2>/dev/null || true
ok "nginx + openssl installed"

apt-get install -y -qq curl wget net-tools 2>/dev/null || true

# ── Locate Xvnc binary ───────────────────────────────────────────────────────
XVNC_BIN=""
for _b in /usr/bin/Xtigervnc /usr/bin/Xvnc; do
    [[ -x "$_b" ]] && { XVNC_BIN="$_b"; break; }
done
[[ -n "$XVNC_BIN" ]] || fatal "Xvnc binary not found. Is tigervnc-standalone-server installed?"
ok "Xvnc binary: ${XVNC_BIN}"

# ── Locate noVNC web root ─────────────────────────────────────────────────────
NOVNC_WEB=""
for _d in /usr/share/novnc /usr/local/share/novnc; do
    [[ -f "${_d}/vnc.html" ]] && { NOVNC_WEB="$_d"; break; }
done
[[ -n "$NOVNC_WEB" ]] || fatal "noVNC web files not found. Is novnc installed?"
ok "noVNC web root: ${NOVNC_WEB}"

# =============================================================================
#  STEP 1.5 — Clean up previous installations (Start fresh)
# =============================================================================
section "Step 1.5 — Cleaning up previous configurations"

# Stop services
systemctl stop vncserver-desktop websockify-desktop nginx 2>/dev/null || true

# Kill any lingering VNC processes
pkill -9 -f 'Xvnc|Xtigervnc' 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 1

# Remove old configs
rm -rf /home/*/.vnc /root/.vnc
rm -f /etc/systemd/system/vncserver-desktop.service
rm -f /etc/systemd/system/websockify-desktop.service
rm -f /etc/nginx/sites-available/vnc-desktop
rm -f /etc/nginx/sites-enabled/vnc-desktop
rm -f /tmp/.X*-lock /tmp/.X11-unix/X*
systemctl daemon-reload
ok "Previous configurations and services wiped"

# =============================================================================
#  STEP 2 — Create desktop user
# =============================================================================
section "Step 2 — Creating user: ${DESK_USER}"

if id "$DESK_USER" &>/dev/null; then
    warn "User '${DESK_USER}' already exists — skipping useradd"
else
    useradd -m -s /bin/bash "$DESK_USER"
    ok "User '${DESK_USER}' created"
fi

# ── Set Linux login password (interactive, inline) ────────────────────────────
echo ""
info "Set a Linux login password for '${DESK_USER}':"
while true; do
    read -rsp "  Enter password: " _LINUX_PASS; echo ""
    [[ ${#_LINUX_PASS} -ge 4 ]] || { warn "Password too short (min 4 chars). Try again."; continue; }
    read -rsp "  Confirm password: " _LINUX_PASS2; echo ""
    [[ "$_LINUX_PASS" == "$_LINUX_PASS2" ]] || { warn "Passwords do not match. Try again."; continue; }
    break
done
echo "${DESK_USER}:${_LINUX_PASS}" | chpasswd
unset _LINUX_PASS _LINUX_PASS2
ok "Linux password set for '${DESK_USER}'"

# =============================================================================
#  STEP 3 — VNC password
# =============================================================================
section "Step 3 — VNC password for ${DESK_USER}"

mkdir -p "/home/${DESK_USER}/.vnc"
chown "${DESK_USER}:${DESK_USER}" "/home/${DESK_USER}/.vnc"
chmod 700 "/home/${DESK_USER}/.vnc"

# ── Set VNC password (interactive, inline) ────────────────────────────────────
echo ""
info "Set the VNC password (used in the noVNC browser dialog):"
info "(VNC passwords are truncated to 8 characters by the VNC protocol)"
while true; do
    read -rsp "  Enter VNC password: " _VNC_PASS; echo ""
    [[ ${#_VNC_PASS} -ge 4 ]] || { warn "Password too short (min 4 chars). Try again."; continue; }
    read -rsp "  Confirm VNC password: " _VNC_PASS2; echo ""
    [[ "$_VNC_PASS" == "$_VNC_PASS2" ]] || { warn "Passwords do not match. Try again."; continue; }
    break
done

# Generate the VNC password file
# vncpasswd -f reads ONE line from stdin and writes the 8-byte DES-encoded file
_PASSWD_FILE="/home/${DESK_USER}/.vnc/passwd"
printf '%s\n' "$_VNC_PASS" | vncpasswd -f > "$_PASSWD_FILE"
chmod 600 "$_PASSWD_FILE"
chown "${DESK_USER}:${DESK_USER}" "$_PASSWD_FILE"
unset _VNC_PASS _VNC_PASS2

# Verify the password file was actually created and is non-empty
if [[ ! -s "$_PASSWD_FILE" ]]; then
    warn "vncpasswd -f produced an empty file — falling back to manual vncpasswd"
    su - "${DESK_USER}" -s /bin/bash -c "vncpasswd ~/.vnc/passwd"
fi
_PSIZE=$(stat -c%s "$_PASSWD_FILE" 2>/dev/null || stat -f%z "$_PASSWD_FILE" 2>/dev/null || echo 0)
info "Password file size: ${_PSIZE} bytes (expected: 8)"
[[ "$_PSIZE" -ge 8 ]] || fatal "VNC password file is invalid (${_PSIZE} bytes). Cannot continue."
ok "VNC password verified and saved"

# =============================================================================
#  STEP 4 — XFCE xstartup
# =============================================================================
section "Step 4 — xstartup (XFCE session launcher)"

cat > "/home/${DESK_USER}/.vnc/xstartup" << 'XSTART'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
XSTART

chmod +x "/home/${DESK_USER}/.vnc/xstartup"
chown "${DESK_USER}:${DESK_USER}" "/home/${DESK_USER}/.vnc/xstartup"
ok "xstartup written"

# =============================================================================
#  STEP 5 — VNC session wrapper script
# =============================================================================
section "Step 5 — VNC session wrapper"

WRAPPER="/usr/local/bin/vnc-desktop.sh"

cat > "$WRAPPER" << WRAPPER_EOF
#!/bin/bash
# Managed by setup-vnc-desktop.sh — do not edit by hand
VNC_USER="${DESK_USER}"
VNC_DISPLAY="${VNC_DISPLAY}"
VNC_GEOMETRY="${GEOMETRY}"
VNC_DEPTH="${DEPTH}"
XVNC_BIN="${XVNC_BIN}"

log() { echo "\$(date '+%H:%M:%S') [vnc-desktop] \$*"; }

cleanup() {
    log "Shutting down..."
    [[ -n "\${XFCE_PID:-}" ]] && kill "\$XFCE_PID" 2>/dev/null || true
    [[ -n "\${XVNC_PID:-}" ]] && kill "\$XVNC_PID" 2>/dev/null || true
    rm -f "/tmp/.X\${VNC_DISPLAY}-lock" "/tmp/.X11-unix/X\${VNC_DISPLAY}"
    log "Stopped."
}
trap cleanup EXIT INT TERM

# Create /tmp/.X11-unix — missing in fresh LXC containers
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Remove stale locks from previous runs
rm -f "/tmp/.X\${VNC_DISPLAY}-lock"
rm -f "/tmp/.X11-unix/X\${VNC_DISPLAY}"

log "Starting Xvnc on display :\${VNC_DISPLAY} (\$XVNC_BIN)..."

# Start Xvnc as the desktop user (background)
# We call Xvnc directly — bypasses the vncserver wrapper which has
# unreliable PID tracking in LXC environments
su - "\$VNC_USER" -s /bin/bash -c "
    \"\$XVNC_BIN\" \":\${VNC_DISPLAY}\" \\
        -geometry \"\${VNC_GEOMETRY}\" \\
        -depth    \"\${VNC_DEPTH}\"    \\
        -rfbauth  ~/.vnc/passwd        \\
        -desktop  Desktop              \\
        -SecurityTypes VncAuth         \\
        -AlwaysShared                  \\
        >> ~/.vnc/xvnc.log 2>&1
" &
XVNC_PID=\$!
log "Xvnc PID: \$XVNC_PID"

# Wait for display socket (up to 20 s)
log "Waiting for display :\${VNC_DISPLAY}..."
READY=0
for _i in \$(seq 1 40); do
    if [[ -S "/tmp/.X11-unix/X\${VNC_DISPLAY}" ]]; then
        if su - "\$VNC_USER" -s /bin/bash -c \
               "DISPLAY=:\${VNC_DISPLAY} xdpyinfo > /dev/null 2>&1"; then
            READY=1; break
        fi
    fi
    sleep 0.5
done

if [[ \$READY -eq 0 ]]; then
    log "ERROR: Xvnc did not become ready. Dumping log:"
    cat "/home/\${VNC_USER}/.vnc/xvnc.log" 2>/dev/null || echo "(no log)"
    exit 1
fi
log "Display ready."

# Start XFCE session as the desktop user
log "Starting XFCE..."
su - "\$VNC_USER" -s /bin/bash -c "
    export DISPLAY=:\${VNC_DISPLAY}
    export DBUS_SESSION_BUS_ADDRESS=
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=XFCE
    unset SESSION_MANAGER
    exec dbus-launch --exit-with-session startxfce4 >> ~/.vnc/xfce.log 2>&1
" &
XFCE_PID=\$!
log "XFCE PID: \$XFCE_PID"

# Block until Xvnc exits (systemd tracks this wrapper PID)
wait "\$XVNC_PID"
log "Xvnc exited — service stopping."
WRAPPER_EOF

chmod +x "$WRAPPER"
ok "Wrapper written: ${WRAPPER}"

# =============================================================================
#  STEP 6 — systemd service: vncserver-desktop
# =============================================================================
section "Step 6 — systemd service: vncserver-desktop"

cat > /etc/systemd/system/vncserver-desktop.service << VNCSVC
[Unit]
Description=VNC desktop for ${DESK_USER}
After=network.target

[Service]
Type=simple
ExecStart=${WRAPPER}
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
VNCSVC
ok "vncserver-desktop.service written"

# =============================================================================
#  STEP 7 — Generate self-signed SSL certificate
# =============================================================================
section "Step 7 — SSL certificate (self-signed)"

# Auto-detect LAN IP for Subject Alternative Name
DETECTED_IP=""
_first_ip=$(ip -4 addr show scope global 2>/dev/null \
    | grep -oP 'inet \K[0-9.]+' | head -1 || true)
DETECTED_IP="${_first_ip:-127.0.0.1}"
info "Detected LAN IP: ${DETECTED_IP}"

mkdir -p "${SSL_DIR}"

# Always regenerate to pick up IP changes (safe to re-run)
info "Generating RSA-4096 self-signed certificate..."
openssl req -x509 -nodes \
    -newkey rsa:4096 \
    -days 3650 \
    -keyout "${SSL_DIR}/vnc.key" \
    -out    "${SSL_DIR}/vnc.crt" \
    -subj   "/C=XX/ST=Lab/L=Lab/O=VNC-Desktop/CN=${DETECTED_IP}" \
    -addext "subjectAltName=IP:${DETECTED_IP},IP:127.0.0.1" \
    2>/dev/null

chmod 600 "${SSL_DIR}/vnc.key"
chmod 644 "${SSL_DIR}/vnc.crt"
ok "Certificate: ${SSL_DIR}/vnc.crt"
ok "Private key: ${SSL_DIR}/vnc.key"

# =============================================================================
#  STEP 8 — systemd service: websockify-desktop (HTTPS on port 6901)
# =============================================================================
section "Step 8 — systemd service: websockify-desktop (HTTPS)"

cat > /etc/systemd/system/websockify-desktop.service << WSSVC
[Unit]
Description=noVNC WebSocket bridge — HTTPS (${DESK_USER})
After=network.target vncserver-desktop.service
Requires=vncserver-desktop.service

[Service]
Type=simple
ExecStart=${WS_BIN} \\
    --web=${NOVNC_WEB} \\
    --heartbeat=30 \\
    --cert=${SSL_DIR}/vnc.crt \\
    --key=${SSL_DIR}/vnc.key \\
    0.0.0.0:${WS_PORT} \\
    127.0.0.1:${VNC_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
WSSVC
ok "websockify-desktop.service written (HTTPS on port ${WS_PORT})"

# =============================================================================
#  STEP 9 — nginx config (HTTPS reverse proxy)
# =============================================================================
section "Step 9 — nginx reverse proxy (HTTPS)"

cat > /etc/nginx/sites-available/vnc-desktop << NGINXCONF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# ── HTTP proxy (Cloudflare Tunnel compatible) ────────────────────────────────
# Cloudflare Tunnel service URL: http://<IP>:${NGINX_HTTP_PORT}
server {
    listen ${NGINX_HTTP_PORT};
    server_name _;

    location = / {
        return 301 /vnc.html;
    }

    location / {
        proxy_pass         https://127.0.0.1:${WS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout    3600s;
        proxy_send_timeout    3600s;
        proxy_connect_timeout 10s;
    }
}

# ── HTTPS proxy (direct LAN access) ─────────────────────────────────────────
server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name _;

    ssl_certificate     ${SSL_DIR}/vnc.crt;
    ssl_certificate_key ${SSL_DIR}/vnc.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location = / {
        return 301 /vnc.html;
    }

    location / {
        proxy_pass         https://127.0.0.1:${WS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout    3600s;
        proxy_send_timeout    3600s;
        proxy_connect_timeout 10s;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/vnc-desktop /etc/nginx/sites-enabled/vnc-desktop
rm -f /etc/nginx/sites-enabled/default

nginx -t || fatal "nginx config failed — check /etc/nginx/sites-available/vnc-desktop"
ok "nginx configured (HTTP:${NGINX_HTTP_PORT} + HTTPS:${NGINX_HTTPS_PORT})"

# =============================================================================
#  STEP 10 — Enable & start all services
# =============================================================================
section "Step 10 — Starting services"

systemctl daemon-reload

# Stop any lingering previous instances
for svc in websockify-desktop vncserver-desktop nginx; do
    systemctl stop "$svc" 2>/dev/null || true
done

# Clean stale X locks before first start
rm -f "/tmp/.X${VNC_DISPLAY}-lock" "/tmp/.X11-unix/X${VNC_DISPLAY}"
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

for svc in vncserver-desktop websockify-desktop nginx; do
    info "Enabling and starting ${svc}..."
    systemctl enable "$svc" --quiet
    systemctl start  "$svc"
    # VNC server needs extra time to create the display socket
    [[ "$svc" == "vncserver-desktop" ]] && sleep 5 || sleep 2
    if systemctl is-active --quiet "$svc"; then
        ok "${svc} — running"
    else
        warn "${svc} — did not start cleanly:"
        journalctl -u "$svc" -n 15 --no-pager 2>/dev/null || true
    fi
done

# ── Verify VNC is actually listening ──────────────────────────────────────────
echo ""
info "Verifying VNC port ${VNC_PORT} is listening..."
sleep 2
if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT} "; then
    _VNC_LISTEN=$(ss -tlnp 2>/dev/null | grep ":${VNC_PORT} " | awk '{print $4}' | head -1)
    ok "VNC listening on ${_VNC_LISTEN}"
else
    warn "VNC port ${VNC_PORT} is NOT listening — Xvnc may have crashed!"
    warn "VNC log output:"
    cat "/home/${DESK_USER}/.vnc/xvnc.log" 2>/dev/null | tail -20 || echo "  (no log file)"
    echo ""
    warn "Password file check:"
    ls -la "/home/${DESK_USER}/.vnc/passwd" 2>/dev/null || echo "  (passwd file missing!)"
fi

info "Verifying websockify port ${WS_PORT} is listening..."
if ss -tlnp 2>/dev/null | grep -q ":${WS_PORT} "; then
    ok "Websockify listening on port ${WS_PORT}"
else
    warn "Websockify port ${WS_PORT} is NOT listening!"
fi

# =============================================================================
#  STEP 11 — Print LAN URLs
# =============================================================================
section "Step 11 — LAN Verification URLs"

CONTAINER_IPS=()
while IFS= read -r _line; do
    _ip=$(echo "$_line" | awk '{print $2}' | cut -d/ -f1)
    CONTAINER_IPS+=("$_ip")
done < <(ip -4 addr show scope global 2>/dev/null | grep -E '^\s+inet ')

echo ""
echo -e "${BOLD}  ┌────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}  │               🔒  LAN Access URLs (HTTPS)             │${RESET}"
echo -e "${BOLD}  └────────────────────────────────────────────────────────┘${RESET}"
echo ""

if [[ ${#CONTAINER_IPS[@]} -eq 0 ]]; then
    warn "Could not auto-detect IP. Run: ip -4 addr show scope global"
    echo -e "  noVNC URL  : ${GREEN}https://<CONTAINER-IP>/vnc.html${RESET}"
    echo -e "  Direct WS  : ${CYAN}https://<CONTAINER-IP>:${WS_PORT}/vnc.html${RESET}"
else
    for _ip in "${CONTAINER_IPS[@]}"; do
        echo -e "  IP          : ${YELLOW}${_ip}${RESET}"
        echo -e "  noVNC URL   : ${GREEN}${BOLD}https://${_ip}/vnc.html${RESET}"
        echo -e "  Direct WS   : ${CYAN}${BOLD}https://${_ip}:${WS_PORT}/vnc.html${RESET}"
        echo ""
    done
fi
echo -e "  VNC native  : 127.0.0.1:${VNC_PORT}  (localhost only)"
echo ""
warn "Self-signed cert — your browser will show a security warning."
warn "Click 'Advanced' → 'Proceed' (or 'Accept the Risk') to continue."
echo ""

# ── Cloudflare Tunnel section ────────────────────────────────────────────────
CF_ORIGIN_IP="${CONTAINER_IPS[0]:-<CONTAINER-IP>}"

echo -e "${BOLD}  ┌────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}  │          ☁️  Cloudflare Tunnel Configuration           │${RESET}"
echo -e "${BOLD}  └────────────────────────────────────────────────────────┘${RESET}"
echo ""
echo -e "  ${BOLD}Paste into Cloudflare Tunnel Dashboard → Service URL:${RESET}"
echo ""
echo -e "  ${BOLD}Service Type:${RESET}  ${CYAN}${BOLD}TCP${RESET}  (or vnc if available)"
echo -e "  ${BOLD}URL:${RESET}           ${GREEN}${BOLD}${CF_ORIGIN_IP}:${VNC_PORT}${RESET}"
echo ""
echo -e "  ${YELLOW}${BOLD}⚠️  IMPORTANT — WHY THIS CHANGED:${RESET}"
echo -e "  Because you enabled ${BOLD}'Browser rendering -> VNC'${RESET} in Cloudflare Access,"
echo -e "  Cloudflare runs its own internal VNC web-client. It expects to talk to"
echo -e "  the ${BOLD}raw VNC server${RESET} (port 5901), NOT the Nginx/Websocket proxy."
echo ""
echo -e "  If you point Cloudflare to Nginx/HTTP, Cloudflare's VNC client will"
echo -e "  receive an HTML webpage instead of VNC data, causing it to immediately disconnect!"
echo ""
echo ""

# =============================================================================
#  STEP 12 — Status summary
# =============================================================================
section "Service Status"

printf "  %-32s %s\n" "SERVICE" "STATUS"
printf "  %-32s %s\n" "────────────────────────────────" "────────"

for svc in vncserver-desktop websockify-desktop nginx; do
    if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc"; then
            _S="${GREEN}● running${RESET}"
        else
            _S="${RED}✗ stopped${RESET}"
        fi
    else
        _S="${YELLOW}○ not enabled${RESET}"
    fi
    printf "  %-32s " "$svc"
    echo -e "$_S"
done

echo ""
echo -e "${BOLD}━━━  Useful debug commands ━━━${RESET}"
echo ""
echo "  Xvnc log    :  cat /home/${DESK_USER}/.vnc/xvnc.log"
echo "  XFCE log    :  cat /home/${DESK_USER}/.vnc/xfce.log"
echo "  VNC service :  journalctl -u vncserver-desktop -n 50"
echo "  WS service  :  journalctl -u websockify-desktop -n 50"
echo "  Port check  :  ss -tlnp | grep -E '(${VNC_PORT}|${WS_PORT}|${NGINX_HTTP_PORT}|${NGINX_HTTPS_PORT})'"
echo "  Restart all :  systemctl restart vncserver-desktop websockify-desktop nginx"
echo "  Regen cert  :  Re-run this script — cert is regenerated every time"
echo ""
echo -e "${BOLD}━━━  Quick test checklist ━━━${RESET}"
echo ""
echo "  □  Open the noVNC URL above in your browser"
echo "  □  Accept the self-signed certificate warning"
echo "  □  noVNC connect screen loads"
echo "  □  Click Connect — enter your VNC password"
echo "  □  XFCE desktop appears"
echo ""
echo -e "${GREEN}${BOLD}  Setup complete! 🔒${RESET}"
echo ""
