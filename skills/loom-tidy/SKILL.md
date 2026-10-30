---
name: loom-tidy
description: Tidy the user's Loom sessions so the right one is quick to pick on a phone — retitle, archive and merge, in one go without asking, then report what changed. Runs as a scheduled task too. Use when the user asks to clean up, organise, archive or merge sessions ("整理一下 session", "合并这几个对话", "把没用的归档").
---

# loom-tidy: 整理 session

The sidebar's Recents is where the user, mostly on a phone, picks the session
to write in. Tidying is for making that quick: titles that say what each one
is, what's finished out of the way, each topic in one place. Nothing is deleted, and nothing but the sidebar changes:
an archived session only leaves the lists (it is in Settings → Archived), and
writing in it, or `loom-session unarchive`, brings it back.

## Commands

```sh
loom-session list [--project P | --all] [--archived] [--fresh]
loom-session read ID [--full]
loom-session archive ID...        |  loom-session unarchive ID...
loom-session merge --title T --summary-file F ID...
loom-session retitle ID TITLE
loom-session keep ID...           # looked at, left as it is
```

`list` shows only what is in Recents. Pinned, employee, Dream and bell
sessions never appear and are not yours to tidy. Loom also refuses running
sessions, the one you are in, ones with an open bell notice, and merges across
projects. Don't argue with a refusal; leave that session out.

## 1. Look

Default scope: the current project (home if none). `--all` when the user says
so, and for a scheduled run.

**New first.** `list` puts first the sessions marked `[new since last tidy]`:
never tidied, or written in since. Those are the work; the others were looked
at last time and are already as they should be — leave them unless one now
reads wrong next to a new one (two titles alike, a topic now merged). With
`--fresh` you get only the new ones; when there are none, there is nothing to
do.

`read` each new one whose fate isn't clear from its title and first message
(look at its end too: that's where it stands). For many or long sessions,
read them in parallel with subagents, each returning a 3-line gist.

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
- **Leave** (beyond retitling) anything with business left: a question to the
  user not answered, something waiting on them or on you, a job half done.
  Age doesn't decide it; what is left does. Long is not finished either.
  In doubt, leave it.
- **Keep** what you looked at and left as it was: `loom-session keep`, so the
  next tidying doesn't read it again. Retitle, archive and merge mark it
  themselves.

## 3. Act

Don't ask: the user wants it done in one go, asked or scheduled. Everything
here can be undone (archive → unarchive; a retitle is a rename), so do it all,
then report.

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

## 5. Report

In a short list: retitled (old → new), archived (title, why in a few words),
merged (into what). Say that archived ones are in Settings → Archived and come
back when written in.

Asked in a chat, that is the reply. In a scheduled run, post it to the bell
(`loom-notify` skill) at priority 7, `--key tidy`, one or two sentences: how
many retitled, archived, merged, and Recents now. Nothing changed → no
notice.
