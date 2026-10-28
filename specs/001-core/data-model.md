# Data model (relay, SQLite; the Mac's activity log at the end)

Everything the relay stores. Anything not listed here is not stored (Constitution VI).
Secrets are stored as SHA-256 hashes unless noted. All timestamps are UTC, stored as Unix
milliseconds. Device public keys are stored as PKIX DER.

| Entity | Fields | Notes |
|---|---|---|
| **users** | id, email, email_verified_at, created_at, deleted_at, wrong_codes, wrong_codes_since, suspended_at, suspended_reason | Deleting an account hard-deletes all rows below (FR-045), except **operator_log**. `suspended_at` and `suspended_reason` are set by the operator's `account suspend` (FR-196) and cleared by `account unsuspend`. `wrong_codes` counts wrong emailed codes since `wrong_codes_since`; 20 within a day refuse emailed codes for the rest of that day (FR-042a) |
| **passkeys** | id, user_id, credential_id, public_key, sign_count, transports, aaguid, created_at, last_used_at | WebAuthn credentials |
| **email_tokens** | token_hash, user_id, purpose (`verify` or `recover`), expires_at, used_at, attempts | Single use, 15 min; 5 wrong attempts end a code (FR-042) |
| **web_sessions** | id_hash, user_id, created_at, expires_at | Browser session for account pages |
| **devices** | id, user_id, name, public_key (P-256), app_version, os_version, created_at, revoked_at | One active device per user in this spec |
| **device_state** | device_id, online, connected_at, last_seen_at, offline_reason, state_json, tools_json | Latest state only, no history (FR-020) |
| **pairing_codes** | code_hash, user_id, expires_at, used_at | 5 min, single use |
| ~~oauth_consents~~ | | Dropped 2026-10-25 (migration 6): approvals are not remembered (FR-049a). The account page lists the clients that hold a live access or refresh token in **oauth_requests** |
| **relay_keys** | name, value, format | The relay's own signing keys: the 32-byte HMAC key for OAuth tokens and the CSRF key. Each value is stored encrypted (AES-256-GCM, format 1) under the key in the key file, which is not in the database (FR-186); format 0, the key itself, is what earlier versions wrote and is converted on the first start (FR-188) |
| **oauth_clients** | id, kind (`dcr` or `cimd`), metadata_json, secret_hash, created_at, fetched_at | CIMD documents cached (with their cache expiry), at most the newest 1,000 that no code or token refers to, and deleted a day after their last fetch if none does (FR-095); DCR clients stored, and deleted after 7 days if no code or token for them is live |
| **oauth_requests** | signature, kind (`code`, `pkce`, `access`, `refresh`), request_id, client_id, user_id, requested_at, scopes, granted_scopes, form, session_json, expires_at, used_at, rotated_at, revoked_at | fosite's stored requests, keyed by token signature (never raw tokens). `form` keeps the authorize parameters fosite re-checks (redirect URI, PKCE challenge); `session_json` holds subject and expiry times. Codes live 1 min, access tokens 1 h, refresh tokens 90 days |
| **oauth_grants** | request_id, id, user_id, client_id, client_name, client_host, redirect, approved_at, last_used_at | One row per approval on the Allow page (FR-190): the grant's internal request ID (shared by its rows in **oauth_requests**), its public `id` (16 random bytes, what the Mac app and the account page name it by), and what the consent page showed. `last_used_at` is written at most once a minute (FR-192). Deleted with the grant, and by the daily purge once no code or token of the grant is left |
| **client_authorizations** | id, user_id, client_name, at, notified_at | Each time a Claude client was given access, so the Owner's Mac is told once; kept 30 days |
| **audit_log** | id, user_id, device_id, at, tool, surface, outcome, duration_ms, call_id | No arguments, no results (FR-022, FR-023). Kept until the account is deleted; nothing is deleted by age (FR-024, FR-630; was 30 days until 2026-10-27). `call_id` is the call's id, unique for all time (FR-632; `''` for entries from before migration 12). Index on (device_id, at) for the Mac's comparison (FR-634). A `revoke_client` from the Mac app is recorded with tool `revoke_client` and surface `Latchkey app`, without the grant's ID and with `call_id` `''` |
| **events** | id, at, kind, user_id, device_id, detail, hour, count, last_at | The relay's event record (FR-631, plan D18): Mac connections and their end, keep-awake changes, sign-in attempts and outcomes, Claude apps approved, refused, and removed, pairings and unpairings, and refused or failed requests. `detail` is fixed words the relay chooses (outcome, reason, close code, the app's name), never content, codes, tokens, keys, or IP addresses. Refusals and sign-in attempts anyone can cause are counted: one row per hour, kind, account, and detail (`hour` set, `count`, first `at` and `last_at`); `user_id` is NULL without an account, and an unfinished sign-up counts as none. Kept until the account is deleted (cascade); rows without an account are kept too, and grow by at most one per kind and reason an hour |
| **blocked_emails** | email, blocked_at, reason | Addresses the operator blocked (FR-197), normalized as at sign-up; kept until unblocked |
| **operator_log** | id, at, actor, action, email, user_id, device_id, detail | Every operator command that changed something (FR-195): who ran it (the server's user name), what, when, the address it was about, and the reason given. `user_id` and `device_id` let the running relay close that account's connections (FR-198). Not tied to the account, so it survives the account's deletion; purged after one year (FR-199) |

## Outside the database

- The key file (`KEY_FILE`, default `DATA_DIR/relay.key`): 32 random bytes, readable by the
  relay's user only, made on the first start. It encrypts the values in **relay_keys** and
  nothing else. The hosted relay keeps it outside the data volume (plan D10).

- With built-in TLS (`ACME_EMAIL` set): TLS certificates and the ACME account key, in
  `DATA_DIR/certs`. Nothing about users.

## Not stored

- Tool arguments or results.
- Passkey private keys or device private keys (they never leave the user's devices).
- IP addresses beyond the HTTP access log, which is deleted after 30 days.

## In memory only

- Abuse-limit counters per client address and per account, pending passkey exchanges, and the
  time each grant's `last_used_at` was last written. Gone on restart.

## On the Mac (the Mac app's activity log, never sent to the relay)

Kept in the Owner's Application Support folder and Keychain, not on the relay, so the relay's
privacy policy doesn't list it (the check below reads only the relay's table above).

| Store | Fields | Notes |
|---|---|---|
| `SealedActivity` in `activity.store` (SwiftData) | id, at, sealed, seq, mac, keyID, kind, callID, device | One row per tool call or removal, and since 2026-10-27 per event of the app's own (FR-633), kept until uninstall (FR-026). `sealed` is AES-256-GCM over the entry's JSON (tool, arguments, result, isError, durationMS, with id and time, and since 2026-10-27 the Claude app's name, `client`, when the relay sent one, FR-637; an event's category is its tool and its text its result); since 2026-10-26 seq and id are bound to it as authenticated data. `kind` is "action" or "event"; `callID` the relay's call id (FR-632), "" for events and older entries; `device` the device ID of the pairing the call came through, "" when none (all three in the clear for the comparison with the relay's audit, FR-634, and covered by `mac` whenever one isn't its default; added with defaults, so older rows upgraded in place as actions without a call id). `seq` numbers checked entries 1, 2, … (0 = from before the check); `mac` is the chain's HMAC-SHA256; `keyID` is 8 bytes derived from the log key, as hex ("" = not yet labelled, "-" = under a key already gone). Indexes on (at, seq), seq, keyID (FR-203, FR-612, FR-614) |
| Keychain `activity-log-key` | 32 bytes | The log key (FR-026a, FR-201) |
| Keychain `activity-log-latest` | version, keyID, seq, mac (57 bytes) | The newest entry Latchkey wrote (FR-613) |

## The privacy policy follows this file

`relay/internal/account/legal_test.go` fails when a table above (or a table in the database) is
not named in the privacy policy's list of stored data (FR-194). Add a table here, and say in
the policy what it holds.
