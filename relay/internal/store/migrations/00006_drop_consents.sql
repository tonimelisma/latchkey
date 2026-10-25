-- Consent is asked every time (FR-049a, Toni 2026-10-25): approvals are no longer remembered, so
-- the table that remembered them goes. The account page lists clients by their live tokens.

-- +goose Up
DROP TABLE oauth_consents;

-- +goose Down
CREATE TABLE oauth_consents (
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_id  TEXT NOT NULL,
    scopes     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, client_id)
) STRICT;
