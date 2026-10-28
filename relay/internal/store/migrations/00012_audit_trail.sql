-- The audit trail without gaps (FR-630 to FR-636, Toni 2026-10-27): every tool call's id, unique
-- for all time, so the Mac's log and the relay's audit can be compared; and the relay's record of
-- events (connections, sign-ins, approvals, pairings, refused requests). Both are kept until the
-- account is deleted; nothing is deleted by age.
-- Existing audit rows keep working: their call id is '' (from before call ids).

-- +goose Up
ALTER TABLE audit_log ADD COLUMN call_id TEXT NOT NULL DEFAULT '';
CREATE INDEX audit_log_device_at ON audit_log (device_id, at);

-- One row per event, or, for refused and failed requests, one row per hour, kind, account, and
-- reason with a count (hour set), so nobody can grow the table faster than its kinds allow.
-- user_id is NULL for events without an account (a stranger's request).
CREATE TABLE events (
    id        INTEGER PRIMARY KEY,
    at        INTEGER NOT NULL,
    kind      TEXT NOT NULL,
    user_id   TEXT REFERENCES users (id) ON DELETE CASCADE,
    device_id TEXT NOT NULL DEFAULT '',
    detail    TEXT NOT NULL DEFAULT '',
    hour      INTEGER,
    count     INTEGER NOT NULL DEFAULT 1,
    last_at   INTEGER NOT NULL
) STRICT;
CREATE INDEX events_user_at ON events (user_id, at);
CREATE INDEX events_at ON events (at);
CREATE INDEX events_hour ON events (hour, kind, detail) WHERE hour IS NOT NULL;

-- +goose Down
DROP INDEX events_hour;
DROP INDEX events_at;
DROP INDEX events_user_at;
DROP TABLE events;
DROP INDEX audit_log_device_at;
ALTER TABLE audit_log DROP COLUMN call_id;
