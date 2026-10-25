-- Looking up whether a client has any code or token left (the purge of unused registered
-- clients and of cached client documents, and the cache's cap) scanned the whole table per
-- client. Security review, 2026-10-25.

-- +goose Up
CREATE INDEX oauth_requests_client ON oauth_requests (client_id);

-- +goose Down
DROP INDEX oauth_requests_client;
