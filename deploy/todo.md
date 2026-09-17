# TODO — manual steps to get Hermes working

Things only you can do (accounts, tokens, interactive auth, builds). Ordered.
Full context for each is in `deploy/README.md`. All commands run from the repo
root (`~/git/hermes-agent`) unless noted.

Note on "Discord webhook": Hermes uses a **Discord bot** (gateway), not an
incoming webhook. So the Discord steps are: create a bot app, grab its token,
and allowlist your user ID. No webhook URL involved.

---

## 0. Land the code
The deploy branch is committed but the push was blocked (needs your hand):
- [ ] Push: `git -C ~/git/hermes-agent/.claude/worktrees/hermes-deploy-config push -u origin worktree-hermes-deploy-config`
- [ ] Merge to main (PR or local) — your fork, your call.
- [ ] (Optional) delete the now-superseded staging copy: `rm -rf ~/hermes-deploy`

## 1. GitHub token (for the sweep to file issues)
- [ ] Create a **fine-grained PAT**: https://github.com/settings/personal-access-tokens/new
  - Resource owner: **evanwtf**
  - Repo access: **Only select → evanwtf/local-llm**
  - Permissions: **Issues = Read/write**, **Contents = Read**, **Metadata = Read**
- [ ] Keep it handy for step 4 (you'll paste it once).

## 2. Discord bot (communication)
- [ ] https://discord.com/developers → **New Application** → **Bot**.
- [ ] **Bot → Privileged Gateway Intents → enable _Message Content Intent_.**
      (Leave _Server Members_ OFF — we allowlist by numeric ID.)
- [ ] **OAuth2 → URL Generator**: scopes `bot` + `applications.commands` →
      invite the bot to a **private** server (or plan to just DM it).
- [ ] Copy the **bot token**.
- [ ] Turn on **Developer Mode** (Settings → Advanced), right-click yourself →
      **Copy User ID** (a big number). Keep both for step 7.

## 3. xAI / SuperGrok (grok CLI + native x_search)
- [ ] Confirm you're logged into grok on the host (`~/.grok/auth.json` exists —
      it does). `stage-creds.sh` copies it into the container profile.
- [ ] You'll also run `hermes auth add xai-oauth` in step 6 for the native
      `x_search` tool (interactive OAuth, one time).

## 4. Stage credentials into ~/.hermes
- [ ] If `~/.hermes` is owned by uid 10000 (a prior container started without
      HERMES_UID chowned it), reclaim it first:
      `sudo chown -R "$(id -u):$(id -g)" ~/.hermes`
      Then ALWAYS launch with `HERMES_UID=$(id -u) HERMES_GID=$(id -g)` so it
      stays yours (stop any old container started without it).
- [ ] `bash deploy/stage-creds.sh`  → paste the GitHub token when prompted.
      (Copies xurl/hf/grok auth + writes git identity; no secrets printed.)

## 5. Build the image (two-step)
- [ ] `HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose build`
- [ ] `HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose -f docker-compose.yml -f deploy/docker-compose.override.yml build`
- [ ] If it fails to boot on caps, read the s6 log and add the one capability it
      names to `deploy/docker-compose.override.yml` (x-hardening block).

## 6. Bring it up + finish auth
- [ ] `HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose -f docker-compose.yml -f deploy/docker-compose.override.yml up -d`
- [ ] `docker exec -it hermes hermes auth add xai-oauth`  (SuperGrok sign-in)
- [ ] Verify toolbelt:
      `docker exec -it hermes bash -lc 'gh auth status && hf version && xurl search --app default "dgx spark" -n 3 | head && grok --version && git -C /opt/data/git/local-llm log -1 --oneline'`

## 7. Wire up Discord
- [ ] `docker exec -it hermes hermes gateway setup`  (choose Discord, paste bot
      token + your numeric user ID) — or append to `~/.hermes/.env`:
      `DISCORD_BOT_TOKEN=...` and `DISCORD_ALLOWED_USERS=<your-id>`.
- [ ] **Do NOT** set `DISCORD_ALLOW_ALL_USERS=true` (agent has code-exec + gh).
- [ ] `docker exec -it hermes hermes gateway restart` && `... gateway status`.
- [ ] DM the bot to confirm it replies; in your `#hermes` channel run `/sethome`.

## 8. Schedule the sweep
- [ ] `mkdir -p ~/.hermes/sweeps && cp deploy/sweep-prompt.md ~/.hermes/sweeps/`
- [ ] Create the job (points `--deliver` at Discord now that it's up):
```
docker exec -it hermes hermes cron create "every day 9am" \
  "Read /opt/data/sweeps/sweep-prompt.md and carry out the local-llm X/Twitter lead sweep it describes." \
  --name local-llm-x-sweep --workdir /opt/data/git/local-llm --skill xurl --deliver discord
```
- [ ] Test once: `docker exec -it hermes hermes cron run local-llm-x-sweep`.

## 9. Decisions (optional, defaults are safe)
- [ ] If Hermes' own `model.default` uses a **local** engine, change that URL in
      `config.yaml` from `127.0.0.1` to `host.docker.internal` (gateway is on
      bridge now). If it's a hosted provider, skip.
- [ ] Approvals: keep `mode: smart` or switch to `manual` (prompts on every
      dangerous command). `cron_mode`/`unattended_mode` already `deny`.
- [ ] Trim toolsets on this headless box: `docker exec -it hermes hermes tools`
      (disable computer_use / browser / voice / image-gen if unused).
