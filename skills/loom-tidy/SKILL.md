---
name: loom-tidy
description: Tidy the user's Loom sessions so the right one is quick to pick on a phone — retitle, archive and merge, propose a plan, and carry it out once the user confirms. Use when the user asks to clean up, organise, archive or merge sessions ("整理一下 session", "合并这几个对话", "把没用的归档").
---

# loom-tidy: 整理 session

The sidebar's Recents is where the user, mostly on a phone, picks the session
to write in. Tidying is for making that quick: titles that say what each one
is, what's finished out of the way, each topic in one place. Nothing is deleted, and nothing but the sidebar changes:
an archived session only leaves the lists (it is in Settings → Archived), and
writing in it, or `loom-session unarchive`, brings it back.

## Commands

```sh
loom-session list [--project P | --all] [--archived]
loom-session read ID [--full]
loom-session archive ID...        |  loom-session unarchive ID...
loom-session merge --title T --summary-file F ID...
loom-session retitle ID TITLE
```

`list` shows only what is in Recents. Pinned, employee, Dream and bell
sessions never appear and are not yours to tidy. Loom also refuses running
sessions, the one you are in, ones with an open bell notice, and merges across
projects. Don't argue with a refusal; leave that session out.

## 1. Look

Default scope: the current project (home if none). `--all` only when the user
says so. `list` first; `read` only the ones whose fate isn't clear from the
title and first message. For many or long sessions, read them in parallel
with subagents, each returning a 3-line gist.

## 2. Decide

- **Archive**: a one-off question that got its answer; empty or 1-turn
  sessions that went nowhere; work whose outcome is already recorded
  (committed, deployed, in memory).
- **Merge**: two or more about the same thing, where the next message could go
  to any of them. Same project only. Close topics aren't enough: "font size"
  and "icons" are both UI, but separate jobs.
- **Retitle** every session that stays in Recents and whose title doesn't say
  what it is (most first-message titles): follow the `loom-retitle` skill.
  The merged sessions' titles follow it too.
- **Long but still in use**: leave it. Long is not finished.
- **Leave** (beyond retitling): anything active in the last 2 days, anything
  in doubt.

## 3. Propose

Show one table: action, sessions (title, age), one-line reason, grouped by
action; for a retitle, "old → new". Then a loom:replies question per action so the user can take some and
not others. Do nothing before they answer. Running unattended (a task, a
Dream) → don't act: post the plan with `loom-notice --needs approve`.

## 4. The summary (merge)

The merged session starts on a new conversation: the summary is all it will
know of the old ones (it is shown to the user too, as its first message). Write it
for the agent who carries on, in the user's language:

- Goal and the decisions taken, with the user's reasons in their words.
- Current state: what is done (commit, files, deployed or not), what's open.
- Where things are: paths, ids, URLs.
- What the user rejected, so it isn't offered again.

Facts only, no story of how the conversation went. A screen or two is plenty.
For a merge, one section per source, and a title naming the topic.

## 5. Do and report

Run the commands, then tell the user in a short list what moved where, and
that archived sessions are in Settings → Archived.
