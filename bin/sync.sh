#!/bin/bash
#
# Back up the running dolt server.
#   1. Commit each database through the SQL server (the CLI cannot lock a
#      database the server already has open), dump it as SQL text into
#      backups/<database>.sql, then garbage-collect it.
#   2. Commit the git working tree if it is dirty.
#   3. Keep the newest BACKUP_KEEP auto-sync commits: older ones are folded
#      into the commit that follows them.
#   4. Push to origin only when local main is ahead. After a fold the push is
#      forced with a lease on the fetched origin/main.
# A failed cycle exits non-zero so the caller retries.

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

is_system() {
    case "$1" in
        information_schema|mysql|performance_schema|sys) return 0 ;;
        *) return 1 ;;
    esac
}

is_beads() {
    local db=$1 found
    found=$(mysql_q --database="$db" -e "SELECT 1 FROM config WHERE \`key\`='issue_prefix' LIMIT 1" 2>/dev/null || true)
    [ -n "$found" ]
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
        value=$(mysql_q --database="$db" -e "$sql" 2>/dev/null || true)
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
    while IFS= read -r db || [ -n "$db" ]; do
        [ -n "$db" ] || continue
        if is_system "$db"; then
            continue
        fi
        if ! is_beads "$db"; then
            echo "skipping: $db" >&2
            continue
        fi
        prefix=$(mysql_q --database="$db" -e "SELECT value FROM config WHERE \`key\`='issue_prefix' LIMIT 1" 2>/dev/null || true)
        prefix=${prefix%%$'\n'*}
        link=$(database_link "$db")
        if [ -n "$prefix" ]; then
            prefix="\`$(readme_cell "$prefix")\`"
        else
            prefix=$(readme_cell "")
        fi
        line="| \`$db\` | $prefix | $(readme_cell "$link") |"
        rows="${rows}${line}"$'\n'
    done <<< "$dbs"

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

backup_dolt() {
    local db=$1 tmp out
    tmp=$(mktemp -d)
    # One row per INSERT line, so git stores only the rows that changed.
    if ! out=$(cd "/data/$db" && dolt dump -r sql --no-batch -fn "$tmp/dump.sql" 2>&1); then
        echo "[$NOW] dolt: $db dump failed: $out"
        rm -rf "$tmp"
        failed=1
        return
    fi
    mkdir -p /repo/backups
    mv "$tmp/dump.sql" "/repo/backups/$db.sql"
    rm -rf "$tmp"
    if ! out=$(mysql_q --database="$db" -e "CALL DOLT_GC();" 2>&1); then
        echo "[$NOW] dolt: $db gc failed: $out"
        failed=1
    fi
}

flush_dolt() {
    local err dbs db out
    err=$(mktemp)
    if ! dbs=$(mysql_q -e "SHOW DATABASES" 2>"$err"); then
        echo "[$NOW] dolt: cannot list databases: $(cat "$err")"
        rm -f "$err"
        failed=1
        return
    fi
    rm -f "$err"

    local committed=""
    while IFS= read -r db || [ -n "$db" ]; do
        [ -n "$db" ] || continue
        if is_system "$db"; then
            continue
        fi
        if ! is_beads "$db"; then
            echo "skipping: $db" >&2
            continue
        fi

        # DOLT_COMMIT on a clean database is an error and spams the server log.
        if ! pending=$(mysql_q --database="$db" -e "SELECT COUNT(*) FROM dolt_status;" 2>&1); then
            echo "[$NOW] dolt: $db status failed: $pending"
            failed=1
            continue
        fi
        if [ "$pending" != "0" ]; then
            mysql_q --database="$db" -e "CALL DOLT_ADD('-A');" >/dev/null 2>&1 || true
            if out=$(mysql_q --database="$db" -e "CALL DOLT_COMMIT('-am', 'auto-sync: $NOW');" 2>&1); then
                committed="${committed} ${db}"
            elif ! printf '%s' "$out" | grep -qiE 'nothing to commit|no changes'; then
                echo "[$NOW] dolt: $db commit failed: $out"
                failed=1
            fi
        fi

        backup_dolt "$db"
    done <<< "$dbs"

    if [ -n "$committed" ]; then
        echo "[$NOW] dolt committed:${committed}"
    fi
}

fold_history() {
    local keep=${BACKUP_KEEP:-50} commit tree parent="" old msg
    local -a autos
    local -A drop=()
    if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
        echo "[$NOW] git: BACKUP_KEEP must be a positive number (got '$keep') — not folding"
        return 1
    fi
    if [ "$(git symbolic-ref --short -q HEAD)" != "main" ] || [ -n "$(git rev-list --merges HEAD)" ]; then
        return 1
    fi
    mapfile -t autos < <(git log --format='%H %s' HEAD | awk '$2 == "auto-sync:" {print $1}')
    [ "${#autos[@]}" -gt "$keep" ] || return 1
    for commit in "${autos[@]:$keep}"; do
        drop[$commit]=1
    done
    old=$(git rev-parse HEAD)
    while IFS= read -r commit; do
        [ -n "${drop[$commit]:-}" ] && continue
        tree=$(git rev-parse "$commit^{tree}")
        msg=$(git log -1 --format=%B "$commit")
        if ! parent=$(printf '%s\n' "$msg" | \
            GIT_AUTHOR_NAME=$(git log -1 --format=%an "$commit") \
            GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$commit") \
            GIT_AUTHOR_DATE=$(git log -1 --format=%aI "$commit") \
            GIT_COMMITTER_NAME=$(git log -1 --format=%cn "$commit") \
            GIT_COMMITTER_EMAIL=$(git log -1 --format=%ce "$commit") \
            GIT_COMMITTER_DATE=$(git log -1 --format=%cI "$commit") \
            git commit-tree "$tree" ${parent:+-p "$parent"}); then
            echo "[$NOW] git: fold failed at $commit"
            failed=1
            return 1
        fi
    done < <(git rev-list --reverse HEAD)
    if ! git diff --quiet "$old" "$parent"; then
        echo "[$NOW] git: folded tree differs from HEAD — not folding"
        failed=1
        return 1
    fi
    git update-ref -m "fold auto-sync history" refs/heads/main "$parent" "$old"
    echo "[$NOW] git: folded ${#drop[@]} auto-sync commit(s), keeping the newest $keep"
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
        local oversized="" path bytes
        while IFS= read -r -d '' path; do
            bytes=$(wc -c < "$path" 2>/dev/null || echo 0)
            bytes=${bytes//[[:space:]]/}
            if [ "${bytes:-0}" -ge 100000000 ]; then
                oversized="${oversized}
${path} (${bytes} bytes)"
            fi
        done < <(git ls-files -co --exclude-standard -z)
        if [ -n "$oversized" ]; then
            echo "[$NOW] git: not committing. GitHub rejects a file of 100 MB or more:${oversized}"
            failed=1
            return
        fi
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
            if git merge-base --is-ancestor HEAD origin/main; then
                echo "[$NOW] git: rebasing onto origin/main"
                if ! git rebase origin/main; then
                    echo "[$NOW] git: rebase failed — aborting, will retry"
                    git rebase --abort || true
                    failed=1
                    return
                fi
            else
                echo "[$NOW] git: history has diverged from origin/main — not rebasing or pushing"
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

    local push_out lease
    if git merge-base --is-ancestor origin/main HEAD && fold_history; then
        lease=$(git rev-parse origin/main)
        echo "[$NOW] git: force-pushing folded history"
        if ! push_out=$(timeout 600 git push --force-with-lease="main:$lease" origin HEAD:main 2>&1); then
            echo "[$NOW] git: push failed (will retry): $push_out"
            failed=1
            return
        fi
        [ -n "$push_out" ] && echo "$push_out"
        git reflog expire --expire=now --all
        git gc --prune=now --quiet
        echo "[$NOW] git: push done"
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
