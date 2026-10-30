---
name: loom-handoff
description: Hand a matter off to a new session in the user's Loom Recents, with a brief that lets it carry on — only once the user has agreed. Use when something you came across belongs in a conversation of its own (another topic, another project, work that isn't your job), when the user says "开个新会话接着做 / 转给一个新 session / 单独开一个聊", or when you, a virtual employee, find something the user should take on outside your work.
---

# loom-handoff: 转交到一个新会话

A handoff opens a new session in the sidebar's Recents (in a project, or at
home) that begins with your brief. The user opens it, and it carries the
matter on from there as if it had been there all along. Nothing of yours
moves: your session goes on as before.

## First, the user agrees

Never hand off on your own. Ask first, and wait for a yes:

- **The user is reading** (a chat, a session they are in): ask in your reply,
  in a line — what you would hand off, where to, and whether it should start
  now. Their "好 / 开吧" is the agreement.
- **The user is not reading** (a virtual employee's work turn, a scheduled
  task, a sleep): ask through the bell, `--needs approve` (the `loom-notify`
  skill; an employee may use its card's `report` with `"needs": "approve"`).
  Priority 4–6 unless it is urgent. Hand off only when `✅ Approved` comes
  back; on `❌ Rejected`, drop it.

What they agreed to is what you do: their project, their title, start now or
not. If they changed the plan, follow the change.

## The command

```sh
loom-session handoff --title T --brief-file F [--project ID|home] [--start]
```

- `--title`: what the matter is, short, as the user would tell it apart on a
  phone (the `loom-retitle` skill's rules).
- `--project`: where it belongs. Default is your own session's project — for
  a virtual employee that is home, so name the project if there is one
  (`loom-session list --all` shows project ids).
- `--start`: it begins on the brief at once, without waiting for the user.
  Only when the user said to start now; it costs a turn they did not watch.
- `--brief-file -` reads the brief from stdin.

It prints the new session's id. Tell the user, in a line, that it is there
and under what title.

## The brief

The new session knows nothing but the brief (the user reads it too, as its
first message). Write it for the agent who carries on, in the user's language:

- **What** the matter is and **why** it is handed off, in a sentence or two.
- **What the user wants**, in their words where you have them, and what they
  already decided or rejected.
- **What is known**: findings, numbers, where things are (paths, ids, URLs,
  commits). Paths in full.
- **What is next**: the first step, and what done looks like.
- **Who handed it off**, so it can be asked back: your name or session.

No transcript dumps, no secrets. A good brief is a page at most.
