-- One row per approval on the Allow page (FR-190 to FR-192, Toni 2026-10-25): the grant's public
-- ID, what the consent page showed, and when it was approved and last used. request_id is
-- fosite's request ID, shared by the grant's rows in oauth_requests.

-- +goose Up
CREATE TABLE oauth_grants (
    request_id   TEXT PRIMARY KEY,
    id           TEXT NOT NULL UNIQUE,
    user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_id    TEXT NOT NULL,
    client_name  TEXT NOT NULL DEFAULT '',
    client_host  TEXT NOT NULL DEFAULT '',
    redirect     TEXT NOT NULL DEFAULT '',
    approved_at  INTEGER NOT NULL,
    last_used_at INTEGER
) STRICT;
CREATE INDEX oauth_grants_user ON oauth_grants (user_id);

-- Grants from before this table: a row each, with an empty label (the list then names them from
-- their client) and the time of their oldest token as the approval time.
INSERT INTO oauth_grants (request_id, id, user_id, client_id, approved_at)
SELECT request_id, 'grt_' || lower(hex(randomblob(16))), MIN(user_id), MIN(client_id), MIN(requested_at)
FROM oauth_requests
WHERE kind IN ('access', 'refresh') AND user_id IS NOT NULL
GROUP BY request_id;

-- +goose Down
DROP INDEX oauth_grants_user;
DROP TABLE oauth_grants;
