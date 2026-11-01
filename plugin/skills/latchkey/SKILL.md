---
name: latchkey
description: How to work on the person's own Macs and Linux servers through Latchkey, a connector that reaches their machines from anywhere. Use whenever the person asks about, or asks you to do, find, check, or change something on, their own computer, Mac, laptop, or server (its battery, disk, files, apps, messages, commands), even if they don't say "Latchkey". Use it especially when no Latchkey tools are available, so you can tell them how to connect it, and when a machine is offline or a Latchkey tool refuses.
---

# Working on the person's machines with Latchkey

Latchkey lets you reach the person's own machines (Macs and Linux servers) through a connector.
The machines dial out to a relay, so they work behind any home router, and when one is off or
asleep the relay answers at once instead of hanging.

What you can do differs from person to person and from machine to machine: the person chooses
on each machine what Claude may use. Work only with the tools you were actually given in this
conversation, and read each tool's description; it states that tool's own rules and limits. In
some apps the tool names carry a prefix (such as `Latchkey:` or `mcp__…__`).

## Where things run

Latchkey's tools are the way to reach the person's machines. Any other tools you have run
somewhere else: a code sandbox runs in the cloud, and a local shell (in Claude Code) runs on the
computer Claude Code is on, which may not be the machine the person means. Whether those other
tools are available, or turned off, says nothing about Latchkey: use Latchkey's tools for the
person's machines even when your own shell or sandbox is off.

## No Latchkey tools in this conversation

If the person asks for something on their computer and you have no Latchkey tools, don't say
you simply can't, and don't stop at offering help. In the same reply, say in a sentence that
Latchkey isn't connected in this conversation, and give the steps that usually fix it:

1. In Claude's Settings → Connectors, check that Latchkey is there and connected; if it shows
   "Connect", click it and sign in with the passkey.
2. If it isn't there, add it: Add custom connector, named Latchkey, with the relay's address
   followed by `/mcp`.
3. Make sure it's turned on for this chat (the tools menu below the message box), then start a
   new chat.

If they don't have Latchkey yet, or this doesn't fix it, use the set-up-latchkey skill. Never
claim to have done something on their machine that you didn't do.

## Choosing a machine

- If the person names a machine, use that one.
- If you don't know which machines there are, or more than one could do the job, call
  `machines` first. It lists each machine, whether it's online, and what it offers.
- If two machines could fit and the person didn't say which, ask them, or do it on each and
  name each machine in your answer. Never pick one silently.
- When only one machine offers a tool, leave the machine out, as the tool descriptions say.
- Say which machine you used when the person has more than one.

## Reading answers

Every answer ends with a short state line: the machine that answered, its state (for a laptop,
battery and power), and the person's other machines. Use it: if something looks off (low
battery, a machine about to sleep, another machine offline), mention it only when it matters to
what they asked.

## A machine that's offline or asleep

The relay answers at once with the reason and when the machine was last seen. Then:

1. Tell the person plainly, in one sentence, with when it was last seen.
2. Say what would bring it back: for a Mac, waking it or opening the lid, a network
   connection, and the Latchkey app running (its key icon in the menu bar); for a server,
   powered on and online (`latchkey status` on the server shows the connection).
3. If another online machine can do the job, offer it.

Don't call the same tool again and again hoping it comes back; try once more only if the
person says it's back, or after some time has clearly passed.

## A Latchkey tool that refuses

When a Latchkey tool refuses, its answer says why: a macOS permission not granted, a part of
Latchkey turned off or set to read-only on that machine, a write outside the allowed places, or
a choice that needs the person. Explain it in plain words and say what the person can change, on
that machine (the Latchkey app's Settings on a Mac; the `latchkey` command on a server,
`latchkey help` lists its settings).

Never get around such a refusal by doing the same thing another way on that machine, such as
with a command instead of the Latchkey tool that refused. The person's settings are their
decision. (This is about Latchkey's refusals only; see "Where things run".)

## Doing the work well

- **Use the most specific tool.** A tool made for the job knows the app's data and respects
  the person's settings; running commands is for what no tool covers.
- **Find, then act.** Look up the exact person, file, note, or event before you send, change,
  or delete. When a search finds several that fit and the action can't be undone, ask which.
- **Long jobs.** Something that takes longer than a tool's wait keeps running; check on it
  later instead of starting it again.
- **Across machines.** A task can span machines in one conversation, for example reading a file
  on the server and saving it on the Mac. Do each step on the right machine and say where each
  step ran.
- **Keep it private.** The person's messages, mail, and files are theirs. Share in your answer
  only what they asked for.
