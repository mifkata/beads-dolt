#!/bin/bash
#
# Back up the running dolt server.
#   1. Commit each database through the SQL server (the CLI cannot lock a
#      database the server already has open).
#   2. Commit the git working tree if it is dirty.
#   3. Push to origin only when local main is ahead.
# A failed cycle exits non-zero so the caller retries. Nothing here force-pushes.

set -u

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCK=/tmp/dolt-sync.lock
failed=0

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[$NOW] previous sync still running — skipping"
    exit 0
fi

export GIT_TERMINAL_PROMPT=0

ssh_cmd=(ssh -F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
if [ -f /home/dev/.ssh-run/known_hosts ]; then
    ssh_cmd+=(-o "UserKnownHostsFile=/home/dev/.ssh-run/known_hosts")
fi
key_found=0
for key in /home/dev/.ssh-run/id_ed25519 /home/dev/.ssh-run/id_rsa /home/dev/.ssh-run/id_ecdsa; do
    if [ -r "$key" ]; then
        ssh_cmd+=(-i "$key")
        key_found=1
    fi
done
GIT_SSH_COMMAND=$(printf '%q ' "${ssh_cmd[@]}")
export GIT_SSH_COMMAND

mysql_q() {
    mysql --protocol=TCP -h 127.0.0.1 -P 3307 -u root -N --batch "$@"
}

readme_cell() {
    local value=$1
    value=${value//$'\r'/}
    value=${value//$'\n'/ }
    value=${value//|/\\|}
    if [ -z "$value" ]; then
        printf '%s' "—"
        return
    fi
    printf '%s' "$value"
}

database_link() {
    local db=$1 value sql
    local -a queries=(
        "SELECT value FROM config WHERE \`key\`='sync.remote' LIMIT 1"
        "SELECT value FROM config WHERE \`key\`='github.repo' LIMIT 1"
        "SELECT value FROM config WHERE \`key\`='gitlab.repo' LIMIT 1"
        "SELECT url FROM dolt_remotes WHERE name='origin' LIMIT 1"
        "SELECT path FROM routes LIMIT 1"
        "SELECT repo_path FROM repo_mtimes LIMIT 1"
    )
    for sql in "${queries[@]}"; do
        value=$(mysql_q -e "USE \`$db\`; $sql" 2>/dev/null || true)
        value=${value%%$'\n'*}
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return
        fi
    done
}

update_readme_databases() {
    local readme=/repo/README.md
    local start="<!-- databases:start -->"
    local end="<!-- databases:end -->"
    [ -f "$readme" ] || return 0
    grep -q "$start" "$readme" || return 0

    local err dbs db prefix link rows line blockfile updated
    err=$(mktemp)
    if ! dbs=$(mysql_q -e "SHOW DATABASES" 2>"$err"); then
        echo "[$NOW] readme: cannot list databases: $(cat "$err")"
        rm -f "$err"
        failed=1
        return
    fi
    rm -f "$err"

    rows=""
    for db in $dbs; do
        case "$db" in
            information_schema|mysql|performance_schema|sys) continue ;;
        esac
        if ! [[ "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
            continue
        fi
        prefix=$(mysql_q -e "USE \`$db\`; SELECT value FROM config WHERE \`key\`='issue_prefix' LIMIT 1" 2>/dev/null || true)
        prefix=${prefix%%$'\n'*}
        link=$(database_link "$db")
        if [ -n "$prefix" ]; then
            prefix="\`$(readme_cell "$prefix")\`"
        else
            prefix=$(readme_cell "")
        fi
        line="| \`$db\` | $prefix | $(readme_cell "$link") |"
        rows="${rows}${line}"$'\n'
    done

    blockfile=$(mktemp)
    {
        printf '%s\n' "$start"
        printf '%s\n' "| Database | Issue prefix | Repository |"
        printf '%s\n' "| --- | --- | --- |"
        printf '%s' "$rows"
        printf '%s\n' "$end"
    } > "$blockfile"

    updated=$(mktemp)
    awk -v start="$start" -v end="$end" -v blockfile="$blockfile" '
        $0 == start {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
            skip = 1
            next
        }
        $0 == end { skip = 0; next }
        skip { next }
        { print }
    ' "$readme" > "$updated"

    if cmp -s "$readme" "$updated"; then
        rm -f "$blockfile" "$updated"
        return 0
    fi
    mv "$updated" "$readme"
    rm -f "$blockfile"
    echo "[$NOW] readme: updated database list"
}

flush_dolt() {
    local err dbs db out count
    err=$(mktemp)
    if ! dbs=$(mysql_q -e "SHOW DATABASES" 2>"$err"); then
        echo "[$NOW] dolt: cannot list databases: $(cat "$err")"
        rm -f "$err"
        failed=1
        return
    fi
    rm -f "$err"

    local committed=""
    for db in $dbs; do
        case "$db" in
            information_schema|mysql|performance_schema|sys) continue ;;
        esac
        if ! [[ "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
            echo "[$NOW] dolt: skipping unexpected database name: $db"
            continue
        fi

        # DOLT_COMMIT on a clean database is an error and spams the server log.
        if ! pending=$(mysql_q -e "USE \`$db\`; SELECT COUNT(*) FROM dolt_status;" 2>&1); then
            echo "[$NOW] dolt: $db status failed: $pending"
            failed=1
            continue
        fi
        if [ "$pending" != "0" ]; then
            mysql_q -e "USE \`$db\`; CALL DOLT_ADD('-A');" >/dev/null 2>&1 || true
            if out=$(mysql_q -e "USE \`$db\`; CALL DOLT_COMMIT('-am', 'auto-sync: $NOW');" 2>&1); then
                committed="${committed} ${db}"
            elif ! printf '%s' "$out" | grep -qiE 'nothing to commit|no changes'; then
                echo "[$NOW] dolt: $db commit failed: $out"
                failed=1
            fi
        fi

        if ! count=$(mysql_q -e "USE \`$db\`; SELECT COUNT(*) FROM dolt_remotes WHERE name='origin';" 2>&1); then
            echo "[$NOW] dolt: $db remote check failed: $count"
            failed=1
            continue
        fi
        [ "$count" = "0" ] && continue

        echo "[$NOW] dolt: $db pulling origin"
        if ! out=$(mysql_q -e "USE \`$db\`; CALL DOLT_PULL('origin');" 2>&1); then
            echo "[$NOW] dolt: $db pull failed: $out"
            failed=1
            continue
        fi
        echo "[$NOW] dolt: $db pushing origin"
        if ! out=$(mysql_q -e "USE \`$db\`; CALL DOLT_PUSH('origin', 'main');" 2>&1); then
            echo "[$NOW] dolt: $db push failed (will retry): $out"
            failed=1
        fi
    done

    if [ -n "$committed" ]; then
        echo "[$NOW] dolt committed:${committed}"
    fi
}

git_sync() {
    cd /repo
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qx '/repo'; then
        git config --global --add safe.directory /repo
    fi

    local status
    if ! status=$(git status --porcelain 2>&1); then
        echo "[$NOW] git status failed: $status"
        failed=1
        return
    fi

    if [ -n "$status" ]; then
        echo "[$NOW] git: committing"
        git add -A
        if ! git commit -m "auto-sync: $NOW"; then
            echo "[$NOW] git: commit failed"
            failed=1
            return
        fi
    fi

    if ! git remote get-url origin >/dev/null 2>&1; then
        echo "[$NOW] git: no remote origin — skipping push"
        return
    fi

    if [ "$key_found" -eq 0 ]; then
        echo "[$NOW] git: no readable SSH private key — skipping fetch/push"
        failed=1
        return
    fi

    local fetch_out
    if ! fetch_out=$(timeout 120 git fetch origin main 2>&1); then
        echo "[$NOW] git: fetch failed (will retry): $fetch_out"
        failed=1
    elif [ -n "$fetch_out" ]; then
        echo "$fetch_out"
    fi

    local dirty=0
    if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
        dirty=1
    fi

    if [ "$dirty" -eq 0 ] && git rev-parse --verify --quiet origin/main >/dev/null; then
        if ! git merge-base --is-ancestor origin/main HEAD; then
            echo "[$NOW] git: rebasing onto origin/main"
            if ! git rebase origin/main; then
                echo "[$NOW] git: rebase failed — aborting, will retry"
                git rebase --abort || true
                failed=1
                return
            fi
        fi
    fi

    if ! git rev-parse --verify --quiet origin/main >/dev/null; then
        echo "[$NOW] git: origin/main is missing — skipping push"
        failed=1
        return
    fi

    local ahead
    ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "")
    if [ -z "$ahead" ]; then
        echo "[$NOW] git: cannot compare with origin/main"
        failed=1
        return
    fi
    if [ "$ahead" = "0" ]; then
        if [ -z "$status" ]; then
            echo "[$NOW] git: nothing to commit or push"
        fi
        return
    fi

    echo "[$NOW] git: pushing $ahead commit(s)"
    local push_out
    if ! push_out=$(timeout 600 git push origin HEAD:main 2>&1); then
        echo "[$NOW] git: push failed (will retry): $push_out"
        failed=1
        return
    fi
    [ -n "$push_out" ] && echo "$push_out"
    echo "[$NOW] git: push done"
}

if [ "${1:-}" = "--readme-databases" ]; then
    update_readme_databases
    exit 0
fi

flush_dolt
update_readme_databases
git_sync
exit "$failed"
