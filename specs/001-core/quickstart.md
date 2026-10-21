# Quickstart: from a fresh Mac and a fresh Claude account

The setup checklist for SC-01 (under 5 minutes, under 10 actions, no router or Terminal steps).
Each numbered step is one action by the Owner. The relay address is shown as
`https://relay.example.com`.

## On the Mac

1. Open Latchkey (downloaded from the project's releases). A key appears in the menu bar.
2. macOS says a background item was added: click it, and turn on Latchkey in System Settings →
   General → Login Items (once; this is the keep-awake helper, FR-073).
3. In the menu, choose **Connect to a Relay…**, enter `https://relay.example.com`, and press
   Connect. The browser opens.
4. Choose **Create an account**, enter your email, and press Continue.
5. Open the link in the email and press **Create passkey** (Touch ID).
6. Press **Connect**. The menu now says Connected.

## In Claude

7. On claude.ai: Settings → Connectors → **Add custom connector**, paste
   `https://relay.example.com/mcp`, and press Add, then Connect.
8. Sign in with your passkey and press **Allow**.

## Try it

9. In Claude on your phone, ask "What's my laptop's battery?". The connector is already there,
   because connectors added on claude.ai follow the account to Desktop and the phone apps (US1).

That is 9 actions. Creating the account during step 4 means Claude's own sign-in (step 8) needs
only the passkey, with no email round trip inside Claude's sign-in window.

## What to expect when the Mac is away

- Mac asleep or shut down: Claude answers right away with "Your Mac is offline…" and the reason
  when known (US2).
- Ask Claude "Is my laptop online?" to get `laptop_status` at any time.
