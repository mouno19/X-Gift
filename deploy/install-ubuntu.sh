#!/bin/bash
# XGift installer for an Ubuntu server that already runs Caddy (systemd package).
#
#   sudo bash deploy/install-ubuntu.sh <hostname> [release-tarball]
#
# <hostname>        public HTTPS hostname pointing at this server, e.g. xp.example.com
#                   (no domain yet? use <name>.<ip-with-dashes>.sslip.io)
# [release-tarball] defaults to /tmp/xgift-linux-amd64-v1.0.0.tar.gz from the GitHub release
#
# Safe to re-run. Installs to /opt/xgift, /etc/xgift, /var/lib/xgift with payments OFF,
# and touches no other service except a validated, graceful Caddy reload that only
# appends the XGift site block. The site is online at the end; then add your
# private settings (X cookies, Stripe key, cards) with: sudo xgift-credentials
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: sudo bash $0 <hostname> [release-tarball]"; exit 1; }
TARBALL="${2:-/tmp/xgift-linux-amd64-v1.0.0.tar.gz}"
[ -f "$TARBALL" ] || { echo "release tarball not found: $TARBALL"; exit 1; }
command -v caddy >/dev/null || { echo "caddy is not installed (https://caddyserver.com/docs/install)"; exit 1; }
TS="$(date +%Y%m%d%H%M%S)"

echo "== 1. service user"
if ! id xgift >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /var/lib/xgift --shell /usr/sbin/nologin xgift
fi
id xgift

echo "== 2. directories"
install -d -o root  -g root  -m 0755 /opt/xgift /opt/xgift/bin
install -d -o xgift -g xgift -m 0700 /etc/xgift /var/lib/xgift
# Lets `xgift <command>` find /var/lib/xgift/vault.db without --db.
ln -sfn /var/lib/xgift /opt/xgift/sqlite

echo "== 3. binaries + deploy files"
rm -rf /tmp/xgift-extract && mkdir -p /tmp/xgift-extract
tar -xzf "$TARBALL" -C /tmp/xgift-extract
SRC=/tmp/xgift-extract/xgift-linux-amd64
for b in xgift xgift-web xpg; do install -o root -g root -m 0755 "$SRC/bin/$b" /opt/xgift/bin/$b; done
rm -rf /opt/xgift/deploy /opt/xgift/docs
cp -r "$SRC/deploy" "$SRC/docs" /opt/xgift/
cp "$SRC/README.md" "$SRC/README.zh-CN.md" "$SRC/LICENSE" /opt/xgift/
basename "$TARBALL" .tar.gz > /opt/xgift/VERSION
rm -rf /tmp/xgift-extract

echo "== 4. admin password + site.env (payments OFF)"
if [ ! -s /etc/xgift/admin-password ]; then
  ( umask 077; head -c 36 /dev/urandom | base64 | tr -d '\n=+/' | head -c 40 > /etc/xgift/admin-password; echo >> /etc/xgift/admin-password )
fi
chown xgift:xgift /etc/xgift/admin-password && chmod 0600 /etc/xgift/admin-password
if [ ! -f /etc/xgift/site.env ]; then
  ( umask 077; cat > /etc/xgift/site.env <<EOF
XGIFT_ORIGIN=https://$HOST
XGIFT_LISTEN=127.0.0.1:8787
XGIFT_DATA_DIR=/var/lib/xgift
XGIFT_PASSWORD_FILE=/etc/xgift/vault-password
XGIFT_ADMIN_PASSWORD_FILE=/etc/xgift/admin-password
XGIFT_PAYMENTS_ENABLED=false
XGIFT_TURNSTILE_SITE_KEY=
XGIFT_TURNSTILE_SECRET_FILE=
EOF
  )
fi
chown root:root /etc/xgift/site.env && chmod 0600 /etc/xgift/site.env

echo "== 5. CLI wrapper /usr/local/bin/xgift"
cat > /usr/local/bin/xgift <<'EOF'
#!/bin/sh
# Runs the XGift admin CLI as the xgift service user against /var/lib/xgift/vault.db.
cd /opt/xgift || exit 1
exec sudo -u xgift /usr/bin/env XGIFT_PASSWORD_FILE=/etc/xgift/vault-password /opt/xgift/bin/xgift "$@"
EOF
chmod 0755 /usr/local/bin/xgift

echo "== 6. English settings helper (xgift-credentials)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/xgift-credentials.sh" ]; then
  install -o root -g root -m 0755 "$HERE/xgift-credentials.sh" /usr/local/bin/xgift-credentials
elif [ -f /opt/xgift/deploy/xgift-credentials.sh ]; then
  install -o root -g root -m 0755 /opt/xgift/deploy/xgift-credentials.sh /usr/local/bin/xgift-credentials
