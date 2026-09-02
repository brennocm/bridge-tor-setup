#!/bin/bash
# Single script: initial hardening (Debian, root + password) + full stack
# setup (obfs4 Tor bridge + Uptime Kuma + daily Telegram summary).
#
# Run as root. Idempotent: safe to re-run if it stops midway
# (e.g. waiting for you to fill in .env).
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/tor-bridge-stack}"

# ============================================================
# PART 1 — INITIAL HARDENING
# ============================================================

echo "==> [1/8] Updating the system"
apt-get update -qq
apt-get -y -qq full-upgrade

echo "==> [2/8] Installing essential packages"
apt-get install -y -qq ufw fail2ban unattended-upgrades apt-listchanges chrony \
               curl gnupg2 ca-certificates git wget jq

echo "==> [3/8] Configuring firewall (UFW)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 9001/tcp comment 'Tor ORPort'
ufw allow 9002/tcp comment 'Tor PT_PORT (obfs4)'
# Uptime Kuma (3001) is intentionally left out: SSH tunnel access only
ufw --force enable

echo "==> [4/8] Configuring fail2ban"
# Lower maxretry and longer bantime: since access is password-only
# (no SSH key), fail2ban is the main defense against brute force.
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled  = true
port     = 22
maxretry = 3
findtime = 600
bantime  = 7200
EOF
systemctl enable --now fail2ban

echo "==> [5/8] Kernel hardening (sysctl)"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Ignore ICMP redirects (avoids route man-in-the-middle)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# Reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Ignore broadcast pings (mitigates smurf attacks)
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Log packets with suspicious source addresses
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system >/dev/null

echo "==> [6/8] Setting up automatic security updates"
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "==> [7/8] Time sync (important for Tor)"
systemctl enable --now chrony

echo "==> [8/8] Creating a 2GB safety swap file"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo ""
echo "Base hardening complete. Root password login remains active."
echo ""

# ============================================================
# PART 2 — DOCKER + UFW-DOCKER FIX
# ============================================================

echo "==> Installing Docker (if needed)"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

echo "==> Applying the ufw-docker fix (Docker bypasses UFW by default)"
if [ ! -f /usr/local/bin/ufw-docker ]; then
  wget -qO /usr/local/bin/ufw-docker \
    https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
  chmod +x /usr/local/bin/ufw-docker
  ufw-docker install
  systemctl restart ufw
fi

# ============================================================
# PART 3 — STACK: TOR BRIDGE + UPTIME KUMA + DAILY SUMMARY
# ============================================================

mkdir -p "${PROJECT_DIR}/daily-summary"
cd "${PROJECT_DIR}"

echo "==> Cloning the official bridge repository (Tor Project)"
if [ ! -d docker-obfs4-bridge ]; then
  git clone -q https://gitlab.torproject.org/tpo/anti-censorship/docker-obfs4-bridge.git
fi

echo "==> Generating docker-compose.yml"
cat > docker-compose.yml <<'EOF'
services:
  tor-bridge:
    build: ./docker-obfs4-bridge
    container_name: tor-bridge
    restart: unless-stopped
    environment:
      OR_PORT: ${OR_PORT}
      PT_PORT: ${PT_PORT}
      EMAIL: ${CONTACT_EMAIL}
      NICKNAME: ${BRIDGE_NICKNAME}
    ports:
      - "${OR_PORT}:${OR_PORT}"
      - "${PT_PORT}:${PT_PORT}"
    volumes:
      - tor-bridge-data:/var/lib/tor

  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - uptime-kuma-data:/app/data

  daily-summary:
    build: ./daily-summary
    container_name: tor-daily-summary
    restart: unless-stopped
    environment:
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
      TELEGRAM_CHAT_ID: ${TELEGRAM_CHAT_ID}
      BRIDGE_FINGERPRINT: ${BRIDGE_FINGERPRINT}
      BRIDGE_NICKNAME: ${BRIDGE_NICKNAME}
      TZ: ${TZ:-America/Sao_Paulo}
      CRON_SCHEDULE: ${CRON_SCHEDULE:-0 9 * * *}

volumes:
  tor-bridge-data:
  uptime-kuma-data:
EOF

echo "==> Generating the daily-summary container files"
cat > daily-summary/Dockerfile <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache bash curl jq tzdata dcron
COPY daily_summary.sh /usr/local/bin/daily_summary.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/daily_summary.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF

cat > daily-summary/entrypoint.sh <<'EOF'
#!/bin/bash
set -euo pipefail
env | grep -E '^(TELEGRAM_|BRIDGE_|TZ=)' > /etc/daily_summary.env
SCHEDULE="${CRON_SCHEDULE:-0 9 * * *}"
echo "${SCHEDULE} . /etc/daily_summary.env; /usr/local/bin/daily_summary.sh >> /var/log/daily_summary.log 2>&1" \
  > /etc/crontabs/root
