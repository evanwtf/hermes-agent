#!/usr/bin/env bash
# Stage file-based credentials for the containerized Hermes toolbelt.
#
# Creds land under ~/.hermes/home, which maps to /opt/data/home in the
# container. That is the isolated home Hermes gives agent SUBPROCESSES
# (get_subprocess_home -> {HERMES_HOME}/home in a container) — NOT /opt/data.
# xurl/gh/hf/grok all resolve their config from that $HOME, so no env vars are
# needed and the sandbox scrubber is a non-issue. (~/.hermes itself is the
# profile root / HERMES_HOME the gateway uses.)
#
# Run this on the DGX host, as evan:   bash ~/hermes-deploy/stage-creds.sh
# Re-runnable (idempotent). It never prints secret values.
set -euo pipefail

HERMES_HOME="${HERMES_DATA_DIR:-$HOME/.hermes}"
umask 077

# Preflight: ~/.hermes must be writable by the current user. If a container was
# ever started WITHOUT HERMES_UID/HERMES_GID, the image chowned it to the
# internal hermes user (uid 10000) and this user can no longer write there.
if [ -e "${HERMES_HOME}" ] && [ ! -w "${HERMES_HOME}" ]; then
  owner="$(stat -c '%u:%g' "${HERMES_HOME}" 2>/dev/null || echo '?')"
  cat >&2 <<EOF
!! ${HERMES_HOME} is not writable by $(id -un) (uid $(id -u)); it is owned by ${owner}.
   A container was started without HERMES_UID/HERMES_GID and chowned it to the
   internal hermes user. Fix, then re-run this script:

     sudo chown -R "\$(id -u):\$(id -g)" "${HERMES_HOME}"

   And ALWAYS launch the container with the uid so it stays yours:
     HERMES_UID=\$(id -u) HERMES_GID=\$(id -g) docker compose ... up -d
EOF
  exit 1
fi

# Creds go into the agent subprocess home, not the profile root.
STAGE_HOME="${HERMES_HOME}/home"
echo ">> Staging into ${STAGE_HOME} (agent subprocess \$HOME)"
mkdir -p "${STAGE_HOME}/.config/gh" \
         "${STAGE_HOME}/.cache/huggingface" \
         "${STAGE_HOME}/.xurl" \
         "${STAGE_HOME}/.grok"

# --- git identity (host has no global identity set) -------------------------
GIT_NAME="${HERMES_GIT_NAME:-Evan Hoffman}"
GIT_EMAIL="${HERMES_GIT_EMAIL:-evandhoffman@gmail.com}"
cat > "${STAGE_HOME}/.gitconfig" <<EOF
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
  cp -a "$HOME/.xurl/auth.yml" "${STAGE_HOME}/.xurl/auth.yml"
  chmod 600 "${STAGE_HOME}/.xurl/auth.yml"
  echo "   xurl auth.yml copied (app-only = read-only)"
else
  echo "   !! ~/.xurl/auth.yml not found — run 'xurl auth' on the host first" >&2
fi

# --- hf token --------------------------------------------------------------
if [ -f "$HOME/.cache/huggingface/token" ]; then
  cp -a "$HOME/.cache/huggingface/token" "${STAGE_HOME}/.cache/huggingface/token"
  chmod 600 "${STAGE_HOME}/.cache/huggingface/token"
  echo "   hf token copied"
else
  echo "   !! hf token not found — run 'hf auth login' on the host first" >&2
fi

# --- grok: binary + auth + config, minus heavy/host-specific state ----------
if [ -d "$HOME/.grok" ]; then
  rsync -a --delete \
    --exclude 'sessions/' --exclude 'worktrees.db' --exclude 'logs/' \
    --exclude 'memtrace/' --exclude 'marketplace-cache/' \
    "$HOME/.grok/" "${STAGE_HOME}/.grok/"
  echo "   grok home staged (binary + auth.json + config.toml + bundled)"
else
  echo "   !! ~/.grok not found — install the grok CLI on the host first" >&2
fi

# --- gh: SCOPED fine-grained token (evanwtf/local-llm only) -----------------
# Create it first at: https://github.com/settings/personal-access-tokens/new
#   Resource owner: evanwtf   Repo access: Only select -> evanwtf/local-llm
#   Permissions: Issues = Read and write; Contents = Read; Metadata = Read
GH_HOSTS="${STAGE_HOME}/.config/gh/hosts.yml"
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
