# Hermes toolbelt + local-llm Twitter sweep — runbook

Deployment overlay for this fork: gives the containerized Hermes access to
**hf, gh, git, xurl, grok**, hardens the container, and sets up a scheduled
X/Twitter lead sweep for the local-llm project. Everything here is committed;
credentials are never in the repo — `stage-creds.sh` writes them into
`~/.hermes` (the mounted volume) at deploy time.

## Design in one paragraph
The base mounts `~/.hermes` at `/opt/data` (the gateway's `HERMES_HOME`).
Crucially, Hermes runs agent **subprocesses** with an isolated home at
**`/opt/data/home`** (`get_subprocess_home` → `{HERMES_HOME}/home` in a
container), *not* `/opt/data`. Its code-execution sandbox **scrubs** env vars
containing KEY/TOKEN/SECRET/AUTH but **injects HOME**, so every CLI is wired
through files under **`~/.hermes/home`** (= `/opt/data/home`) at its default
`$HOME` path — no env tokens, no secrets in the image. (Staging into `~/.hermes`
instead of `~/.hermes/home` is off by one dir and tools won't find their auth.) Tools are added in a **derived image** (`Dockerfile.tools`,
`FROM hermes-agent`) to keep the fork mergeable with upstream. The override also
moves the gateway to **bridge networking** and applies **least-privilege**
capabilities (see §9). Credentials are **scoped**: gh = a fine-grained token
limited to `evanwtf/local-llm` (Issues:write, else read); xurl = app-only
(read-only, cannot post); no ssh key is mounted.

## Files (deploy/)
- `Dockerfile.tools` — derived image: gh (apt), hf (uv tool), xurl (official
  release, checksum-verified), grok (runtime symlink to the mounted `~/.grok`).
- `docker-compose.override.yml` — tooled image, local-llm ro mount, bridge net
  (gateway), capability hardening. Pass it with explicit `-f` (see below).
- `stage-creds.sh` — populates `~/.hermes/home/{.config/gh,.xurl,.cache/huggingface,
  .grok,.gitconfig}` (the agent subprocess `$HOME`). You run it; never prints secrets.
- `sweep-prompt.md` — the cron job's prompt.

All commands below run from the repo root.

## Steps (run on the DGX host as evan)

### 1. Create the scoped GitHub token
https://github.com/settings/personal-access-tokens/new →
Resource owner **evanwtf**, repo access **Only select → evanwtf/local-llm**,
permissions **Issues: Read and write; Contents: Read; Metadata: Read**.

### 2. Stage credentials
```bash
bash deploy/stage-creds.sh      # paste the token when prompted
```

### 3. Sign the native grok-powered X search into the Hermes profile (optional
but recommended — this is the `x_search` tool, separate from the grok CLI):
```bash
# after the container is up (step 5), once:
docker exec -it hermes hermes auth add xai-oauth
```

### 4. Build (two-step: base first, then the toolbelt layer)
```bash
HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose build          # base -> hermes-agent:latest
HERMES_UID=$(id -u) HERMES_GID=$(id -g) \
  docker compose -f docker-compose.yml \
                 -f deploy/docker-compose.override.yml build           # -> hermes-agent-tools
```

### 5. Bring it up
```bash
HERMES_UID=$(id -u) HERMES_GID=$(id -g) \
  docker compose -f docker-compose.yml \
                 -f deploy/docker-compose.override.yml up -d
```

### 6. Verify the toolbelt inside the container
Run it as the agent's user + subprocess `$HOME` (a bare `docker exec` runs as
root with `HOME=/root` and would NOT see the staged creds):
```bash
docker exec -u hermes -e HOME=/opt/data/home hermes bash -lc '
  gh auth status &&
  hf version &&
  xurl auth apps list &&
  grok --version &&
  git -C /opt/data/git/local-llm log -1 --oneline'
```

### 7. Schedule the sweep
First put the prompt where the container can read it (the `~/.hermes` volume):
```bash
mkdir -p ~/.hermes/sweeps && cp deploy/sweep-prompt.md ~/.hermes/sweeps/
```
Then create the job. `hermes cron create` (alias `add`) takes the schedule and
prompt as **positionals** — the prompt just points at that file:
```bash
docker exec -it hermes hermes cron create "every day 9am" \
  "Read /opt/data/sweeps/sweep-prompt.md and carry out the local-llm X/Twitter lead sweep it describes." \
  --name local-llm-x-sweep \
  --workdir /opt/data/git/local-llm \
  --skill xurl \
  --deliver local
```
- Verify flags with `docker exec -it hermes hermes cron create --help`.
- `--deliver`: `local` posts to the profile's Bot Chat/dashboard; swap for
  `telegram` / `discord` / `platform:<chat_id>` to route the digest elsewhere.
- Tier 1 is swept daily; the prompt widens to Tier 2 on Mondays.
- Sanity-run it once now: `docker exec -it hermes hermes cron run local-llm-x-sweep`.
- Once Discord is up (below), route the digest there: `--deliver discord` (or a
  specific channel), and run `/sethome` in that channel first.

## 8. Discord gateway (communication)

Discord is the only gateway we enable (Telegram/WhatsApp/Signal/Slack stay off).
Config is pure env in `~/.hermes/.env` (→ `/opt/data/.env`); **nothing to
rebuild** — the container already runs `gateway run` under s6.

