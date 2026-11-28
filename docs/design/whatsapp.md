# WhatsApp: design

GOVERNS: `macos/App/WhatsApp/`

Spec 012's plan (migrated from `specs/012-whatsapp/plan.md`, titled "Plan 012: WhatsApp — HOW"). What it must do:
[requirements/whatsapp.md](../requirements/whatsapp.md). Each decision Dn is an ADR, linked
where the decision stood.

Spec: `docs/requirements/whatsapp.md`. Research and every test behind these choices: `docs/research/2026-11-02-whatsapp.md`. Extended
2026-11-05: replies, reactions, deleting, "me", older history (D5), and WhatsApp for Mac's window
as the fallback again (D3b). Rebuilt on
2026-11-04 after the maintainer chose (spec FR-1206, FR-1208, FR-1215, FR-1222): no linked device of
Latchkey's own; sending only through WhatsApp Web in Safari, opened in a tab when none is;
WhatsApp for Mac's database for reading while that app runs. The first build (0.8.101 to
0.8.114) ran WhatsApp Web in a hidden page of Latchkey's own, linked by QR or code; what it taught
is kept below where it still applies.

## D1. The Owner's WhatsApp Web tab in Safari

Decision record: [ADR 0137](../adr/0137-the-owners-whatsapp-web-tab-in-safari.md).

## D2. Driving WhatsApp Web: its own functions, not its screen

Decision record: [ADR 0138](../adr/0138-driving-whatsapp-web-its-own-functions-not-its-screen.md).

## D3. WhatsApp for Mac's window (withdrawn 2026-11-04)

Decision record: [ADR 0139](../adr/0139-whatsapp-for-macs-window.md).

## D3b. WhatsApp for Mac's window again, as the fallback (2026-11-05)

Decision record: [ADR 0140](../adr/0140-whatsapp-for-macs-window-again-as-the-fallback.md).

## D4. Latchkey's own device, removed

Decision record: [ADR 0141](../adr/0141-latchkeys-own-device-removed.md).

## D5. Tools

Decision record: [ADR 0142](../adr/0142-tools.md).

## D6. Deadline

Decision record: [ADR 0143](../adr/0143-deadline.md).

## D7. Off

Decision record: [ADR 0144](../adr/0144-off.md).

## Constitution check

- I (outbound only): nothing listens; Safari and WhatsApp for Mac make their own connections.
- II (fail fast): every Safari script has a deadline; an unusable tab or a locked Mac answers at
  once with why; every wait in WhatsApp for Mac's window is bounded (a few seconds each, 10 s
  for the database to confirm).
- III (off is invisible): Off removes the tools.
- IV (real Mac app): AppleScript, a URL scheme, and Accessibility; all Apple-supported.
- VI (relay stores no results): unchanged.
- VII (tests first): bridge contract tests run the JavaScript against a stand-in of WhatsApp's
  modules; the Safari call's JavaScript runs in a real WebKit view; tool tests use fake tab and
  window and a fixture copy of the desktop database; the live check runs against real WhatsApp.