. /etc/daily_summary.env
/usr/local/bin/daily_summary.sh || echo "Warning: first send failed, check log above."
exec crond -f -l 2
EOF

cat > daily-summary/daily_summary.sh <<'EOF'
#!/bin/bash
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID}"
: "${BRIDGE_FINGERPRINT:?Set BRIDGE_FINGERPRINT (hash from the Tor log)}"
NICKNAME="${BRIDGE_NICKNAME:-my-bridge}"
NOW_UTC="$(date -u +'%Y-%m-%d %H:%M UTC')"
RESPONSE="$(curl -fsS "https://onionoo.torproject.org/details?lookup=${BRIDGE_FINGERPRINT}" || echo '{}')"
NODE="$(echo "$RESPONSE" | jq -c '(.bridges // [])[0] // (.relays // [])[0] // empty')"
if [ -z "$NODE" ]; then
  MSG="⚠️ *Daily summary — ${NICKNAME}*
_${NOW_UTC}_

No data found on Onionoo for this fingerprint yet. Normal in the first few hours."
else
  RUNNING="$(echo "$NODE" | jq -r '.running')"
  LAST_RESTARTED="$(echo "$NODE" | jq -r '.last_restarted // "unknown"')"
  LAST_SEEN="$(echo "$NODE" | jq -r '.last_seen // "unknown"')"
  BW_RAW="$(echo "$NODE" | jq -r '.advertised_bandwidth // empty')"
  FLAGS="$(echo "$NODE" | jq -r '(.flags // []) | join(", ")')"
  if [ "$RUNNING" = "true" ]; then
    STATUS_EMOJI="🟢"; STATUS_TXT="online and visible on the network"
  else
    STATUS_EMOJI="🔴"; STATUS_TXT="offline (not seen in the last scan)"
  fi
  BW_HUMAN="N/A"
  if [ -n "${BW_RAW:-}" ] && [ "$BW_RAW" != "null" ]; then
    BW_HUMAN="$(awk -v b="$BW_RAW" 'BEGIN{printf "%.0f KB/s", b/1024}')"
  fi
  MSG="${STATUS_EMOJI} *Daily summary — ${NICKNAME}*
_${NOW_UTC}_

Status: ${STATUS_TXT}
Running since: ${LAST_RESTARTED}
Last seen: ${LAST_SEEN}
Advertised bandwidth: ${BW_HUMAN}
Flags: ${FLAGS:-none listed yet}"
fi
curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d parse_mode="Markdown" \
  --data-urlencode text="${MSG}" > /dev/null
echo "$(date -u +%FT%TZ) - daily summary sent"
EOF
chmod +x daily-summary/*.sh

if [ ! -f .env ]; then
  echo "==> Generating .env (with placeholders)"
  cat > .env <<'EOF'
OR_PORT=9001
PT_PORT=9002
CONTACT_EMAIL=your-email@example.com
BRIDGE_NICKNAME=TorVolunteerBridge
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
BRIDGE_FINGERPRINT=
TZ=America/Sao_Paulo
CRON_SCHEDULE="0 9 * * *"
EOF
  echo ""
  echo "!!! Edit ${PROJECT_DIR}/.env (email, Telegram token/chat id) and re-run this script !!!"
  exit 0
fi

# shellcheck disable=SC1091
source .env
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "ERROR: fill in TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in ${PROJECT_DIR}/.env before continuing."
  exit 1
fi

echo "==> Starting Tor bridge + Uptime Kuma"
docker compose up -d --build tor-bridge uptime-kuma

echo "==> Waiting for the bridge to publish its fingerprint (up to 5 minutes)..."
FINGERPRINT=""
for i in $(seq 1 60); do
  FINGERPRINT="$(docker compose logs tor-bridge 2>/dev/null \
    | grep -i "hashed identity" \
    | grep -oE "[A-F0-9]{40}" | head -n1 || true)"
  [ -n "$FINGERPRINT" ] && break
  sleep 5
done

if [ -z "$FINGERPRINT" ]; then
  echo "WARNING: fingerprint hasn't shown up in the logs yet."
  echo "Later, run: docker compose logs tor-bridge | grep -i 'hashed identity'"
  echo "Fill in BRIDGE_FINGERPRINT in .env, then: docker compose up -d --build daily-summary"
else
  echo "==> Fingerprint found: ${FINGERPRINT}"
  sed -i "s/^BRIDGE_FINGERPRINT=.*/BRIDGE_FINGERPRINT=${FINGERPRINT}/" .env
  docker compose up -d --build daily-summary
fi

echo ""
echo "=================================================================="
echo " Hardening + stack complete in ${PROJECT_DIR}"
echo " - Tor bridge: ORPort ${OR_PORT} / PT ${PT_PORT}"
echo " - Uptime Kuma: http://127.0.0.1:3001 (access via SSH tunnel)"
echo " - Daily summary: configured (check Telegram)"
echo " Uptime Kuma monitors still need to be set up manually."
echo "=================================================================="