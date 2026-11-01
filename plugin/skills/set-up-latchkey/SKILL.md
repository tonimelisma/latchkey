---
name: set-up-latchkey
description: Helps the person set up and fix Latchkey, which lets Claude reach their own Mac or Linux server from anywhere. Covers connecting Claude to a Latchkey relay (claude.ai, Claude Desktop, phones, Claude Code), pairing a Mac or a Linux server, setting up their own relay, and fixing a connection that stopped working. Use when the person asks about installing, connecting, pairing, or troubleshooting Latchkey, or wants Claude to use their computer remotely while no Latchkey tools are available.
---

# Setting up Latchkey

## How to help

- Plain, short sentences; explain a technical word in a few words when you must use one.
- Do what you can yourself; ask the person only for what only they can do (create an account,
  sign in with their passkey, click Allow, type a code).
- Find out where they are before giving steps, then give only the steps they still need, one
  part at a time, and check each worked.

## The three parts

1. **The relay**: a small always-on server that passes messages between Claude and the
   machines. It has an address like `https://relay.example.com`. The person signs in to it with
   a passkey; its account page lists their machines and shows how to add one.
2. **The machines**: the Latchkey app on a Mac, or the Latchkey program on a Linux server. Each
   dials out to the relay, so nothing is opened on the person's router. On each machine the
   person chooses what Claude may use there.
3. **The connector**: in Claude, the relay's address followed by `/mcp`. Through it Claude
   reaches every machine on the account.

Ask: do they have a relay (someone runs one for them, or their own), and which of the other two
parts are done?

## No relay yet

They can use a relay someone they trust runs (they need its address), or set up their own on a
free cloud server, which takes about 20 minutes.

Setting up their own relay needs Claude Code on their computer, because it runs commands. If
you are Claude Code and can run commands, read `own-relay.md` in this skill's folder and follow
it from the start. Otherwise, tell them to install Claude Code (https://code.claude.com) and ask
it: "Set up a Latchkey relay for me, following
https://raw.githubusercontent.com/tonimelisma/latchkey/main/plugin/skills/set-up-latchkey/own-relay.md".
The Mac app's first setup step also has a Copy Request button that copies that request.

## Pair a Mac

1. Install the Latchkey app (the Get started section of https://github.com/tonimelisma/latchkey
   says where to get it) and open it. Its key icon appears in the menu bar.
2. Its setup window walks through each step: enter the relay's address and click Connect, sign
   in with the passkey in the browser, click Allow, then allow each macOS permission it asks
   for.
3. On the Mac, Latchkey's Settings choose what Claude may use there and show its activity.

## Pair a Linux server

1. On the relay's account page, under Add a machine, copy the install line (it has the relay's
   address filled in).
2. On the server, signed in as the account Claude should use (not root), run it. If you are
   Claude Code with a shell on that server, you can run it yourself.
3. It shows a short code. The person opens the relay's `/link` page on any device where they're
   signed in, types the code, and clicks Connect.
4. The service then starts by itself and comes back after reboots. `latchkey status` on the
   server shows the connection, and `latchkey help` lists everything else (what Claude may use
   there, pausing, the activity log, uninstalling).

## Connect Claude

- **claude.ai, Claude Desktop, phones**: on claude.ai or in Desktop, Settings → Connectors → Add
  custom connector. Name it Latchkey, enter the relay's address followed by `/mcp` (for example
  `https://relay.example.com/mcp`), click Connect, sign in with the passkey, and click Allow. It
  then works on the web, in Desktop, and on their phone. Connectors can't be added on a phone.
- **Claude Code**: if they sign in to Claude Code with their claude.ai account, the connector
  from claude.ai is already there. Otherwise run
  `claude mcp add --transport http latchkey https://relay.example.com/mcp` with their address,
  then sign in through `/mcp` in a Claude Code session.
- **This plugin**: on claude.ai or in Desktop, Customize → Plugins → Add marketplace, enter
  `tonimelisma/latchkey`, then add the Latchkey plugin. In Claude Code:
  `claude plugin marketplace add tonimelisma/latchkey`, then
  `claude plugin install latchkey@latchkey`. On claude.ai, plugin skills need code execution
  turned on (Settings → Capabilities).

## Check it works

In a new chat, ask "Which machines can you reach?". Claude calls `machines` and lists each
machine and whether it's online. Then ask something simple on one of them.

## When something doesn't work

- **No Latchkey tools in a chat**: check that the connector shows as connected in Settings →
  Connectors, and that it's turned on for this chat in the chat's tools menu below the message
  box. Start a new chat after adding or reconnecting it, since some apps fix the list of tools
  when a chat starts.
- **Claude asks to sign in again, or calls fail with an authorization error**: reconnect the
  connector in Settings → Connectors and sign in with the passkey. Someone may have removed
  Claude's access on the relay's account page.
- **A machine shows as offline**: a Mac must be awake, online, and running Latchkey (key icon
  in the menu bar); a server must be on and online (`latchkey status`). The relay's account page
  shows when each machine was last seen.
- **Lost passkey on their own relay**: see "If they lose their passkey" in `own-relay.md`.
  On a relay someone else runs, they ask that person.
- **The relay's address doesn't open at all**: on a relay someone else runs, tell that person.
  On their own, `own-relay.md` names the hosting company and the server to check.
- **A machine was replaced or renamed**: pair it again; the other machines stay paired.
