#!/bin/bash
#
# Auto-sync: commits git repo changes and syncs dolt databases.
#
# 1. Git: commit and push all changes in /repo
# 2. Dolt: for each database, commit local changes, pull, push
#
# Collision avoidance strategy for dolt:
#   - Commit local changes first (so they aren't lost during pull)
#   - Pull from remote (dolt merges at row-level — concurrent edits to
#     different rows merge cleanly)
#   - Push to remote
#   - If push fails, the next cycle retries
#
# If a pull produces merge conflicts (same row edited by two users),
# the script logs the conflict and skips push — a human must resolve it.

set -euo pipefail

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Git sync ---
echo "[$NOW] === git repo ==="
cd /repo
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "  Committing changes..."
    git add -A
    git commit -m "auto-sync: $NOW" || echo "  Commit skipped"
fi

if git remote -v 2>/dev/null | grep -q "^origin"; then
    echo "  Pulling from origin..."
    git pull --rebase origin main 2>/dev/null || echo "  Pull failed — will retry next cycle"
    echo "  Pushing to origin..."
    git push origin main 2>/dev/null || echo "  Push failed — will retry next cycle"
else
    echo "  No git remote 'origin' configured — skipping pull/push"
fi

# --- Dolt sync ---
for dir in /data/*/; do
    [ -d "$dir/.dolt" ] || continue
    db=$(basename "$dir")
    echo "[$NOW] === dolt: $db ==="
    cd "$dir"

    # 1. Commit any uncommitted changes
    if dolt status 2>/dev/null | grep -q "modified\|new table\|deleted\|renamed"; then
        echo "  Committing changes..."
        dolt add .
        dolt commit -m "auto-sync: $NOW" || echo "  Commit skipped (nothing staged)"
    fi

    # 2. Check if remote 'origin' is configured
    if ! dolt remote -v 2>/dev/null | grep -q "^origin"; then
        echo "  No remote 'origin' configured — skipping pull/push"
        continue
    fi

    # 3. Pull (fetch + merge)
    echo "  Pulling from origin..."
    if ! dolt pull origin main 2>/dev/null; then
        echo "  Pull failed — will retry next cycle"
        continue
    fi

    # 4. Abort push if there are merge conflicts
    if dolt conflicts cat . 2>/dev/null | grep -q .; then
        echo "  WARNING: conflicts detected after pull — skipping push (resolve manually)"
        continue
    fi

    # 5. Push
    echo "  Pushing to origin..."
    if ! dolt push origin main 2>/dev/null; then
        echo "  Push failed — pulling again and retrying..."
        dolt pull origin main 2>/dev/null || true
        dolt push origin main 2>/dev/null || echo "  Push retry failed — will try next cycle"
    fi

    echo "  Done."
done
