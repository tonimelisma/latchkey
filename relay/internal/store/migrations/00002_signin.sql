-- Sign-in, OAuth, and pairing (specs/001-core/data-model.md). Secrets are stored as SHA-256 hashes.

-- +goose Up
CREATE TABLE passkeys (
    id              INTEGER PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    credential_id   BLOB NOT NULL UNIQUE,
    credential_json TEXT NOT NULL, -- go-webauthn Credential: public key, sign count, flags, AAGUID
    created_at      INTEGER NOT NULL,
    last_used_at    INTEGER
) STRICT;
CREATE INDEX passkeys_user ON passkeys (user_id);

CREATE TABLE email_tokens (
    token_hash BLOB PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    purpose    TEXT NOT NULL CHECK (purpose IN ('verify', 'recover')),
    expires_at INTEGER NOT NULL,
    used_at    INTEGER
) STRICT;

CREATE TABLE web_sessions (
    id_hash    BLOB PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    reauth_at  INTEGER -- last fresh passkey check, for account deletion (FR-048)
) STRICT;

CREATE TABLE pairing_codes (
    code_hash  BLOB PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER
) STRICT;

CREATE TABLE oauth_clients (
    id            TEXT PRIMARY KEY,
    kind          TEXT NOT NULL CHECK (kind IN ('dcr', 'cimd')),
    metadata_json TEXT NOT NULL,
    secret_hash   BLOB,
    created_at    INTEGER NOT NULL,
    fetched_at    INTEGER
) STRICT;

CREATE TABLE oauth_requests (
    signature      TEXT NOT NULL,
    kind           TEXT NOT NULL CHECK (kind IN ('code', 'pkce', 'access', 'refresh')),
    request_id     TEXT NOT NULL,
    client_id      TEXT NOT NULL,
    user_id        TEXT REFERENCES users (id) ON DELETE CASCADE,
    requested_at   INTEGER NOT NULL,
    scopes         TEXT NOT NULL,
    granted_scopes TEXT NOT NULL,
    form           TEXT NOT NULL,
    session_json   TEXT NOT NULL,
    expires_at     INTEGER NOT NULL,
    used_at        INTEGER,
    rotated_at     INTEGER,
    revoked_at     INTEGER,
    PRIMARY KEY (kind, signature)
) STRICT;
CREATE INDEX oauth_requests_request ON oauth_requests (request_id);
CREATE INDEX oauth_requests_user ON oauth_requests (user_id);
CREATE INDEX oauth_requests_expires ON oauth_requests (expires_at);

CREATE TABLE oauth_consents (
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_id  TEXT NOT NULL,
    scopes     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, client_id)
) STRICT;

CREATE TABLE relay_keys (
    name  TEXT PRIMARY KEY,
    value BLOB NOT NULL
) STRICT;

-- +goose Down
DROP TABLE relay_keys;
DROP TABLE oauth_consents;
DROP TABLE oauth_requests;
DROP TABLE oauth_clients;
DROP TABLE pairing_codes;
DROP TABLE web_sessions;
DROP TABLE email_tokens;
DROP TABLE passkeys;
