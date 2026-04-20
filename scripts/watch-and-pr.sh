#!/bin/bash
# ============================================================
#  GitHub Drop Watcher — Synology DSM 7
#  Watches a local folder for new/changed HTML and JSON files
#  and opens a pull request to your GitHub Pages repo.
#
#  Handles:
#    - HTML tool files  → any department subfolder
#    - JSON data files  → /data folder (shared) OR next to a tool
#    - Deletions        → single PR bundling all removed files
#
#  Run via DSM Task Scheduler every 5 minutes.
# ============================================================

# ── CONFIG ──────────────────────────────────────────────────
# Secrets (GITHUB_TOKEN, PROTECTED_PASSWORD) live in /volume1/GitHubDrop/.env
# That file is never committed to git. Example contents:
#   GITHUB_TOKEN="ghp_..."
#   PROTECTED_PASSWORD="your-password"
[ -f "/volume1/GitHubDrop/.env" ] && . "/volume1/GitHubDrop/.env"

GITHUB_ORG="the-jerky-co"
GITHUB_REPO="tools"
GITHUB_USER_EMAIL="it@thejerkyco.com.au"
GITHUB_USER_NAME="NAS Watcher"

DROP_FOLDER="/volume1/GitHubDrop"
WORK_DIR="/volume1/GitHubDrop/.git-work"
LOG_FILE="/volume1/GitHubDrop/.watcher.log"
# ─────────────────────────────────────────────────────────────

REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
DELETED_TMP="/tmp/deleted_files_$$.txt"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# ── Ensure git is available ──────────────────────────────────
if ! command -v git &>/dev/null; then
  log "ERROR: git not found. Install Git Server package in DSM Package Center."
  exit 1
fi

# ── Clone or update the main branch into work dir ───────────
if [ ! -d "$WORK_DIR/.git" ]; then
  log "Cloning repo for the first time..."
  git clone "$REPO_URL" "$WORK_DIR" >> "$LOG_FILE" 2>&1
else
  cd "$WORK_DIR"
  git remote set-url origin "$REPO_URL"
  git fetch origin >> "$LOG_FILE" 2>&1
  git checkout main >> "$LOG_FILE" 2>&1
  git pull origin main >> "$LOG_FILE" 2>&1
fi

cd "$WORK_DIR"
git config user.email "$GITHUB_USER_EMAIL"
git config user.name "$GITHUB_USER_NAME"

