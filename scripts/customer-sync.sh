#!/usr/bin/env bash
#
# customer-sync.sh — POC: filter the Tenx primary repo and push a snapshot
# to the customer repo on the SAME branch.
#
# Blocklist model: everything syncs EXCEPT paths in .customer-sync-ignore.
#
# Required env vars:
#   TARGET_REMOTE    Authenticated https URL of repo B
#                    e.g. https://<PAT>@github.com/Dayone-Tenx/codesync.git
#   BRANCH           Branch to sync (must match the source branch)
#   COMMITTER_NAME   Committer name for repo B commits (configurable per run)
#   COMMITTER_EMAIL  Committer email for repo B commits (fixed)
#
# Optional env vars:
#   SOURCE_DIR       Checkout of repo A (default: current directory)
#   IGNORE_FILE      Blocklist file (default: $SOURCE_DIR/.customer-sync-ignore)
#   DRY_RUN          If "1", stage + show the diff but do NOT push.

set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-$(pwd)}"
IGNORE_FILE="${IGNORE_FILE:-$SOURCE_DIR/.customer-sync-ignore}"
: "${TARGET_REMOTE:?TARGET_REMOTE is required}"
: "${BRANCH:?BRANCH is required}"
: "${COMMITTER_NAME:?COMMITTER_NAME is required}"
: "${COMMITTER_EMAIL:?COMMITTER_EMAIL is required}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-Sync from Tenx repo ($BRANCH)}"
COMMIT_BODY="${COMMIT_BODY:-}"
DRY_RUN="${DRY_RUN:-0}"

echo "==> Source : $SOURCE_DIR"
echo "==> Branch : $BRANCH"
echo "==> Author : $COMMITTER_NAME <$COMMITTER_EMAIL>"
echo "==> Message: $COMMIT_MESSAGE"
[ -n "${COMMIT_BODY// /}" ] && echo "==> Body   : $COMMIT_BODY"
[ -f "$IGNORE_FILE" ] || { echo "!! blocklist not found: $IGNORE_FILE" >&2; exit 1; }

# --- Committer diagnostics -------------------------------------------------
# git reads GIT_AUTHOR_*/GIT_COMMITTER_* env vars in preference to `-c user.*`.
# If the agent set any, unset them so the selected committer wins.
echo "==> Committer diagnostics:"
echo "      requested name : $COMMITTER_NAME"
echo "      requested email: $COMMITTER_EMAIL"
for v in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
  if [ -n "${!v:-}" ]; then
    echo "      !! inherited $v='${!v}' — unsetting so it cannot override the selection"
  fi
done
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# ---------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Clone repo B on the matching branch; create it if it does not exist yet.
if git clone --depth 1 --branch "$BRANCH" "$TARGET_REMOTE" "$WORK" 2>/dev/null; then
  echo "==> Cloned existing branch '$BRANCH' from customer repo."
else
  echo "==> Branch '$BRANCH' not on customer repo yet; starting a fresh one."
  git clone --depth 1 "$TARGET_REMOTE" "$WORK"
  git -C "$WORK" checkout --orphan "$BRANCH"
  git -C "$WORK" rm -rf . >/dev/null 2>&1 || true
fi

# 2. Mirror source -> repo B, applying the blocklist.
#    --delete removes files dropped in repo A; excluded paths are never copied.
rsync -a --delete \
  --exclude='.git/' \
  --exclude-from="$IGNORE_FILE" \
  "$SOURCE_DIR/" "$WORK/"

# 3. Stage and commit as the configured committer.
cd "$WORK"
git add -A
if git diff --cached --quiet; then
  echo "==> No changes to sync — nothing to commit."
  echo "==> This means repo B already matches the filtered repo A, so NO new"
  echo "    commit was created. Any committer you selected is NOT applied on a"
  echo "    no-op run. Current repo B HEAD identity:"
  git show -s --format='      author    : %an <%ae>%n      committer : %cn <%ce>%n      subject   : %s' HEAD 2>/dev/null \
    || echo "      (repo B has no commits yet)"
  exit 0
fi

echo "==> Files staged for the customer repo:"
git diff --cached --name-status

if [ "$DRY_RUN" = "1" ]; then
  echo "==> DRY_RUN=1 — not committing or pushing."
  exit 0
fi

INTERNAL_REF="$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Build the commit: subject, optional body (only if non-blank), then the
# automatic Internal-Ref trailer. Each -m becomes its own paragraph.
COMMIT_ARGS=(-m "$COMMIT_MESSAGE")
if [ -n "${COMMIT_BODY// /}" ]; then
  COMMIT_ARGS+=(-m "$COMMIT_BODY")
fi
COMMIT_ARGS+=(-m "Internal-Ref: $INTERNAL_REF")

git -c user.name="$COMMITTER_NAME" -c user.email="$COMMITTER_EMAIL" \
    commit "${COMMIT_ARGS[@]}"

# Verify the identity actually written into the commit (not just what we asked
# for). If these do not match the requested name/email, something overrode it.
echo "==> Identity written into the new commit:"
git show -s --format='      author    : %an <%ae>%n      committer : %cn <%ce>%n      sha       : %H' HEAD

git push origin "HEAD:$BRANCH"
echo "==> Pushed snapshot to customer repo, branch '$BRANCH'."
echo "==> NOTE: GitHub shows the avatar/username by EMAIL. '$COMMITTER_EMAIL'"
echo "    renders as a real profile only if it is verified on a GitHub account;"
echo "    otherwise it shows the name with a generic avatar."
