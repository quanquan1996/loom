---
name: loom-guide
description: Answer questions about Loom itself — what it can do, how a feature works or is set up, where its settings and data live, how to deploy or restart it. Use when the user asks about Loom, this web UI, its sessions, projects, tasks/cron, devices, browser, canvas, keys or deployment ("loom 怎么…", "这个软件支持…吗", "how do I … in Loom").
---

# loom-guide: read Loom's own docs before answering

Loom's documentation lives in its checkout, which is not necessarily your
working directory. Find it from the service:

```sh
systemctl cat loom | grep WorkingDirectory    # usually ~/loom
```

Then read the file that fits the question, rather than answering from memory:

- `README.md` — what Loom does, feature by feature, for the user.
- `docs/architecture.md` — how each part works: sessions, channels, devices
  (loom-node), the browser, cron, files.
- `docs/deploy.md` — installing, the systemd unit, `rel/deploy.sh`, restarts.
- `docs/backends.md` — the Claude Code and Codex backends.
- `docs/keys.md` — API keys and credentials.

If the docs don't settle it, read the code: `lib/` (Elixir server),
`frontend/src/` (UI), `node/` (loom-node). Say which you checked.

Restarting Loom ends every session, this one included. Don't do it unasked.
Ask Loom to restart once sessions are idle with
`_build/prod/rel/loom/bin/loom rpc 'Loom.Restarter.request()'`, which is how
`rel/deploy.sh` does it.
