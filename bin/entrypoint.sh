#!/bin/bash
set -euo pipefail

# Debian cron cannot run user jobs here: /etc/pam.d/cron requires pam_loginuid,
# and that module fails in a container, so the job is skipped with no log line.
# A loop is the schedule.

INTERVAL="${SYNC_INTERVAL:-60}"
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
    echo "SYNC_INTERVAL must be a positive number of seconds (got '${SYNC_INTERVAL:-}')"
    exit 1
fi
if [ -n "${SYNC_SCHEDULE:-}" ]; then
    echo "SYNC_SCHEDULE is ignored. Sync runs every ${INTERVAL}s (SYNC_INTERVAL)."
fi

# The host key directory is bind-mounted and mode 600 under the host uid.
# Copy it so the container user can actually read the private key.
rm -rf /home/dev/.ssh-run
mkdir -p /home/dev/.ssh-run
if [ -d /home/dev/.ssh ]; then
    cp -a /home/dev/.ssh/. /home/dev/.ssh-run/
fi
touch /home/dev/.ssh-run/known_hosts
ssh-keyscan -t ed25519,rsa github.com gitlab.com >> /home/dev/.ssh-run/known_hosts 2>/dev/null || true
chown -R dev:dev /home/dev/.ssh-run
chmod 700 /home/dev/.ssh-run
find /home/dev/.ssh-run -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} +
chmod 644 /home/dev/.ssh-run/known_hosts 2>/dev/null || true

if ! gosu dev bash -c 'for k in /home/dev/.ssh-run/id_ed25519 /home/dev/.ssh-run/id_rsa /home/dev/.ssh-run/id_ecdsa; do [ -r "$k" ] && exit 0; done; exit 1'; then
    echo "WARNING: no SSH private key in /home/dev/.ssh — git push will fail"
fi

gosu dev git config --global user.name "dev"
gosu dev git config --global user.email "dev@dolt.local"
if ! gosu dev git config --global --get-all safe.directory 2>/dev/null | grep -qx '/repo'; then
    gosu dev git config --global --add safe.directory /repo
fi

cd /data
gosu dev dolt sql-server --host 0.0.0.0 --port 3307 &
DOLT_PID=$!
SLEEP_PID=

stop() {
    if [ -n "${SLEEP_PID}" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
    if [ -n "${DOLT_PID}" ]; then
        kill "$DOLT_PID" 2>/dev/null || true
    fi
}
trap stop EXIT INT TERM

until mysql --protocol=TCP -h 127.0.0.1 -P 3307 -u root -e "SELECT 1" >/dev/null 2>&1; do
    if ! kill -0 "$DOLT_PID" 2>/dev/null; then
        echo "dolt sql-server exited before it was ready"
        exit 1
    fi
    sleep 0.5
done

mysql --protocol=TCP -h 127.0.0.1 -P 3307 -u root -e "
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
"

echo "sync interval: ${INTERVAL}s"

while kill -0 "$DOLT_PID" 2>/dev/null; do
    cycle_start=$(date +%s)
    if ! gosu dev /usr/local/bin/sync.sh 2>&1 | tee -a /tmp/dolt-sync.log; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] sync cycle failed — will retry" | tee -a /tmp/dolt-sync.log
    fi
    elapsed=$(( $(date +%s) - cycle_start ))
    remain=$(( INTERVAL - elapsed ))
    # A cycle that overruns the interval (a large push) retries after a short
    # pause instead of spinning. A fast cycle waits out the rest of the minute.
    if [ "$remain" -lt 5 ]; then
        remain=5
    fi
    sleep "$remain" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=
done

wait "$DOLT_PID" || true