else
  curl -fsSL https://raw.githubusercontent.com/mouno19/X-Gift/main/deploy/xgift-credentials.sh -o /usr/local/bin/xgift-credentials
  chmod 0755 /usr/local/bin/xgift-credentials
fi
# Older instructions referred to finish-setup.sh; keep it as a shim.
printf '#!/bin/sh\nexec /usr/local/bin/xgift-credentials "$@"\n' > /opt/xgift/finish-setup.sh
chmod 0755 /opt/xgift/finish-setup.sh

echo "== 7. vault with non-secret defaults (X web Bearer/UA, direct network, default catalog)"
if [ ! -e /var/lib/xgift/vault.db ]; then
  [ -e /etc/xgift/vault-password ] && { echo "vault-password exists without a vault; refusing"; exit 1; }
  sudo -u xgift sh -c 'umask 077; head -c 32 /dev/urandom | base64 | tr "+/" "-_" | tr -d "=\n" > /etc/xgift/vault-password; echo >> /etc/xgift/vault-password'
  cat <<'JSON' | sudo -u xgift /opt/xgift/bin/xgift init --db /var/lib/xgift/vault.db --password-file /etc/xgift/vault-password
{
  "api-auth": {
    "Authorization": "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA",
    "UserAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
  },
  "proxy": {"outbounds": [{"type": "direct", "tag": "direct"}]},
  "catalog": {
    "merchant": "acct_1Ika5JA3KZ32dPo1",
    "currency": "bdt",
    "plans": [
      {"months": 3, "amount": 30000, "product": "prod_TJXJtpzqCpI36N"},
      {"months": 6, "amount": 60000, "product": "prod_TJXKKNJwZJIhCM"}
    ]
  }
}
JSON
else
  echo "vault already exists - keeping it"
fi

echo "== 7b. systemd unit (started now; payments stay OFF)"
install -o root -g root -m 0644 /opt/xgift/deploy/xgift.service /etc/systemd/system/xgift.service
systemctl daemon-reload
systemctl enable xgift >/dev/null 2>&1
systemctl restart xgift
sleep 3
systemctl is-active xgift
curl -fsS http://127.0.0.1:8787/healthz; echo

echo "== 8. Caddy site block"
CF=/etc/caddy/Caddyfile
if ! grep -q "^$HOST {" "$CF"; then
  cp -p "$CF" "/etc/caddy/Caddyfile.bak.xgift.$TS"
  cat >> "$CF" <<EOF

# ---------------------------------------------------------------------------
# XGift (github.com/mouno19/X-Gift) -> xgift.service on 127.0.0.1:8787
# Config: /etc/xgift/site.env   Data: /var/lib/xgift   Binaries: /opt/xgift/bin
# Rollback: sudo cp /etc/caddy/Caddyfile.bak.xgift.$TS /etc/caddy/Caddyfile && sudo systemctl reload caddy
# ---------------------------------------------------------------------------
$HOST {
	encode zstd gzip
	header Strict-Transport-Security "max-age=31536000"
	reverse_proxy 127.0.0.1:8787 {
		# Let existing queue polls survive a short backend restart.
		lb_try_duration 30s
		lb_try_interval 250ms
		lb_retry_match method GET
		header_up X-Real-IP {remote_host}
	}
	log {
		output file /var/log/caddy/xgift.log {
			roll_size 10MiB
			roll_keep 5
		}
	}
}
EOF
  # Create the log file as the caddy user first; otherwise a root-run validate
  # creates it root-owned and the reload fails with "permission denied".
  install -d -o caddy -g caddy -m 0755 /var/log/caddy
  [ -e /var/log/caddy/xgift.log ] || install -o caddy -g caddy -m 0640 /dev/null /var/log/caddy/xgift.log
  chown caddy:caddy /var/log/caddy/xgift.log
  if caddy validate --config "$CF" --adapter caddyfile >/tmp/xgift-caddy-validate.log 2>&1; then
    systemctl reload caddy
    echo "caddy reloaded (backup: /etc/caddy/Caddyfile.bak.xgift.$TS)"
  else
    cat /tmp/xgift-caddy-validate.log | tail -5
    cp -p "/etc/caddy/Caddyfile.bak.xgift.$TS" "$CF"
    echo "caddy validation FAILED - original Caddyfile restored, caddy not reloaded"
    exit 1
  fi
else
  echo "site block already present"
fi
systemctl is-active caddy

echo "== done"
echo "Site: https://$HOST  (admin: https://$HOST/admin, user admin, password: sudo cat /etc/xgift/admin-password)"
echo "Next: sudo xgift-credentials   (add X cookies, Stripe key and cards; then turn payments on)"
echo "BACK UP /etc/xgift/vault-password - without it the vault cannot be decrypted."
ls -la /opt/xgift /opt/xgift/bin /etc/xgift /var/lib/xgift
