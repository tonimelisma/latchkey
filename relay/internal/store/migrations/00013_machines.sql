-- Several machines per account (spec 010 FR-1001): a Mac or a Linux server, any number of each.
-- The one-active-device rule goes; names stay unique among an account's active machines, which
-- the code enforces (a revoked row keeps the name it had).
-- device_pairings: headless pairing (spec 010 plan D7, RFC 8628's shape). The server asks for a
-- code with its name, kind, and public key; the Owner approves the short code in a signed-in
-- browser; the server collects its device ID once. Codes are stored hashed.

-- +goose Up
DROP INDEX devices_one_active;
ALTER TABLE devices ADD COLUMN kind TEXT NOT NULL DEFAULT 'mac';
CREATE INDEX devices_user_active ON devices (user_id) WHERE revoked_at IS NULL;

CREATE TABLE device_pairings (
    device_code_hash BLOB PRIMARY KEY,
    user_code_hash   BLOB NOT NULL UNIQUE,
    name             TEXT NOT NULL,
    kind             TEXT NOT NULL,
    public_key       BLOB NOT NULL,
    created_at       INTEGER NOT NULL,
    expires_at       INTEGER NOT NULL,
    polled_at        INTEGER,
    approved_by      TEXT REFERENCES users (id) ON DELETE CASCADE,
    device_id        TEXT REFERENCES devices (id) ON DELETE CASCADE,
    collected_at     INTEGER
) STRICT;
CREATE INDEX device_pairings_expires ON device_pairings (expires_at);

-- +goose Down
DROP TABLE device_pairings;
DROP INDEX devices_user_active;
ALTER TABLE devices DROP COLUMN kind;
CREATE UNIQUE INDEX devices_one_active ON devices (user_id) WHERE revoked_at IS NULL;
