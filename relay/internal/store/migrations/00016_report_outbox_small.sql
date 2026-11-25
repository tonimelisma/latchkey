-- A report's small version, for an intake that takes only 64 KB (spec 014 FR-1451, 2026-11-25):
-- sealed to the developer's key like the report itself; the relay can't open either.

-- +goose Up
ALTER TABLE report_outbox ADD COLUMN small BLOB;

-- +goose Down
ALTER TABLE report_outbox DROP COLUMN small;
