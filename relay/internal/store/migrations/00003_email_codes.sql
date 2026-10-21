-- One-time email codes replace email links (FR-042, FR-043): a code's hash is stored per user and
-- purpose, with a count of wrong attempts.

-- +goose Up
ALTER TABLE email_tokens ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
CREATE INDEX email_tokens_user_purpose ON email_tokens (user_id, purpose);

-- +goose Down
DROP INDEX email_tokens_user_purpose;
ALTER TABLE email_tokens DROP COLUMN attempts;
