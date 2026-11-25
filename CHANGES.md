# 5dive phone — changelog

One plugin, one repo, one changelog. The 0.1.0 entry was carried over from
`5dive-ai/5dive-plugins/CHANGES.md`, where the plugin started (DIVE-9064, 5dive-plugins#359).

## Unreleased

## 0.2.0 — typing in any language; a restart needs one switch, not a port (DIVE-9242)

- `type` takes any text: Cyrillic, accents, emoji, line breaks. Plain English text still goes through
  adb's `input text`; anything else is pasted. `lib/type.dex` (our own code, built reproducibly from
  `android/` by `android/build.sh`, sha256 in `lib/type.dex.sha256`) is copied to
  `/data/local/tmp` for that step, run with Android's `app_process` as the adb shell user to set the
  clipboard (marked sensitive, without the "Copied" panel), a Paste key types it, then the clipboard is
  emptied and the file deleted. No app is installed. A pasted line break never sends. A type step is
  capped at 4000 characters. Text containing a literal `%s`, which `input text` turned into a space, is
  pasted too.
- After a restart the owner only switches Wireless debugging back on: the next command finds the port
  it picked (`lib/ports.py` tries the phone's ephemeral ports, a few hundred at a time), connects with
  the existing pairing and pins 5555 again. `connect <ip>` with no port does the same. Exit 69 now
  tells a phone that is off or off Tailscale apart from one whose Wireless debugging is still off.
- Harness: 116 arms (19 new; 19 red on 0.1.1). Live on the redroid rig (Android 13): "Мария Ž 👋"
  typed into Contacts and read back, nothing left in `/data/local/tmp`; adbd moved to a random port
  was found in 8.5 s and pinned back to 5555.

## 0.1.1 — the phone plugin's own repo (DIVE-9230)

- The plugin now lives at `5dive-ai/5dive-phone` and installs with
  `sudo 5dive plugin add 5dive-ai/5dive-phone`. The manifest's `homepage` names this repo. The code is
  byte-for-byte 0.1.0. `phone@5dive-plugins` keeps working: that copy is a mirror of this repo's
  `phone/`, checked on every 5dive-plugins pull request.

## 0.1.0 — your agent uses apps on a spare Android phone (DIVE-9064)

- New plugin `phone` (`5dive phone`). It drives an Android phone the owner sets aside, over adb on the phone's Tailscale address; the screen is read with uiautomator and taps and typing go through `input`, both part of Android, so nothing is installed on the phone and no third-party code runs on either side. Same shape as the browser: `snapshot` prints controls with refs (`[e3] button "Send"  ⚠ send`, or by name `button/Send`), `act --steps=[…]` opens apps and links, taps, types, scrolls and presses keys, `screenshot` saves a private PNG. `guide` and `connect` cover the one-time setup (Developer options, Wireless debugging pairing, then adb's fixed port 5555); after a phone restart every command exits 69 with the words to send the owner.
- Sending, posting, paying and deleting follow the owner's browser policy (the same file): a tap on such a control, or a step the agent labels with `kind`, stops with exit 73 BEFORE any step runs when the policy says ask (a money button — Send money, Send payment, Request money, Withdraw, Send $50 or Send 50 USD, and Geld senden, Überweisen, Enviar dinero, Transferir, Virement, Отправить деньги, Перевод — is paying, so the default asks for it), writes the ask in the browser's format and hands it to `5dive owner-ask`, so the owner's Approve button and `sudo 5dive browser approve <id>` answer it. The grant fits those exact steps on that phone, once, for 30 minutes. Every step is logged to the seat's `~/.5dive/phone/actions.jsonl` (0600).
- Harness: `tests/phone_unit.sh` against a fake adb. Live arm on the redroid rig (Android 13): Contacts opened, text typed and read back from the snapshot; a Send under careful stopped with nothing typed, the approved re-run sent, the spent grant was refused.
