-- Claude's feedback reports (spec 001 FR-690 to FR-695, Toni 2026-11-16): kept until the account
-- is deleted. The text (client, machine, summary, details as JSON) is sealed under the relay's
-- key file, with the row's id as the additional data, so a copy of the database alone can't be
-- read. delivered_at is when a Mac said it saved the report; NULL until then.

-- +goose Up
CREATE TABLE feedback (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    at           INTEGER NOT NULL,
    sealed       BLOB NOT NULL,
    delivered_at INTEGER
) STRICT;
CREATE INDEX feedback_user_waiting ON feedback (user_id, at) WHERE delivered_at IS NULL;

-- +goose Down
DROP INDEX feedback_user_waiting;
DROP TABLE feedback;
