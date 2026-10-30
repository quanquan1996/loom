---
name: loom-notify
description: Post to the user's bell in Loom — something they should see, decide, approve or answer, with a priority from 0 (most urgent) to 10 — and keep it right afterwards (update, re-rate, withdraw); and put things on the user's to-do list when they ask ("加到我的待办", "add to my todo"). Use when work running without the user (a virtual employee, a scheduled task, a sleep, a long job) has something for them, or the user asks for a to-do; not for replying to the user in a chat they are reading.
---

# loom-notify: the user's bell

The user gets many reports a day. The bell puts them in order, so the few that
need them now are seen now, and the rest wait without nagging. Your priority is
what decides when — and whether — they are interrupted. Choose it honestly.

## The command

```sh
loom-notice post --priority N [--key KEY] [--needs read|reply|approve] "summary"
loom-notice list                 # your notices still open
loom-notice withdraw KEY         # take one back
```

It works only in a session Loom started (it reads `LOOM_SESSION_ID`). The
notice links to your session: the user taps it and lands here, so whatever
they need to act on must be in this session's reply, not only in the notice.

A virtual employee reports through its work card's `report` instead (same
priorities, same `key`, `needs`, and `withdraw`); the command works too.

## Choosing the priority

| Priority | Means | What the user gets |
|---|---|---|
| **0–1** | Something is breaking or about to be lost; acting late costs real damage. | Notified at once, even at night. |
| **2** | Blocked, or a decision / permission is needed today, and it cannot wait for the evening. | Notified at once (held until 07:00 at night). |
| **3–5** | Important but can wait for the evening: a decision, a KPI ready for review, a real finding. 3 sooner, 5 later. | One notification at 20:00 for all of them. |
| **6–8** | Worth knowing: progress, a report written, a result. | No notification; seen when the user looks. Gone after a week unread. |
| **9–10** | By the way. | Same, at the bottom. |

- **Default low.** If you hesitate between two, take the less urgent. Most
  work needs no notice at all; never post "nothing happened".
- **Urgent is rare.** One urgent (0–2) a day per source gets through; a
  second the same day is posted as 3 and says so. Save it for what matters.
- **Asking permission** (deploying, deleting, pushing, sending anything out):
  `--needs approve`, priority 2 if it blocks you today, else 3–5. The user
  approves or rejects from the bell; the answer arrives in your session as a
  message (`✅ Approved: …` / `❌ Rejected: …`). Until it does, you are not
  approved.
- `--needs reply` when you need words back; `read` (the default) when it is
  only to know. A `read` notice is done once opened; `reply`/`approve` stay
  until the user answers here.

## Writing the summary

One or two plain sentences, in the user's language: **what**, and **what you
need from them**, with the deadline if there is one. No markdown, no links —
the bell shows plain text. "要部署侧栏改动（2b98e02），需要你批准；今天不批就上不了线"
beats "Deployment update".

## Keeping it right

- **Use a key** for anything you may update: `deploy-2b98e02`,
  `supplier-switch`. Posting the same key again replaces the open notice — new
  text, new priority — instead of adding another.
- **Re-rate** when things change: a deadline came closer, the risk grew → post
  the key again with a lower number; it notifies again only if it became more
  urgent. Say in the summary what changed.
- **Withdraw** what no longer matters (you solved it yourself, it became
  moot). Don't leave the user stale items.
- When you wake up or start a turn, `loom-notice list` and look over what you
  still have open.
- The user answering in your session settles your open notices there.

## The user's to-do list

Beside the bell is the user's own to-do list. **Add to it only when the user
asks you to** ("put it on my list", "加到待办") — never on your own; what you
think they should do is a notice, not a to-do.

```sh
loom-notice todo add "text" [--due YYYY-MM-DD]
loom-notice todos                    # the list, open first
loom-notice todo done|undo|rm ID
```

One line each, in the user's language, phrased as what they will do
("续费域名 loom.example"), with the due date if they gave one.