### 8a. Developer Portal
1. https://discord.com/developers → **New Application** → **Bot**.
2. **Privileged Gateway Intents → enable *Message Content Intent*.** Leave
   *Server Members* OFF unless you allowlist by username (we use a numeric ID,
   so it's not needed). Presence not needed.
3. **OAuth2 → URL Generator**: scopes `bot` + `applications.commands`; invite to
   a **private** test server (or just DM the bot).
4. Copy the **bot token**. Get your **numeric user ID** (Discord → Settings →
   Advanced → Developer Mode on → right-click yourself → Copy User ID).

### 8b. Configure (pick one)
Canonical, validated (writes `~/.hermes/.env` for you):
```bash
docker exec -it hermes hermes gateway setup     # choose Discord, paste token + your user ID
```
Or manual — append to `~/.hermes/.env` on the host:
```
DISCORD_BOT_TOKEN=your-bot-token
DISCORD_ALLOWED_USERS=your-numeric-user-id
```
Allowlist is OR across `DISCORD_ALLOWED_USERS` / `_ALLOWED_ROLES` /
`_ALLOWED_CHANNELS`. Hermes **fails closed** with none set. **Never** set
`DISCORD_ALLOW_ALL_USERS=true` — this agent has code-exec + gh write to
local-llm; that flag would expose both to any Discord user.

### 8c. Apply + verify
```bash
docker exec -it hermes hermes gateway restart    # or: docker compose ... restart gateway
docker exec -it hermes hermes gateway status
```
Bot goes green in a few seconds. DM it (no @mention needed) or @mention it in a
channel. Slash commands (`/model`, `/skills`, `/sethome`, + installed skills)
register after a gateway restart. Habits: `/sethome` in a private `#hermes`
channel for cron/sweep reports; one thread per task; DMs = personal session.

## 9. Hardening — networking + least privilege

**Why it's load-bearing:** Hermes' code-execution path has no OS sandbox (no
bwrap/nsjail/seccomp beyond Docker's default), so the container *is* the
boundary for an agent that runs arbitrary code and is reachable from Discord.

**Networking (in the override):** only the **gateway** moves to bridge (the
risky, code-exec, chat-reachable service); it has no inbound ports (Discord is
outbound) and reaches local models via `host.docker.internal` (engines must
listen on `0.0.0.0`, which they do for LAN serving — a loopback-only engine
would need rebinding).

The **dashboard stays on host networking.** Hermes hard-maps its
`--host 0.0.0.0` back to `127.0.0.1` (and `--insecure` does not override this),
so it only ever binds loopback — and you can't port-publish a loopback-bound
service through a bridge, which is why binding `0.0.0.0` was refused before. On
host networking its loopback bind = the host's `127.0.0.1:9119`, as designed;
reach it remotely with `ssh -L 9119:localhost:9119 <dgx>`. It's the low-risk
service (UI over the shared volume + vLLM), so it keeps host net but still gets
capability hardening.

**Container caps (in the override):** `cap_drop: ALL` + only the boot set
(CHOWN/DAC_OVERRIDE/FOWNER/SETPCAP for uid-remap+chown, SETUID/SETGID for the
privilege drop, KILL for s6); `no-new-privileges` (agent can't sudo — bake tools
in the image, don't apt at runtime); `pids_limit`. `docker.sock` is deliberately
NOT mounted (docker-cli is present but has no daemon = no escape). Optional,
commented: `mem_limit`/`cpus` and a read-only rootfs (test code-exec/grok first).

**Hermes app-level (already safe by default; verify in `config.yaml`):**
- `approvals.mode` = `smart` (aux-LLM approves only low-risk); `cron_mode`,
  `single_query_mode`, `unattended_mode` = **`deny`** — so the autonomous sweep
  and Discord-push sessions *refuse* dangerous commands when no one can approve.
  For strictest, set `mode: manual` (always prompt) and add hard blocks:
  ```yaml
  approvals:
    mode: manual
    deny: ["git push --force*", "gh repo delete*", "rm -rf /*", "sudo *"]
  ```
- **Trim the tool surface** to what the sweep needs (terminal, web/x_search,
  files). On a headless box, disable unused toolsets — list and toggle with
  `docker exec -it hermes hermes tools` (e.g. computer_use, browser, voice,
  image generation). Smaller surface = less to abuse.
- `subagent_auto_approve` stays `false` (default).
- Credentials are already least-privilege: gh token scoped to local-llm, xurl
  app-only (read). Advanced: `hermes egress setup` (iron-proxy) injects real
  tokens only at egress so a compromised sandbox sees opaque tokens.

Verify after boot: `docker exec -it hermes bash -lc 'id; capsh --print 2>/dev/null | head'`
and confirm the toolbelt still works (step 6).

## Notes / caveats
- **grok CLI vs x_search**: the sweep uses `xurl` (read-only). The native
  grok-powered `x_search` tool (step 3) is a second, citation-returning path;
  the standalone `grok` CLI is available in-container for deeper analysis. All
  three share your xAI/SuperGrok account.
- **Token blast radius**: the gh token can file issues on local-llm and nothing
  else; xurl cannot post. Auto-PRs would need Contents:write and a deliberate
  decision.
- **Two-step build** is required because `Dockerfile.tools` is `FROM
  hermes-agent:latest`, which the base build produces. (This is why the override
  is not the auto-loaded root `docker-compose.override.yml`.)
- If Hermes' own `model.default` points at a **local** engine, change that URL
  from `127.0.0.1` to `host.docker.internal` now that the gateway is on bridge.
