-- The relay's own signing keys are stored encrypted under a key kept in a separate file
-- (FR-186). format is the version of a stored value: 0 is the key itself, as written before
-- this migration; 1 is AES-256-GCM (a 12-byte nonce, then ciphertext and tag, with the row's
-- name as additional data). Rows with format 0 are converted by the relay on its next start
-- (store/sealed.go); SQL can't do it. Toni, 2026-10-25.

-- +goose Up
ALTER TABLE relay_keys ADD COLUMN format INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE relay_keys DROP COLUMN format;