# ── Helper: open a PR for a single changed file ─────────────
open_pr() {
  local SRC_FILE="$1"
  local REL_PATH="${SRC_FILE#$DROP_FOLDER/}"
  local DEST_FILE="$WORK_DIR/$REL_PATH"
  local DEST_DIR
  DEST_DIR=$(dirname "$DEST_FILE")
  local FILE_TYPE="$2"

  if [ -f "$DEST_FILE" ] && cmp -s "$SRC_FILE" "$DEST_FILE"; then
    return
  fi

  # Skip if an open PR already exists for this file (prevents duplicate PR spam)
  local SAFE_REL BRANCH_PREFIX EXISTING_BRANCH
  SAFE_REL=$(echo "$REL_PATH" | tr '/' '-' | tr ' ' '-')
  BRANCH_PREFIX="upload/${SAFE_REL}-"
  EXISTING_BRANCH=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/branches?per_page=100" \
    | grep -o '"name":"[^"]*"' | grep -c "\"${BRANCH_PREFIX}")
  if [ "$EXISTING_BRANCH" -gt 0 ]; then
    log "Open PR already exists for $REL_PATH — skipping duplicate"
    return
  fi

  log "Change detected [$FILE_TYPE]: $REL_PATH"

  local BRANCH_NAME="upload/$(echo "$REL_PATH" | tr '/' '-' | tr ' ' '-')-${TIMESTAMP}"

  cd "$WORK_DIR"
  git checkout main >> "$LOG_FILE" 2>&1
  git checkout -b "$BRANCH_NAME" >> "$LOG_FILE" 2>&1

  mkdir -p "$DEST_DIR"
  cp "$SRC_FILE" "$DEST_FILE"

  # Encrypt password-protected tools before committing
  if echo "$REL_PATH" | grep -q '\-protected\.html$'; then
    if command -v staticrypt &>/dev/null; then
      log "Encrypting: $REL_PATH"
      local TMP_ENC
      TMP_ENC=$(mktemp -d)
      staticrypt "$DEST_FILE" --password "$PROTECTED_PASSWORD" \
        --directory "$TMP_ENC" --no-remember 2>> "$LOG_FILE"
      if [ -f "$TMP_ENC/$(basename "$DEST_FILE")" ]; then
        mv "$TMP_ENC/$(basename "$DEST_FILE")" "$DEST_FILE"
        log "Encryption successful: $REL_PATH"
      else
        log "WARNING: staticrypt output not found — pushing $REL_PATH unencrypted"
      fi
      rm -rf "$TMP_ENC"
    else
      log "WARNING: staticrypt not installed — pushing $REL_PATH unencrypted. Run: npm install -g staticrypt"
    fi
  fi

  if [ "$FILE_TYPE" = "tool" ]; then
    bash "$WORK_DIR/scripts/build-index.sh" "$WORK_DIR"
  fi

  git add -A >> "$LOG_FILE" 2>&1
  git commit -m "Add/update $FILE_TYPE: $REL_PATH" >> "$LOG_FILE" 2>&1
  git push origin "$BRANCH_NAME" >> "$LOG_FILE" 2>&1

  local PR_TITLE PR_BODY
  if [ "$FILE_TYPE" = "data" ]; then
    PR_TITLE="Data update: $REL_PATH"
    PR_BODY="Automated data file update from NAS.\n\n**File:** \`$REL_PATH\`\n**Time:** $(date)\n\n> This updates shared data. Please verify the JSON is valid before merging."
  elif echo "$REL_PATH" | grep -q '\-protected\.html$'; then
    PR_TITLE="New tool (protected): $REL_PATH"
    PR_BODY="New or updated password-protected tool from NAS drop folder.\n\n**File:** \`$REL_PATH\`\n**Time:** $(date)\n\n> Page is StatiCrypt-encrypted. Share the password separately.\n\nReview and merge to publish."
  else
    PR_TITLE="New tool: $REL_PATH"
    PR_BODY="New or updated tool from NAS drop folder.\n\n**File:** \`$REL_PATH\`\n**Time:** $(date)\n\nReview and merge to publish."
  fi

  local PR_RESPONSE
  PR_RESPONSE=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/pulls" \
    -d "{
      \"title\": \"${PR_TITLE}\",
      \"body\": \"${PR_BODY}\",
      \"head\": \"${BRANCH_NAME}\",
      \"base\": \"main\"
    }")

  local PR_URL
  PR_URL=$(echo "$PR_RESPONSE" | grep -o '"html_url": *"[^"]*pulls[^"]*"' | head -1 | cut -d'"' -f4)
  log "PR opened: $PR_URL"

  git checkout main >> "$LOG_FILE" 2>&1
}

# ── Scan: new/changed HTML files ─────────────────────────────
find "$DROP_FOLDER" -name "*.html" \
  ! -path "*/.git-work/*" \
  ! -path "*/scripts/*" \
  ! -path "*/#recycle/*" \
  ! -path "*/@eaDir/*" \
  ! -path "*/.scripts/*" \
  | while read -r FILE; do
    open_pr "$FILE" "tool"
  done

# ── Scan: new/changed JSON files ─────────────────────────────
find "$DROP_FOLDER" -name "*.json" \
  ! -path "*/.git-work/*" \
  ! -path "*/#recycle/*" \
  ! -path "*/@eaDir/*" \
  ! -path "*/.scripts/*" \
  | while read -r FILE; do
    open_pr "$FILE" "data"
  done

# ── Scan: deletions ──────────────────────────────────────────
# Find HTML/JSON files in the repo that no longer exist in the NAS drop folder
DELETED_FILES=""

# Check repo HTML and JSON files against NAS
find "$WORK_DIR" \( -name "*.html" -o -name "*.json" \) \
  ! -name "index.html" \
  ! -path "*/.git/*" \
  ! -path "*/scripts/*" \
  | while read -r REPO_FILE; do
    REL_PATH="${REPO_FILE#$WORK_DIR/}"
    NAS_FILE="$DROP_FOLDER/$REL_PATH"

    # If it doesn't exist on the NAS, it was deleted
    if [ ! -f "$NAS_FILE" ]; then
      echo "$REL_PATH"
    fi
  done > $DELETED_TMP

# If any deletions found, bundle into one PR
if [ -s $DELETED_TMP ]; then
  # Skip if a cleanup PR is already open
  EXISTING_CLEANUP=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/branches?per_page=100" \
    | grep -o '"name":"[^"]*"' | grep -c '"cleanup/')
  if [ "$EXISTING_CLEANUP" -gt 0 ]; then
    log "Open cleanup PR already exists — skipping duplicate"
    rm -f $DELETED_TMP
    # Rotate log if over 2 MB
LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$LOG_SIZE" -gt 2097152 ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old"
  log "Log rotated (was ${LOG_SIZE} bytes)"
fi

log "Scan complete."
    exit 0
  fi

  BRANCH_NAME="cleanup/removed-files-${TIMESTAMP}"

  cd "$WORK_DIR"
  git checkout main >> "$LOG_FILE" 2>&1
  git checkout -b "$BRANCH_NAME" >> "$LOG_FILE" 2>&1

  PR_BODY="The following files were removed from the NAS drop folder and will be unpublished from the site:\n\n"
  DELETED_LIST=""

  while IFS= read -r REL_PATH; do
    log "Deletion detected: $REL_PATH"
    git rm -f "$REL_PATH" >> "$LOG_FILE" 2>&1
    PR_BODY+="- \`$REL_PATH\`\n"
    DELETED_LIST="$DELETED_LIST $REL_PATH"
  done < $DELETED_TMP

  PR_BODY+"\n**Time:** $(date)\n\nMerge to remove these files from the live site."

  # Rebuild index after removals
  bash "$WORK_DIR/scripts/build-index.sh" "$WORK_DIR"

  git add -A >> "$LOG_FILE" 2>&1
  git commit -m "Cleanup: remove deleted files" >> "$LOG_FILE" 2>&1
  git push origin "$BRANCH_NAME" >> "$LOG_FILE" 2>&1

  PR_RESPONSE=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/pulls" \
    -d "{
      \"title\": \"Cleanup: removed files\",
      \"body\": \"${PR_BODY}\",
      \"head\": \"${BRANCH_NAME}\",
      \"base\": \"main\"
    }")

  PR_URL=$(echo "$PR_RESPONSE" | grep -o '"html_url": *"[^"]*pulls[^"]*"' | head -1 | cut -d'"' -f4)
  log "Deletion PR opened: $PR_URL"

  git checkout main >> "$LOG_FILE" 2>&1
fi

rm -f $DELETED_TMP
log "Scan complete."