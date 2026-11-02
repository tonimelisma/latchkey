# Latchkey

**Use your Mac from Claude, wherever you are.**

Ask Claude on your phone to add eggs to your grocery note, find what Sarah said about Saturday, or
read the PDF sitting in your Downloads. It happens on your Mac at home, even with the lid closed
and nothing set up on your router. If your Mac is asleep, Claude tells you right away.

**Free and open source** · Mac with Apple silicon (M1 or newer), macOS 26 or later · Linux servers too

<img src="docs/images/phone-chat.svg" width="300" alt="A phone chat: asked to find the lease PDF on the Mac, Claude answers from the MacBook at home that the lease ends on August 31, 2027, with notice due by July 2, 2027.">

> **Latchkey is in testing; there's no download yet.** To hear when the first release is out,
> click **Watch → Custom → Releases** at the top of this page (needs a free GitHub account).

## Get started

1. **Install Latchkey on your Mac** (once it's released) and open it.
2. **Let Claude set it up with you** (about 20 minutes). In Latchkey's first setup step, click
   **Copy Request**. Open the Claude app on your Mac, click the **Code** tab, paste, and press
   Return. Claude builds your relay, a small always-on service on the internet where Claude and
   your Mac meet, and walks you through the rest one click at a time:
   - sign in to Google Cloud and add a card (Google asks for one; the relay stays within its
     free tier, and Google emails you if anything ever costs more than $1);
   - connect Latchkey to your relay and make a passkey with Touch ID;
   - allow macOS's permissions, so macOS never stops Claude to ask while you're away (you can
     turn any ability off later);
   - add Latchkey to Claude: Claude opens a form already filled in; click **Add**, then **Add**
     once more and **Connect**; on the Latchkey page that opens, use Touch ID and click
     **Allow**.

   The Code tab comes with Claude's paid plans (Pro or Max).
3. **Ask Claude something about your Mac**, from your phone or anywhere.

Already have a relay? Paste its address in Latchkey's first setup step and click Connect;
Latchkey's last step, **Add to Claude**, does the rest, and keeps reminding you until Claude is
connected. If that button doesn't work: on claude.ai, click **Customize**, then **Connectors**,
then **Add custom connector**, and paste your relay's address with `/mcp` right after it (no
space), like `https://relay.example.com/mcp`. Do this once; Claude on your phone then has it too.

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
