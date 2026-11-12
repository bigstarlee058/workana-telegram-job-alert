#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "$EUID" -ne 0 || $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: sudo bash deploy.sh /path/to/source.tar" >&2
  exit 1
fi
if [[ ! -s /etc/workana-bot.env ]]; then
  echo "Install the bot's .env as /etc/workana-bot.env before deploying." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends python3-venv curl
if ! id workana-bot >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/workana-bot --shell /usr/sbin/nologin workana-bot
fi
install -d -m 0755 /opt/workana-bot /opt/workana-bot/releases
install -d -o workana-bot -g workana-bot -m 0750 /var/lib/workana-bot
install -d -o workana-bot -g workana-bot -m 0755 /opt/workana-bot/browsers
chown root:workana-bot /etc/workana-bot.env
chmod 0640 /etc/workana-bot.env

release="$(mktemp -d /opt/workana-bot/releases/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX)"
chmod 0755 "$release"
tar -xf "$1" -C "$release"
chmod -R u=rwX,go=rX "$release"
ln -s /var/lib/workana-bot "$release/data"
python3 -m venv "$release/.venv"
"$release/.venv/bin/python" -m pip install --disable-pip-version-check -r "$release/requirements.txt"
"$release/.venv/bin/python" -m pip check
"$release/.venv/bin/python" -m pip freeze > "$release/requirements-installed.txt"
chmod -R u=rwX,go=rX "$release/.venv"
export PLAYWRIGHT_BROWSERS_PATH=/opt/workana-bot/browsers
"$release/.venv/bin/python" -m playwright install-deps chromium
runuser -u workana-bot -- env PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
  "$release/.venv/bin/python" -m playwright install chromium

# Fetch and check Telegram permissions before switching the running release.
runuser -u workana-bot -- env PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
  PYTHONDONTWRITEBYTECODE=1 \
  timeout --kill-after=10 420 "$release/.venv/bin/python" "$release/deploy/verify_runtime.py" --live

previous="$(readlink -f /opt/workana-bot/current || true)"
ln -sfnT "$release" /opt/workana-bot/current.next
mv -Tf /opt/workana-bot/current.next /opt/workana-bot/current
install -m 0644 "$release/deploy/workana-bot.service" /etc/systemd/system/workana-bot.service
systemctl daemon-reload
systemctl enable workana-bot
systemctl restart workana-bot

if ! "$release/.venv/bin/python" "$release/deploy/verify_runtime.py" --service --wait 420; then
  systemctl stop workana-bot
  if [[ -n "$previous" && "$previous" != "$release" ]]; then
    ln -sfnT "$previous" /opt/workana-bot/current.next
    mv -Tf /opt/workana-bot/current.next /opt/workana-bot/current
    systemctl start workana-bot
    echo "Restored the previous release." >&2
  fi
  exit 1
fi
echo "Deployed $release"
