-- Wrong emailed codes per address per day (FR-042a, security scan 2026-10-24): after 20 wrong
-- codes within a day of the first, every emailed code is refused until that day is over. New
-- codes don't reset the count.

-- +goose Up
ALTER TABLE users ADD COLUMN wrong_codes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN wrong_codes_since INTEGER;

-- +goose Down
ALTER TABLE users DROP COLUMN wrong_codes_since;
ALTER TABLE users DROP COLUMN wrong_codes;
