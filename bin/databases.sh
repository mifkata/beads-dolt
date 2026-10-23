#!/bin/bash
# List databases, list their issues, count them, or drop one database after the name is typed.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
Usage:
  databases.sh list
  databases.sh issues [--no-color] [database]
  databases.sh stats [--no-color]
  databases.sh purge <database>

Issue lines use color in a terminal. --no-color, or a set NO_COLOR variable, prints plain text.
purge drops one database. Type that database's name when asked.
EOF
}

# Bright colors for a dark terminal: cyan id, status by state, magenta type.
use_color=1
if [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
    use_color=0
fi
positional=()
for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        use_color=0
        continue
    fi
    positional+=("$arg")
done
if [ "${#positional[@]}" -gt 0 ]; then
    set -- "${positional[@]}"
else
    set --
fi

mysql_q() {
    docker compose exec -T dolt mysql --protocol=TCP -h 127.0.0.1 -P 3307 -u root -N --batch "$@" </dev/null
}

is_name() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

is_system() {
    case "$1" in
        information_schema|mysql|performance_schema|sys) return 0 ;;
        *) return 1 ;;
    esac
}

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

paint() {
    local code=$1 text=$2
    if [ "$use_color" -eq 1 ]; then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

status_sgr() {
    case "$1" in
        open) printf '93' ;;
        in_progress) printf '94' ;;
        blocked) printf '91' ;;
        closed) printf '92' ;;
        *) printf '97' ;;
    esac
}

user_databases() {
    local dbs db
    dbs=$(mysql_q -e "SHOW DATABASES") || return 1
    for db in $dbs; do
        if is_system "$db"; then
            continue
        fi
        if ! is_name "$db"; then
            echo "skipping unexpected database name: $db" >&2
            continue
        fi
        printf '%s\n' "$db"
    done
}

config_value() {
    local db=$1 key=$2 value
    value=$(mysql_q -e "USE \`$db\`; SELECT value FROM config WHERE \`key\`='$key' LIMIT 1" 2>/dev/null || true)
    value=${value%%$'\n'*}
    value=${value%$'\r'}
    printf '%s' "$value"
}

prefix_of() {
    local value
    value=$(config_value "$1" issue_prefix)
    if [ -z "$value" ]; then
        printf '%s' "—"
        return
    fi
    printf '%s' "$value"
}

repo_of() {
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
        value=${value%$'\r'}
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return
        fi
    done
    printf '%s' "—"
}

require_database() {
    local only=$1 name
    if is_name "$only"; then
        while IFS= read -r name; do
            if [ "$name" = "$only" ]; then
                return 0
            fi
        done < <(user_databases)
    fi
    echo "Database $only was not found. Available options:" >&2
    cmd_list >&2
    exit 1
}

cmd_list() {
    local db prefix repo
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        prefix=$(prefix_of "$db")
        repo=$(repo_of "$db")
        printf '%-24s %-12s %s\n' "$db" "$prefix" "$repo"
    done < <(user_databases)
}

print_issue() {
    local db=$1 id=$2 status=$3 priority=$4 type=$5 title=$6
    local shown=$id
    if [ -n "$db" ]; then
        shown="$db/$id"
    fi
    printf '%s [%s][P%s](%s): %s\n' \
        "$(paint 96 "$shown")" \
        "$(paint "$(status_sgr "$status")" "$(upper "$status")")" \
        "$priority" \
        "$(paint 95 "$type")" \
        "$title"
}

cmd_issues() {
    local only=${1:-} db prefix err rows line id status priority type title
    if [ -n "$only" ]; then
        require_database "$only"
    fi
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        if [ -n "$only" ] && [ "$db" != "$only" ]; then
            continue
        fi
        err=$(mktemp)
        if ! rows=$(mysql_q -e "USE \`$db\`; SELECT id, status, priority, issue_type, REPLACE(REPLACE(title, CHAR(9), ' '), CHAR(10), ' ') FROM issues ORDER BY id" 2>"$err"); then
            prefix=$(prefix_of "$db")
            echo "# $db $prefix"
            echo "no issues table: $(head -n 1 "$err")"
            rm -f "$err"
            continue
        fi
        rm -f "$err"
        if [ -z "$rows" ]; then
            continue
        fi
        while IFS= read -r line; do
            IFS=$'\t' read -r id status priority type title <<<"$line"
            if [ -z "$only" ]; then
                print_issue "$db" "$id" "$status" "$priority" "$type" "$title"
            else
                print_issue "" "$id" "$status" "$priority" "$type" "$title"
            fi
        done <<<"$rows"
    done < <(user_databases)
}

