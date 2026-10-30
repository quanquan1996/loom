---
name: loom-retitle
description: Give the user's Loom sessions titles they can tell apart at a glance on a phone — rewrite the ones still named after their first message, or whose topic has moved on. Part of loom-tidy; use on its own when the user says the sidebar is hard to read or asks to rename sessions ("标题看不懂", "session 名字重新起一下", "分不清哪个是哪个").
---

# loom-retitle: titles to pick a session by

A session is named after the first line of its first message: "我想挂个域名了，我
route5…", "如果我mac上登陆teams你…". On a phone the sidebar shows about a dozen
characters of it, and the user reads that to choose where to write. A title is
for choosing: it names the thing, so the right one is found without opening
any.

## Commands

```sh
loom-session list [--project P | --all]     # each row says who titled it
loom-session read ID
loom-session retitle ID TITLE
```

`title=the user's`: leave it; Loom refuses to replace it anyway.
`title=first message`: rewrite it. `title=tidied`: an earlier one of yours;
rewrite it only if the session has moved on since.

## Writing one

- **Short.** At most 12 Chinese characters, or about 20 Latin ones; it is cut
  after that on a phone. The word that tells it apart goes first.
- **The thing, not the request.** "域名续费 Route53", not "我想挂个域名了"; "家里 WiFi 排查",
  not "我家wifi感觉网络好差帮我…". No "我想", "帮我", "一下", no question form.
- **Where it ended up**, not only where it began: read the last turns too. A
  chat that started on icons and became the theme is about the theme.
- **Apart from its neighbours.** Look at every title in the list together.
  Two that would read alike get the word that differs up front: "侧栏 · 未读点",
  "侧栏 · 搜索", not two "侧栏优化".
- **Nothing every title shares**: not the project's name, not "Loom", not a
  date.
- The user's language; their own words for things where they have them
  (product names, nicknames: "健美助理", "钱多多").

For example, from this user's sidebar:

| First message | Title |
|---|---|
| 我想挂个域名了，我route53的域名还有1个月过期，研究一… | 域名续费 Route53 |
| 如果我mac上登陆teams你能读取吗，我锁屏后你还能读取吗 | Mac Teams 读取 |
| engjunq@80a99726fe31 workshop-… | Workshop 实例排错 |
| 更新一下github那个牛逼的产品页 | 产品页更新 |
| 你会剪辑视频吗，我有一些口播的视频需要剪辑… | 口播视频剪辑 |

(Guesses from first messages; read the session before you title it.)

## Doing it

Inside `loom-tidy`, as part of its one go: retitle, and list "old → new" in
its report. Asked directly, likewise: retitle them, then show the list.
Begin with the sessions marked `[new since last tidy]`.
