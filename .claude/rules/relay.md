---
paths:
  - "relay/**"
  - "deploy/**"
---

# Relay gotchas (moved from CLAUDE.md, 2026-11-22)

- A relay test or local check that registers its own client must set
  `AllowedClients: oauth.AnyClientHost()`; the default accepts only clients on claude.ai, and
  `/register` answers 403.
- Never start a relay version from before the key file (2026-10-25) on a database a newer one
  has opened: it can't read the encrypted keys. The server's updater only moves forward along main
  and goes back only to the version it replaced; it refuses to update a relay that runs without
  its key file.
- Changing the text of `relay/internal/account/templates/terms.html` or `privacy.html` means
  changing `LegalEffectiveDate` in `relay/internal/account/legal.go`. A new table needs a row in
  `data-model.md` and a phrase in the privacy policy (a test fails otherwise).
