-- Each time a Claude client is given access, so the Owner's Mac can say so once (best-practices
-- review, Toni 2026-10-23). Kept 30 days, like the audit log.

-- +goose Up
CREATE TABLE client_authorizations (
    id          INTEGER PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_name TEXT NOT NULL,
    at          INTEGER NOT NULL,
    notified_at INTEGER
) STRICT;
CREATE INDEX client_authorizations_pending ON client_authorizations (user_id, notified_at);

-- +goose Down
DROP INDEX client_authorizations_pending;
DROP TABLE client_authorizations;
