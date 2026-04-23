#!/usr/bin/env bash
#
# auto-commit.sh — Auto-commits idle projects in /mnt/1tb-ssd/random/
# Runs via cron every 15 minutes. Skips projects being actively edited.
# Shows a desktop toast for the first 4 runs.
#

set -euo pipefail

PROJECTS_DIR="/mnt/1tb-ssd/random"
LOG_FILE="/mnt/1tb-ssd/random/committer/auto-commit.log"
RUN_COUNT_FILE="/mnt/1tb-ssd/random/committer/.run-count"
GITHUB_USER="PixelPotts"
IDLE_THRESHOLD_SECS=120  # 2 minutes — skip if .edits or files modified more recently

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

toast() {
  local title="$1" body="$2"
  notify-send -u normal -t 5000 "$title" "$body" 2>/dev/null || true
}

# ── Check if a project is actively being edited ──────────────────────────
is_actively_edited() {
  local project_dir="$1"
  local now
  now=$(date +%s)

  # Check .edits file — if modified within threshold, project is active
  if [ -f "$project_dir/.edits" ]; then
    local edits_mtime
    edits_mtime=$(stat -c %Y "$project_dir/.edits" 2>/dev/null || echo 0)
    local edits_age=$(( now - edits_mtime ))
    if [ "$edits_age" -lt "$IDLE_THRESHOLD_SECS" ]; then
      log "  ACTIVE (.edits modified ${edits_age}s ago)"
      return 0
    fi
  fi

  # Check if any source files were modified very recently (last 60s)
  local recent_files
  recent_files=$(find "$project_dir" -maxdepth 3 \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/dist/*' \
    -not -path '*/__pycache__/*' \
    -not -name '*.log' \
    -type f -newermt "-60 seconds" 2>/dev/null | head -1)
  if [ -n "$recent_files" ]; then
    log "  ACTIVE (files modified in last 60s)"
    return 0
  fi

  # Check for running Claude Code or editors with files open in this project
  local project_name
  project_name=$(basename "$project_dir")
  if pgrep -f "claude.*${project_name}" > /dev/null 2>&1; then
    log "  ACTIVE (claude process detected)"
    return 0
  fi

  return 1
}

# ── Ensure a project has a GitHub remote ─────────────────────────────────
ensure_github_remote() {
  local project_dir="$1"
  local project_name
  project_name=$(basename "$project_dir")

  if ! git -C "$project_dir" remote get-url origin &>/dev/null; then
    log "  Creating GitHub repo for $project_name..."
    if gh repo create "$GITHUB_USER/$project_name" --public --source="$project_dir" --push 2>>"$LOG_FILE"; then
      log "  GitHub repo created: $GITHUB_USER/$project_name"
      return 0
    else
      log "  WARN: Failed to create GitHub repo for $project_name"
      return 1
    fi
  fi
  return 0
}

# ── Commit and push a single project ────────────────────────────────────
commit_and_push() {
  local project_dir="$1"
  local project_name
  project_name=$(basename "$project_dir")

  # Check for changes
  local changes
  changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l)
  if [ "$changes" -eq 0 ]; then
    log "  No changes to commit"
    return 0
  fi

  # Stage all changes
  git -C "$project_dir" add -A 2>>"$LOG_FILE"

  # Build a commit message summarizing what changed
  local added modified deleted
  added=$(git -C "$project_dir" diff --cached --numstat 2>/dev/null | wc -l)
  modified=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null | wc -l)
  local msg="auto-commit: ${modified} file(s) updated"

  git -C "$project_dir" commit -m "$msg" 2>>"$LOG_FILE" || {
    log "  WARN: commit failed for $project_name"
    return 1
  }
  log "  Committed: $msg"

  # Push if remote exists
  if git -C "$project_dir" remote get-url origin &>/dev/null; then
    local branch
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    git -C "$project_dir" push -u origin "$branch" 2>>"$LOG_FILE" || {
      log "  WARN: push failed for $project_name"
      return 1
    }
    log "  Pushed to origin/$branch"
  fi

  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  log "=== Auto-commit run started ==="

  local committed=0
  local skipped_active=0
  local skipped_clean=0
  local errors=0
  local committed_names=""

  for project_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$project_dir" ] || continue
    local project_name
    project_name=$(basename "$project_dir")
    log "Processing: $project_name"

    # Ensure git repo exists
    if [ ! -d "$project_dir/.git" ]; then
      log "  Initializing git repo..."
      git -C "$project_dir" init 2>>"$LOG_FILE"
      git -C "$project_dir" add -A 2>>"$LOG_FILE"
      git -C "$project_dir" commit -m "Initial commit" 2>>"$LOG_FILE" || true
    fi

    # Ensure GitHub remote exists
    ensure_github_remote "$project_dir"

    # Skip if actively being edited
    if is_actively_edited "$project_dir"; then
      skipped_active=$((skipped_active + 1))
      continue
    fi

    # Commit and push
    if commit_and_push "$project_dir"; then
      local changes
      changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l)
      # If we actually committed (not just "no changes")
      if git -C "$project_dir" log -1 --format="%s" 2>/dev/null | grep -q "^auto-commit:"; then
        local last_commit_time
        last_commit_time=$(git -C "$project_dir" log -1 --format="%ct" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if [ $((now - last_commit_time)) -lt 10 ]; then
          committed=$((committed + 1))
          committed_names="${committed_names}${project_name}, "
        fi
      fi
    else
      errors=$((errors + 1))
    fi
  done

  log "=== Run complete: committed=$committed skipped_active=$skipped_active errors=$errors ==="

  # Toast notification for first 4 runs
  local run_count=0
  if [ -f "$RUN_COUNT_FILE" ]; then
    run_count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 0)
  fi
  run_count=$((run_count + 1))
  echo "$run_count" > "$RUN_COUNT_FILE"

  if [ "$run_count" -le 4 ]; then
    local toast_body="Committed: $committed | Skipped (active): $skipped_active | Errors: $errors"
    if [ -n "$committed_names" ]; then
      committed_names="${committed_names%, }"
      toast_body="${toast_body}\nProjects: ${committed_names}"
    fi
    toast "Auto-Committer (#$run_count)" "$toast_body"
  fi
}

main "$@"
