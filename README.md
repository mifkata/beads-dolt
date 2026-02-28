# Beads Dolt

Dolt SQL server running in Docker with automatic sync (commit, pull, push) every hour.

## Table of contents

- [Quick start](#quick-start)
- [Makefile commands](#makefile-commands)
- [How it works](#how-it-works)
- [Adding remotes](#adding-remotes)
- [Beads configuration](#beads-configuration)
- [SSH keys](#ssh-keys)
- [Volumes](#volumes)
- [Customisation](#customisation)
  - [Server config](#server-config)
  - [Port](#port)
  - [Sync frequency](#sync-frequency)
  - [Sync logs](#sync-logs)
  - [Dolt author](#dolt-author)
- [Resolving merge conflicts](#resolving-merge-conflicts)
- [License](#license)

## Quick start

Fork this repository and clone your fork locally. Your fork should be **private** since it will contain your database data.

```bash
git clone git@github.com:<you>/beads-dolt.git
cd beads-dolt
make start
```

Or directly with docker compose:

```bash
docker compose up -d
```

Connect to the database:

```bash
make mysql
```

From another Docker container, connect via `host.docker.internal:3307` — no extra network configuration needed.

## Makefile commands

| Command | Description |
|---------|-------------|
| `make start` | Start the server in the background |
| `make stop` | Stop and remove the container |
| `make build` | Build the Docker image |
| `make rebuild` | Build from scratch (no cache) |
| `make restart` | Stop then start |
| `make shell` | Open a bash shell in the container |
| `make mysql` | Connect to the dolt server via mysql |
| `make logs` | Tail the sync log |

## How it works

The container runs two things:

1. **Dolt SQL server** on port 3307 — serves all databases found in `./data`
2. **Sync loop** (on startup, then every hour) — commits git repo changes, then for each dolt database commits local changes, pulls from remote, pushes to remote

### Sync strategy

The sync script (`bin/sync.sh`) avoids collisions between multiple users by following this order:

1. **Commit** any uncommitted local changes
2. **Pull** from remote — dolt merges at the row level, so concurrent edits to different rows merge cleanly
3. **Push** to remote — if it fails (someone else pushed in between), the next cycle retries

If a pull produces a merge conflict (two users edited the same row), the script logs a warning and skips push until the conflict is resolved manually.

## Adding remotes

Remotes enable sync between multiple users. Without a remote configured, the cron job only commits locally.

### Via dolt CLI (recommended)

Run from each database directory:

```bash
cd data/<database>
dolt remote add origin https://doltremoteapi.dolthub.com/<org>/<database>
```

SSH remote:

```bash
cd data/<database>
dolt remote add origin ssh://git@github.com:<org>/<database>.git
```

Verify:

```bash
cd data/<database>
dolt remote -v
```

### Via SQL

If the server is already running, you can add remotes through SQL instead:

```sql
USE <database>;
CALL dolt_remote('add', 'origin', 'https://doltremoteapi.dolthub.com/<org>/<database>');
```

SSH remote:

```sql
USE <database>;
CALL dolt_remote('add', 'origin', 'ssh://git@github.com:<org>/<database>.git');
```

Verify:

```sql
SELECT * FROM dolt_remotes;
```

Once a remote named `origin` exists, the cron job handles pull/push automatically.

## Beads configuration

To use the same hostname (`host.docker.internal`) from both the host and other containers, add it to your `/etc/hosts`:

```bash
echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts
```

Then configure `bd` to use it:

```bash
bd dolt set host host.docker.internal
bd dolt set port 3307
bd dolt set user root
bd dolt set database <database>
```

View current config and connection status:

```bash
bd dolt show
```

Once connected, `bd` can commit, push, and pull directly:

```bash
bd dolt commit
bd dolt push
bd dolt pull
```

## SSH keys

Your host `.ssh` directory is mounted into the container at `/home/dev/.ssh`. Any SSH keys available on the host are usable by dolt for remote operations — no extra setup needed.

## Volumes

| Host | Container | Purpose |
|------|-----------|---------|
| `./data` | `/data` | Dolt databases and server config |
| `.` | `/repo` | Full git repository |
| `.ssh` | `/home/dev/.ssh` | SSH keys for remote sync |

## Customisation

### Server config

Edit `data/config.yaml` to change dolt sql-server settings (logging, TLS, max connections, etc.). The server reads this file from `/data` on startup. See the [dolt server configuration docs](https://docs.dolthub.com/sql-reference/server/configuration) for all options.

### Port

Set `DOLT_PORT` to change the server port. Defaults to `3307`.

```bash
DOLT_PORT=3308 make start
```

Or set it in your environment before running any make command.

### Sync frequency

Set `SYNC_SCHEDULE` to a cron expression. Defaults to `0 * * * *` (every hour).

```bash
# Every 5 minutes
SYNC_SCHEDULE="*/5 * * * *" make start

# Every 6 hours
SYNC_SCHEDULE="0 */6 * * *" make start
```

Or set it in your environment before running any make command.

### Sync logs

View sync logs:

```bash
make logs
```

### Dolt author

The default commit author is `dev <dev@dolt.local>`. To change it, edit the `dolt config` lines in the `Dockerfile` and rebuild.

## Resolving merge conflicts

If the sync log shows conflicts:

```bash
make mysql
```

```sql
USE <database>;

-- View conflicted tables
SELECT * FROM dolt_conflicts;

-- View conflict details for a specific table
SELECT * FROM dolt_conflicts_<table_name>;

-- Resolve by accepting ours (local) or theirs (remote)
CALL dolt_conflicts_resolve('--ours', '<table_name>');
-- or
CALL dolt_conflicts_resolve('--theirs', '<table_name>');

-- Commit the resolution
CALL dolt_commit('-am', 'resolve merge conflict');
```

The next sync cycle will push the resolution.

## License

[MIT](LICENSE)
