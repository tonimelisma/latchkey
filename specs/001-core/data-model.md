# Data model (relay, SQLite)

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
| **relay_keys** | name, value | Server secrets, e.g. the 32-byte HMAC key for OAuth tokens; never leaves the server |
| **oauth_clients** | id, kind (`dcr` or `cimd`), metadata_json, secret_hash, created_at, fetched_at | CIMD documents cached (with their cache expiry), at most the newest 1,000 that no code or token refers to, and deleted a day after their last fetch if none does (FR-095); DCR clients stored, and deleted after 7 days if no code or token for them is live |
| **oauth_requests** | signature, kind (`code`, `pkce`, `access`, `refresh`), request_id, client_id, user_id, requested_at, scopes, granted_scopes, form, session_json, expires_at, used_at, rotated_at, revoked_at | fosite's stored requests, keyed by token signature (never raw tokens). `form` keeps the authorize parameters fosite re-checks (redirect URI, PKCE challenge); `session_json` holds subject and expiry times. Codes live 1 min, access tokens 1 h, refresh tokens 90 days |
| **oauth_grants** | request_id, id, user_id, client_id, client_name, client_host, redirect, approved_at, last_used_at | One row per approval on the Allow page (FR-190): the grant's internal request ID (shared by its rows in **oauth_requests**), its public `id` (16 random bytes, what the Mac app and the account page name it by), and what the consent page showed. `last_used_at` is written at most once a minute (FR-192). Deleted with the grant, and by the daily purge once no code or token of the grant is left |
| **client_authorizations** | id, user_id, client_name, at, notified_at | Each time a Claude client was given access, so the Owner's Mac is told once; kept 30 days |
| **audit_log** | id, user_id, device_id, at, tool, surface, outcome, duration_ms | No arguments, no results (FR-022, FR-023); purged after retention. A `revoke_client` from the Mac app is recorded with tool `revoke_client` and surface `Latchkey app`, without the grant's ID |
| **blocked_emails** | email, blocked_at, reason | Addresses the operator blocked (FR-197), normalized as at sign-up; kept until unblocked |
| **operator_log** | id, at, actor, action, email, user_id, device_id, detail | Every operator command that changed something (FR-195): who ran it (the server's user name), what, when, the address it was about, and the reason given. `user_id` and `device_id` let the running relay close that account's connections (FR-198). Not tied to the account, so it survives the account's deletion; purged after one year (FR-199) |

## Outside the database

- With built-in TLS (`ACME_EMAIL` set): TLS certificates and the ACME account key, in
  `DATA_DIR/certs`. Nothing about users.

## Not stored

- Tool arguments or results.
- Passkey private keys or device private keys (they never leave the user's devices).
- IP addresses beyond the HTTP access log, which is deleted after 30 days.

## In memory only

- Abuse-limit counters per client address and per account, pending passkey exchanges, and the
  time each grant's `last_used_at` was last written. Gone on restart.

## The privacy policy follows this file

`relay/internal/account/legal_test.go` fails when a table above (or a table in the database) is
not named in the privacy policy's list of stored data (FR-194). Add a table here, and say in
the policy what it holds.
