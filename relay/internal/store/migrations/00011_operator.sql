-- Tools for the person running the relay (FR-195 to FR-199, Toni 2026-10-25): suspended
-- accounts, blocked addresses, and a log of the operator's commands, which the running relay
-- also reads to close the connections of an account that was just suspended or deleted.

-- +goose Up
ALTER TABLE users ADD COLUMN suspended_at INTEGER;
ALTER TABLE users ADD COLUMN suspended_reason TEXT NOT NULL DEFAULT '';

CREATE TABLE blocked_emails (
    email      TEXT PRIMARY KEY,
    blocked_at INTEGER NOT NULL,
    reason     TEXT NOT NULL DEFAULT ''
) STRICT;

-- Not tied to users: an entry outlives the account it is about. Purged after a year.
CREATE TABLE operator_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    at        INTEGER NOT NULL,
    actor     TEXT NOT NULL,
    action    TEXT NOT NULL,
    email     TEXT NOT NULL,
    user_id   TEXT NOT NULL DEFAULT '',
    device_id TEXT NOT NULL DEFAULT '',
    detail    TEXT NOT NULL DEFAULT ''
) STRICT;
CREATE INDEX operator_log_at ON operator_log (at);

-- +goose Down
DROP INDEX operator_log_at;
DROP TABLE operator_log;
DROP TABLE blocked_emails;
ALTER TABLE users DROP COLUMN suspended_reason;
ALTER TABLE users DROP COLUMN suspended_at;
