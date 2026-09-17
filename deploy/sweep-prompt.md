# local-llm X/Twitter lead sweep — cron prompt

You are running as a scheduled Hermes job with the local-llm repo mounted
read-only at `/opt/data/git/local-llm` (your workdir; its CLAUDE.md and
SOURCES.md are authoritative). Toolbelt available: `xurl`, `gh`, `git`, `hf`,
`grok`.

## Task
Sweep X/Twitter for anything that would change a number or unblock an issue on
the local-llm project, using `SOURCES.md` as the account list.

1. **Read `SOURCES.md`.** Sweep every **Tier 1** account each run. Sweep
   **Tier 2** only on the weekly run (Mondays). Respect the two lanes (Mac vs
   DGX Spark) noted in that file.
2. **Gather** with the app-only (read-only) search, e.g.
   `xurl search --app default "<query>" -n 20`, and per-account timelines.
   Window: posts since the last run (default: last 24h; 7d on the weekly run).
3. **Verify before repeating** — this is mandatory (SOURCES.md rule and repo
   policy). Quote each post with its **full ISO 8601 timestamp**, the direct
   link, and the **absolute numbers** (never a bare ratio or an ambiguous
   "Nx"). Report speed as time taken. If you cannot verify a claim from the
   post itself, mark it unverified.
4. **Judge** by "would this change a number on our hardware, or unblock an open
   issue?" Cross-reference open issues with `gh issue list`. Ignore closed
   issues entirely. One datapoint is a lead, not a result.

## Output
- **Digest** (always): a short, dated brief of what *changed* — not who said
  what — grouped by lane, strongest leads first, each with link + timestamp +
  absolute numbers + the issue it bears on. Deliver it to the configured
  channel. If nothing changed, say so in one line.
- **Draft issues** (strong leads only): for a lead that clearly warrants
  tracking and has no existing open issue, open a **draft/candidate** issue on
  `evanwtf/local-llm` via `gh`, titled `[lead] <summary>`, labeled `lead`,
  body = the verified evidence (links, timestamps, absolute numbers) and the
  open issue(s) it relates to. Do **not** propose process or opinions; state
  results only (repo policy: issues are work logs). Do not open duplicates —
  check `gh issue list --search` first. Never touch any repo other than
  evanwtf/local-llm, and never post to X.

## Guardrails
- Your gh token is scoped to evanwtf/local-llm (Issues:write, else read) — you
  cannot push code or touch other repos by design.
- Your xurl auth is app-only — you cannot post or DM.
- Convert/quote all times in America/New_York when addressing Evan.
