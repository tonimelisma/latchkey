-- Tables for milestone M1 (specs/001-core/data-model.md). Timestamps are Unix milliseconds, UTC.

-- +goose Up
CREATE TABLE users (
    id                TEXT PRIMARY KEY,
    email             TEXT NOT NULL UNIQUE,
    email_verified_at INTEGER,
    created_at        INTEGER NOT NULL,
    deleted_at        INTEGER
) STRICT;

-- Revocation deletes the public key (plan D6), so a key exists exactly while not revoked.
CREATE TABLE devices (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    public_key  BLOB,
    app_version TEXT NOT NULL DEFAULT '',
    os_version  TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    revoked_at  INTEGER,
    CHECK ((revoked_at IS NULL) = (public_key IS NOT NULL))
) STRICT;

-- One active device per user in this spec.
CREATE UNIQUE INDEX devices_one_active ON devices (user_id) WHERE revoked_at IS NULL;

CREATE TABLE device_state (
    device_id      TEXT PRIMARY KEY REFERENCES devices (id) ON DELETE CASCADE,
    online         INTEGER NOT NULL,
    connected_at   INTEGER,
    last_seen_at   INTEGER,
    offline_reason TEXT NOT NULL DEFAULT '',
    state_json     TEXT,
    tools_json     TEXT
) STRICT;

-- Metadata only: no arguments, no results (FR-022, FR-023).
CREATE TABLE audit_log (
    id          INTEGER PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id   TEXT REFERENCES devices (id) ON DELETE CASCADE,
    at          INTEGER NOT NULL,
    tool        TEXT NOT NULL,
    surface     TEXT NOT NULL DEFAULT '',
    outcome     TEXT NOT NULL CHECK (outcome IN ('ok', 'error', 'timeout', 'offline')),
    duration_ms INTEGER NOT NULL
) STRICT;

CREATE INDEX audit_log_at ON audit_log (at);
CREATE INDEX audit_log_user_at ON audit_log (user_id, at);

-- +goose Down
DROP TABLE audit_log;
DROP TABLE device_state;
DROP TABLE devices;
DROP TABLE users;
