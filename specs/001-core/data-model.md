# Data model (relay, SQLite)

Everything the relay stores. Anything not listed here is not stored (Constitution VI).
Secrets are stored as SHA-256 hashes unless noted. All timestamps are UTC, stored as Unix
milliseconds. Device public keys are stored as PKIX DER.

| Entity | Fields | Notes |
|---|---|---|
| **users** | id, email, email_verified_at, created_at, deleted_at | Deleting an account hard-deletes all rows below (FR-045) |
| **passkeys** | id, user_id, credential_id, public_key, sign_count, transports, aaguid, created_at, last_used_at | WebAuthn credentials |
| **email_tokens** | token_hash, user_id, purpose (`verify` or `recover`), expires_at, used_at | Single use, 15 min |
| **web_sessions** | id_hash, user_id, created_at, expires_at | Browser session for account pages |
| **devices** | id, user_id, name, public_key (P-256), app_version, os_version, created_at, revoked_at | One active device per user in this spec |
| **device_state** | device_id, online, connected_at, last_seen_at, offline_reason, state_json, tools_json | Latest state only, no history (FR-020) |
| **pairing_codes** | code_hash, user_id, expires_at, used_at | 5 min, single use |
| **oauth_clients** | id, kind (`dcr` or `cimd`), metadata_json, secret_hash, created_at, fetched_at | CIMD documents cached; DCR clients stored |
| **oauth_codes** | signature, client_id, user_id, pkce_challenge, redirect_uri, scopes, expires_at | fosite authorize codes, 1 min |
| **oauth_tokens** | signature, kind (`access` or `refresh`), client_id, user_id, scopes, expires_at, rotated_at, revoked_at | fosite HMAC token signatures, never raw tokens |
| **audit_log** | id, user_id, device_id, at, tool, surface, outcome, duration_ms | No arguments, no results (FR-022, FR-023); purged after retention |

## Not stored

- Tool arguments or results.
- Passkey private keys or device private keys (they never leave the user's devices).
- IP addresses beyond the HTTP access log, which is deleted after 30 days.
