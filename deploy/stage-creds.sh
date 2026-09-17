#!/usr/bin/env bash
# Stage file-based credentials for the containerized Hermes toolbelt.
#
# Everything lands under ~/.hermes, which the base compose mounts at
# /opt/data (= the container user's HOME). Each tool then finds its auth at
# its default $HOME path, so NO env vars are needed and the sandbox scrubber
# is a non-issue.
#
# Run this on the DGX host, as evan:   bash ~/hermes-deploy/stage-creds.sh
# Re-runnable (idempotent). It never prints secret values.
set -euo pipefail

HERMES_HOME="${HERMES_DATA_DIR:-$HOME/.hermes}"
umask 077

echo ">> Staging into ${HERMES_HOME}"
mkdir -p "${HERMES_HOME}/.config/gh" \
         "${HERMES_HOME}/.cache/huggingface" \
         "${HERMES_HOME}/.xurl" \
         "${HERMES_HOME}/.grok"

# --- git identity (host has no global identity set) -------------------------
GIT_NAME="${HERMES_GIT_NAME:-Evan Hoffman}"
GIT_EMAIL="${HERMES_GIT_EMAIL:-evandhoffman@gmail.com}"
cat > "${HERMES_HOME}/.gitconfig" <<EOF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[init]
	defaultBranch = main
[safe]
	directory = /opt/data/git/local-llm
EOF
echo "   git identity: ${GIT_NAME} <${GIT_EMAIL}>"

# --- xurl: app-only auth (read-only; app bearer cannot post as a user) ------
if [ -f "$HOME/.xurl/auth.yml" ]; then
  cp -a "$HOME/.xurl/auth.yml" "${HERMES_HOME}/.xurl/auth.yml"
  chmod 600 "${HERMES_HOME}/.xurl/auth.yml"
  echo "   xurl auth.yml copied (app-only = read-only)"
else
  echo "   !! ~/.xurl/auth.yml not found — run 'xurl auth' on the host first" >&2
fi

# --- hf token --------------------------------------------------------------
if [ -f "$HOME/.cache/huggingface/token" ]; then
  cp -a "$HOME/.cache/huggingface/token" "${HERMES_HOME}/.cache/huggingface/token"
  chmod 600 "${HERMES_HOME}/.cache/huggingface/token"
  echo "   hf token copied"
else
  echo "   !! hf token not found — run 'hf auth login' on the host first" >&2
fi

# --- grok: binary + auth + config, minus heavy/host-specific state ----------
if [ -d "$HOME/.grok" ]; then
  rsync -a --delete \
    --exclude 'sessions/' --exclude 'worktrees.db' --exclude 'logs/' \
    --exclude 'memtrace/' --exclude 'marketplace-cache/' \
    "$HOME/.grok/" "${HERMES_HOME}/.grok/"
  echo "   grok home staged (binary + auth.json + config.toml + bundled)"
else
  echo "   !! ~/.grok not found — install the grok CLI on the host first" >&2
fi

# --- gh: SCOPED fine-grained token (evanwtf/local-llm only) -----------------
# Create it first at: https://github.com/settings/personal-access-tokens/new
#   Resource owner: evanwtf   Repo access: Only select -> evanwtf/local-llm
#   Permissions: Issues = Read and write; Contents = Read; Metadata = Read
GH_HOSTS="${HERMES_HOME}/.config/gh/hosts.yml"
if [ -f "${GH_HOSTS}" ] && [ "${1:-}" != "--force-gh" ]; then
  echo "   gh hosts.yml already present (pass --force-gh to overwrite)"
else
  echo
  read -rsp "   Paste the SCOPED GitHub token for evanwtf/local-llm (input hidden): " GH_TOK
  echo
  if [ -n "${GH_TOK}" ]; then
    cat > "${GH_HOSTS}" <<EOF
github.com:
    oauth_token: ${GH_TOK}
    user: evandhoffman
    git_protocol: https
EOF
    chmod 600 "${GH_HOSTS}"
    unset GH_TOK
    echo "   gh hosts.yml written (scoped token)"
  else
    echo "   (skipped gh token — no input)"
  fi
fi

echo
echo ">> Done. These files are owned by $(id -un) (uid $(id -u)); start the"
echo "   container with HERMES_UID=\$(id -u) HERMES_GID=\$(id -g) so the"
echo "   container's hermes user maps to you and can read them."
