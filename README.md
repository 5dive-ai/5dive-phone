# 5dive phone

**Give your AI agent a spare Android phone. It uses the apps that only live on a phone.**

WhatsApp Business, Instagram, anything without a website. The agent reads the screen, taps and
types. Nothing is installed on the phone.

```
  Your server (agent)  ──── Tailscale ────  Spare Android phone
                                            on a charger
  "reply to Sam on WhatsApp"
     1. reads the screen     [e3] button "Send"  ⚠ send
     2. taps and types       type "On my way", tap Send
     3. about to pay?        it asks you first
```

## Install

On a server running 5dive (self-host: `curl -fsSL https://install.5dive.ai | sudo bash`):

```sh
sudo 5dive plugin add 5dive-ai/5dive-phone
sudo 5dive phone setup     # installs adb, Android's own debugging tool (Debian, Ubuntu)
```

Then tell your agent "connect my phone". It walks you through the five steps below, one at a time.

## Connect the phone (once, about 5 minutes)

Keep the spare phone on a charger.

1. **Settings › About phone**, tap **Build number** seven times. (Samsung: it is under Software
   information.)
2. Install **Tailscale** on the phone and sign in with the same account as your server.
3. In **Developer options**, turn on **Stay awake** and **Disable adb authorization timeout**
   (Android 11+). Set **Screen lock** to None or Swipe.
4. Turn on **Wireless debugging** and tap **Pair device with pairing code**. Give your agent the
   6-digit code and the ports. Keep that screen open until it says it's connected.
5. If the phone asks **"Allow debugging?"**, tick Always allow and tap Allow.

The agent then moves the connection to a fixed port (5555), so a dropped connection comes back on
its own.

## You decide what it may do alone

Sending, posting, deleting and paying follow one switch, shared with
[5dive browser](https://github.com/5dive-ai/5dive-browser):

| Setting | Pay | Send, post, delete |
|---|---|---|
| **standard** (default) | asks you | goes ahead, logged |
| **careful** | asks you | asks you |

```sh
sudo 5dive phone approvals policy set careful
```

An ask reaches you as an Approve button in Telegram, and nothing runs until you tap it. Every
step the agent takes is logged on your server.

## Limits

- **A locked phone can't be used.** Set the screen lock to None or Swipe.
- **After the phone restarts**, turn Wireless debugging on again and send your agent the new port.
  No new code is needed.
- **Typing is plain English letters only** for now: no emoji, accents or Cyrillic.
- **Websites** go through 5dive browser on the server. They read badly on the phone.
- **Android only.** iPhone is not supported.
- **Some apps refuse to run** when developer mode is on, banking apps especially. Automated taps
  can also break an app's terms: check them before you hand the app to your agent.

## More

- What the agent runs: [`phone/README.md`](phone/README.md)
- Changes: [`CHANGES.md`](CHANGES.md) · Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Apache 2.0, see [`LICENSE`](LICENSE)
