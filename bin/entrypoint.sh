#!/bin/bash
set -e

# Add GitHub/GitLab host keys to known_hosts if not already present
gosu dev bash -c 'mkdir -p ~/.ssh && ssh-keyscan -t ed25519,rsa github.com gitlab.com >> ~/.ssh/known_hosts 2>/dev/null'

# Install crontab from SYNC_SCHEDULE env var
echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${SYNC_SCHEDULE:-0 * * * *} /usr/local/bin/sync.sh >> /tmp/dolt-sync.log 2>&1
" | crontab -u dev -

cron

cd /data

# Start dolt in the background to run init queries
gosu dev dolt sql-server --host 0.0.0.0 --port "${DOLT_PORT:-3307}" &
DOLT_PID=$!

# Wait for server to be ready
until mysql -h 127.0.0.1 -P "${DOLT_PORT:-3307}" -u root -e "SELECT 1" >/dev/null 2>&1; do
    sleep 0.5
done

# Allow connections from any host (not just localhost) so external clients can connect
mysql -h 127.0.0.1 -P "${DOLT_PORT:-3307}" -u root -e "
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
"

# Initial sync on startup
gosu dev /usr/local/bin/sync.sh 2>&1 | tee -a /tmp/dolt-sync.log

# Keep the server process in the foreground
wait $DOLT_PID
