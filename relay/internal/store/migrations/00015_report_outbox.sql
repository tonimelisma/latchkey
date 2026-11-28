-- Problem reports go to the developer's intake (spec 014, decided 2026-11-23): the relay keeps no
-- readable report. The old table (spec 001 FR-691 to FR-693: reports kept until the account was
-- deleted and copied to the Mac) goes with what it held. report_outbox holds a report sealed to
-- the developer's key only until the intake accepts it, at most 7 days (FR-1414).

-- +goose Up
DROP INDEX IF EXISTS feedback_user_waiting;
DROP TABLE IF EXISTS feedback;
CREATE TABLE report_outbox (
    id       TEXT PRIMARY KEY,
    user_id  TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created  INTEGER NOT NULL,
    sealed   BLOB NOT NULL,
    tries    INTEGER NOT NULL DEFAULT 0,
    next_try INTEGER NOT NULL
) STRICT;
CREATE INDEX report_outbox_due ON report_outbox (next_try);

-- +goose Down
DROP INDEX report_outbox_due;
DROP TABLE report_outbox;
CREATE TABLE feedback (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    at           INTEGER NOT NULL,
    sealed       BLOB NOT NULL,
    delivered_at INTEGER
) STRICT;
CREATE INDEX feedback_user_waiting ON feedback (user_id, at) WHERE delivered_at IS NULL;
