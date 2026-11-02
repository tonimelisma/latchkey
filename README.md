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

1. **Download Latchkey and open it.** Make your account with Touch ID, and the Mac is connected.
2. **Add Latchkey to Claude.** Your account page shows an address: paste it into Claude's
   Settings → Connectors → Add custom connector, then click Allow. It works in Claude on the
   web, on your desktop, and on your phone.
3. **Ask Claude something about your Mac**, from anywhere.

Optional: add the Latchkey plugin so Claude knows its way around (Customize → Plugins → Add
marketplace, enter `tonimelisma/latchkey`; it needs code execution turned on in Settings →
Capabilities). [More about the plugin](plugin/README.md).

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
- **[Run your own relay](docs/self-hosting.md):** the small always-on service your Mac and
  Claude meet at. Claude Code can set one up for you on a free server.
- **[How it works](docs/how-it-works.md):** what runs where, every tool, privacy in detail.
- **[Security](SECURITY.md):** report a problem privately; the
  [threat model](docs/threat-model.md) says what is protected and how.
- **[Build from source and contribute](docs/development.md).**

Apache-2.0. Made by Toni Melisma.
