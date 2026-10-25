package store

import (
	"context"
	"database/sql"
)

// DeleteClientsExcept deletes every OAuth client keep refuses, together with all its codes and
// tokens, in one transaction, and returns how many clients went. Codes and tokens whose client
// row is already gone are offered to keep as a client with only an ID.
func (s *Store) DeleteClientsExcept(ctx context.Context, keep func(OAuthClient) bool) (int, error) {
	removed := 0
	err := s.immediate(ctx, func(conn *sql.Conn) error {
		rows, err := conn.QueryContext(ctx, `
			SELECT id, kind, metadata_json FROM oauth_clients
			UNION ALL
			SELECT DISTINCT client_id, '', '' FROM oauth_requests
			WHERE client_id NOT IN (SELECT id FROM oauth_clients)`)
		if err != nil {
			return err
		}
		var refused []string
		for rows.Next() {
			var c OAuthClient
			var meta string
			if err := rows.Scan(&c.ID, &c.Kind, &meta); err != nil {
				_ = rows.Close()
				return err
			}
			c.MetadataJSON = []byte(meta)
			if !keep(c) {
				refused = append(refused, c.ID)
			}
		}
		if err := rows.Close(); err != nil {
			return err
		}
		if err := rows.Err(); err != nil {
			return err
		}
		for _, id := range refused {
			if _, err := conn.ExecContext(ctx, `DELETE FROM oauth_requests WHERE client_id = ?`, id); err != nil {
				return err
			}
			if _, err := conn.ExecContext(ctx, `DELETE FROM oauth_clients WHERE id = ?`, id); err != nil {
				return err
			}
		}
		removed = len(refused)
		return nil
	})
	if err != nil {
		return 0, err
	}
	return removed, nil
}
