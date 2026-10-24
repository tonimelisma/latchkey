# Data model (relay, SQLite)

Everything the relay stores. Anything not listed here is not stored (Constitution VI).
Secrets are stored as SHA-256 hashes unless noted. All timestamps are UTC, stored as Unix
milliseconds. Device public keys are stored as PKIX DER.

| Entity | Fields | Notes |
|---|---|---|
| **users** | id, email, email_verified_at, created_at, deleted_at, wrong_codes, wrong_codes_since | Deleting an account hard-deletes all rows below (FR-045). `wrong_codes` counts wrong emailed codes since `wrong_codes_since`; 20 within a day refuse emailed codes for the rest of that day (FR-042a) |
| **passkeys** | id, user_id, credential_id, public_key, sign_count, transports, aaguid, created_at, last_used_at | WebAuthn credentials |
| **email_tokens** | token_hash, user_id, purpose (`verify` or `recover`), expires_at, used_at, attempts | Single use, 15 min; 5 wrong attempts end a code (FR-042) |
| **web_sessions** | id_hash, user_id, created_at, expires_at | Browser session for account pages |
| **devices** | id, user_id, name, public_key (P-256), app_version, os_version, created_at, revoked_at | One active device per user in this spec |
| **device_state** | device_id, online, connected_at, last_seen_at, offline_reason, state_json, tools_json | Latest state only, no history (FR-020) |
| **pairing_codes** | code_hash, user_id, expires_at, used_at | 5 min, single use |
| **oauth_consents** | user_id, client_id, scopes, created_at | Remembered approvals (FR-049); deleted when Claude's access is revoked |
| **relay_keys** | name, value | Server secrets, e.g. the 32-byte HMAC key for OAuth tokens; never leaves the server |
| **oauth_clients** | id, kind (`dcr` or `cimd`), metadata_json, secret_hash, created_at, fetched_at | CIMD documents cached; DCR clients stored, and deleted after 7 days if no code or token for them is live |
| **oauth_requests** | signature, kind (`code`, `pkce`, `access`, `refresh`), request_id, client_id, user_id, requested_at, scopes, granted_scopes, form, session_json, expires_at, used_at, rotated_at, revoked_at | fosite's stored requests, keyed by token signature (never raw tokens). `form` keeps the authorize parameters fosite re-checks (redirect URI, PKCE challenge); `session_json` holds subject and expiry times. Codes live 1 min, access tokens 1 h, refresh tokens 90 days |
| **audit_log** | id, user_id, device_id, at, tool, surface, outcome, duration_ms | No arguments, no results (FR-022, FR-023); purged after retention |

## Outside the database

- With built-in TLS (`ACME_EMAIL` set): TLS certificates and the ACME account key, in
  `DATA_DIR/certs`. Nothing about users.

## Not stored

- Tool arguments or results.
- Passkey private keys or device private keys (they never leave the user's devices).
- IP addresses beyond the HTTP access log, which is deleted after 30 days.
