# Agent protocol fixtures

Example messages for `../agent-protocol.md`, read by both the Go relay tests and the Swift app
tests so the two implementations agree.

- `valid/`: must decode, and re-encoding must give the same JSON (key order aside).
- `tolerated/`: must decode (unknown fields are ignored); not compared after re-encoding.
- `invalid/`: must be rejected as a protocol violation (close 4005).

Signatures and nonces here are placeholders, not real cryptographic values; signature tests
generate their own keys.