append_counts() {
    local db=$1 kind=$2 rows=$3 line key count
    [ -n "$rows" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$'\t' read -r key count <<<"$line"
        if [ "$kind" = status ]; then
            key=$(upper "$key")
        fi
        printf '%s\t%s\t%s\t%s\n' "$db" "$kind" "$key" "$count" >> "$stats_file"
    done <<<"$rows"
}

print_stats_table() {
    awk -F '\t' -v bold="$use_color" '
        function srank(s) {
            if (s == "OPEN") return 1
            if (s == "IN_PROGRESS") return 2
            if (s == "BLOCKED") return 3
            if (s == "DEFERRED") return 4
            if (s == "CLOSED") return 5
            return 9
        }
        function fit(col, text) {
            text = text ""
            if (length(text) > width[col]) width[col] = length(text)
        }
        function field(col, text, right,    i, n, out) {
            text = text ""
            n = width[col] - length(text)
            out = ""
            if (right) {
                for (i = 0; i < n; i++) out = out " "
                out = out text
            } else {
                out = text
                for (i = 0; i < n; i++) out = out " "
            }
            return out
        }
        function repeat(ch, n,    i, s) {
            s = ""
            for (i = 0; i < n; i++) s = s ch
            return s
        }
        function rule(left, mid, right,    c, line) {
            line = left
            for (c = 1; c <= ncols; c++) {
                line = line repeat("─", width[c] + 2)
                if (c < ncols) line = line mid
            }
            return line right
        }
        function join_row(numeric,    c, line) {
            line = "│"
            for (c = 1; c <= ncols; c++) line = line " " field(c, cells[c], numeric && c > 1) " │"
            return line
        }
        function show(text, do_bold) {
            if (do_bold && bold) print "\033[1m" text "\033[0m"
            else print text
        }
        {
            if (!($1 in dbseen)) {
                dbseen[$1] = 1
                dbs[++ndb] = $1
            }
            if ($2 == "status") {
                if (!($3 in sseen)) {
                    sseen[$3] = 1
                    statuses[++ns] = $3
                }
                sc[$1, $3] = $4 + 0
            } else if ($2 == "priority") {
                if (!($3 in pseen)) {
                    pseen[$3] = 1
                    priorities[++np] = $3
                }
                pc[$1, $3] = $4 + 0
            } else if ($2 == "total") {
                total[$1] = $4 + 0
            }
        }
        function sort_statuses(    i, j, tmp) {
            for (i = 1; i <= ns; i++) {
                for (j = i + 1; j <= ns; j++) {
                    if (srank(statuses[j]) < srank(statuses[i]) || (srank(statuses[j]) == srank(statuses[i]) && statuses[j] < statuses[i])) {
                        tmp = statuses[i]
                        statuses[i] = statuses[j]
                        statuses[j] = tmp
                    }
                }
            }
        }
        function sort_priorities(    i, j, tmp) {
            for (i = 1; i <= np; i++) {
                for (j = i + 1; j <= np; j++) {
                    if (priorities[j] + 0 < priorities[i] + 0) {
                        tmp = priorities[i]
                        priorities[i] = priorities[j]
                        priorities[j] = tmp
                    }
                }
            }
        }
        function status_sum(name,    d, sum) {
            sum = 0
            for (d = 1; d <= ndb; d++) sum += sc[dbs[d], name]
            return sum
        }
        function priority_sum(name,    d, sum) {
            sum = 0
            for (d = 1; d <= ndb; d++) sum += pc[dbs[d], name]
            return sum
        }
        function total_sum(    d, sum) {
            sum = 0
            for (d = 1; d <= ndb; d++) sum += total[dbs[d]]
            return sum
        }
        function measure_row(db,    col, i) {
            fit(1, db)
            col = 2
            for (i = 1; i <= ns; i++) fit(col++, sc[db, statuses[i]] + 0)
            for (i = 1; i <= np; i++) fit(col++, pc[db, priorities[i]] + 0)
            fit(col, total[db] + 0)
        }
        END {
            if (ndb == 0) exit
            sort_statuses()
            sort_priorities()
            headers[++ncols] = "Database"
            for (i = 1; i <= ns; i++) headers[++ncols] = statuses[i]
            for (i = 1; i <= np; i++) headers[++ncols] = "P" priorities[i]
            headers[++ncols] = "Total"
            for (c = 1; c <= ncols; c++) width[c] = length(headers[c])
            for (d = 1; d <= ndb; d++) measure_row(dbs[d])
            fit(1, "Total")
            col = 2
            for (i = 1; i <= ns; i++) fit(col++, status_sum(statuses[i]))
            for (i = 1; i <= np; i++) fit(col++, priority_sum(priorities[i]))
            fit(col, total_sum())
            show(rule("┌", "┬", "┐"), 0)
            for (c = 1; c <= ncols; c++) cells[c] = headers[c]
            show(join_row(0), 1)
            for (d = 1; d <= ndb; d++) {
                show(rule("├", "┼", "┤"), 0)
                cells[1] = dbs[d]
                col = 2
                for (i = 1; i <= ns; i++) cells[col++] = sc[dbs[d], statuses[i]] + 0
                for (i = 1; i <= np; i++) cells[col++] = pc[dbs[d], priorities[i]] + 0
                cells[col] = total[dbs[d]] + 0
                show(join_row(1), 0)
            }
            show(rule("├", "┼", "┤"), 0)
            cells[1] = "Total"
            col = 2
            for (i = 1; i <= ns; i++) cells[col++] = status_sum(statuses[i])
            for (i = 1; i <= np; i++) cells[col++] = priority_sum(priorities[i])
            cells[col] = total_sum()
            show(join_row(1), 1)
            show(rule("└", "┴", "┘"), 0)
        }
    ' "$stats_file"
}

cmd_stats() {
    local db err status_rows priority_rows total
    stats_file=$(mktemp)
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        err=$(mktemp)
        if ! status_rows=$(mysql_q -e "USE \`$db\`; SELECT status, COUNT(*) FROM issues GROUP BY status" 2>"$err"); then
            echo "$db: no issues table: $(head -n 1 "$err")" >&2
            rm -f "$err"
            continue
        fi
        rm -f "$err"
        priority_rows=$(mysql_q -e "USE \`$db\`; SELECT priority, COUNT(*) FROM issues GROUP BY priority")
        total=$(mysql_q -e "USE \`$db\`; SELECT COUNT(*) FROM issues")
        total=${total%%$'\n'*}
        append_counts "$db" status "$status_rows"
        append_counts "$db" priority "$priority_rows"
        printf '%s\ttotal\ttotal\t%s\n' "$db" "$total" >> "$stats_file"
    done < <(user_databases)
    print_stats_table
    rm -f "$stats_file"
}

cmd_purge() {
    local db=${1:-} answer
    if [ -z "$db" ]; then
        echo "Usage: make purge DB=<database>" >&2
        exit 1
    fi
    require_database "$db"
    printf 'Type %s to drop it: ' "$db"
    IFS= read -r answer || true
    answer=${answer%$'\r'}
    if [ "$answer" != "$db" ]; then
        echo "Not dropped." >&2
        exit 1
    fi
    mysql_q -e "DROP DATABASE \`$db\`"
    # Dolt keeps a copy under data/.dolt_dropped_databases. Remove that copy
    # so the next sync does not commit the database that was just dropped.
    rm -rf "$ROOT/data/.dolt_dropped_databases/$db" "$ROOT/data/.dolt_dropped_databases/$db.backup."*
    echo "Dropped $db."
}

cmd=${1:-}
case "$cmd" in
    list) cmd_list ;;
    issues) cmd_issues "${2:-}" ;;
    stats) cmd_stats ;;
    purge) cmd_purge "${2:-}" ;;
    *) usage >&2; exit 1 ;;
esac
