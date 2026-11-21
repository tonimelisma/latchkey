# Tasks 013: Signing in by itself

Each test is written and seen failing before its code.

- [x] T1 [P] CSV, codes, site matching: `SignInDataTests`, `SignInData.swift` (FR-1300, FR-1321)
- [x] T2 [P] The store: `SignInStoreTests`, `SignInStore.swift` (FR-1303, FR-1310, FR-1324)
- [x] T3 The import folder: tests, `SignInImport.swift` (FR-1301, FR-1303)
- [x] T4 Page scripts and both browsers' fill step: `SignInPageTests` (FR-1311, FR-1321, FR-1322)
- [x] T5 The tools and capability: `SignInToolsTests`, `PublicToolsTests` (FR-1320, FR-1323 to
      FR-1327, FR-1340)
- [x] T6 The one-touch export: `PasswordsExport.swift` (FR-1301, FR-1306); its live run is T11
- [x] T7 The reminder: tests, `SignInReminder.swift` (FR-1304)
- [x] T8 Settings, menu, setup step, uninstall (FR-1302, FR-1305)
- [x] T9 README, STATUS, decisions; regression and live cases (group `logins`)
- [x] T10 Full tests and lint, install, live check (0.8.175: 881 tests; live 51 of 51)
- [x] T11 Toni: Latchkey menu → Export Passwords to Latchkey…, one Touch ID (the first live export;
  done 2026-11-21 with 0.8.177: 1,026 sign-ins in 10 s)
- [x] T12 `OwnSessions`: own sites, cookie reach, fallback, the kept sign-ins in their Keychain
  item, expiry: `OwnSessionsTests` (FR-1350, FR-1352, FR-1353)
- [x] T13 The browser: no copy for an own site or into one, own sites stay in Latchkey's browser
  while unlocked, kept sign-ins back in a new store, unlock keeps them, the answer's first line:
  `OwnSessionsBrowserTests` (FR-1350, FR-1351, FR-1353 to FR-1355)
- [x] T14 Fallback in `logins_sign_in`: locked takes Safari's cookies and loads again; unlocked
  moves to a Safari tab: `SignInToolsTests` (FR-1352)
- [x] T15 Remove All and uninstall remove the kept sign-ins; README, STATUS, decisions, spec 005
  notes; regression and live cases (FR-1354)
- [ ] T16 Full tests and lint, install, live check
