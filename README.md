# Latchkey

**Use your Mac from Claude, wherever you are.**

Ask Claude on your phone to add eggs to your grocery note, find what Sarah said about Saturday, or
read the PDF sitting in your Downloads. It happens on your Mac at home, even with the lid closed
and nothing set up on your router. If your Mac is asleep, Claude tells you right away.

**Free and open source** · Mac with Apple silicon, macOS 26 or later · Linux servers too

<img src="docs/images/phone-chat.svg" width="300" alt="A phone chat: asked to find the lease PDF on the Mac, Claude answers from the MacBook at home that the lease ends on August 31, 2027, with notice due by July 2, 2027.">

> **Latchkey is in testing; there's no download yet.** To hear when the first release is out,
> click **Watch → Custom → Releases** at the top of this page.

## Get started

1. **Get a relay**, the small always-on service your Mac and Claude meet at. Claude Code sets
   one up for you on Google Cloud's free tier: about 20 minutes, and you only create the account
   and click Allow a few times ([how](docs/self-hosting.md)). Latchkey's first setup step has
   the request to paste into Claude Code.
2. **Download Latchkey and open it.** Enter your relay's address and sign up with your email and
   a passkey (Touch ID).
3. **Give Latchkey macOS's permissions.** Latchkey asks for each one in turn and opens the right
   System Settings page, so macOS never stops Claude to ask while you're away.
4. **Add Latchkey to Claude.** Click **Add to Claude** in Latchkey's last setup step. Claude
   opens with Latchkey filled in: click Add, Add again, and Connect, then sign in with your
   passkey and click Allow. Latchkey keeps reminding you until Claude is connected. If the button
   doesn't work, add it by hand: in Claude, open Customize → Connectors → Add custom connector,
   and paste your relay's address followed by `/mcp`. It works in Claude on the web, on your
   desktop, and on your phone.
5. **Ask Claude something about your Mac**, from anywhere.

[Every step in detail](docs/how-it-works.md#setting-up-the-mac-app-in-detail).

## What you can ask

- "What's on my calendar tomorrow? Text Sam that I'll be late."
- "Find the lease PDF and tell me when it ends."
- "Reply to Dana's email and attach last month's invoice."
- "How much disk space is free? Is my backup still running?"
- "Check my order status on that site I'm signed in to."
- "Add milk to my shopping list and remind me at 6."

Claude can use your Notes, Messages, Mail, Calendar, Reminders, Contacts, files, Safari, the
command line, location and maps, and the screen, but only what you turn on.

## You stay in charge

- **You choose what Claude can do.** Each ability is Off, Read only, or Read & write. One that's
  off doesn't exist as far as Claude knows.
- **You approve every Claude app** that connects, and can remove any of them later.
- **You see everything Claude did**, with a notification for every change.
- **You can pause Claude in one click** from the menu bar.
- **Your content stays yours.** Your notes, messages, mail, and files pass through the relay to
  Claude and are never stored there.
- **Nothing is left behind.** What Claude starts is cleaned up when it's done.

## Also

- **[Linux servers](docs/how-it-works.md#add-a-linux-server):** add a home server, a Raspberry
  Pi, or a rented server with one command.
- **[Run your own relay](docs/self-hosting.md):** on Google Cloud with Claude Code's help, or
  anywhere that runs a container.
- **[How it works](docs/how-it-works.md):** what runs where, every tool, privacy in detail.
- **[Security](SECURITY.md):** report a problem privately; the
  [threat model](docs/threat-model.md) says what is protected and how.
- **[Build from source and contribute](docs/development.md).**

Apache-2.0. Made by Toni Melisma.
