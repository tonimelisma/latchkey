module github.com/tonimelisma/latchkey/linux

go 1.26.0

replace github.com/tonimelisma/latchkey/relay => ../relay

require (
	github.com/coder/websocket v1.8.15
	github.com/creack/pty v1.1.24
	github.com/ledongthuc/pdf v0.0.0-20261020125853-5e46805f718e
	github.com/modelcontextprotocol/go-sdk v1.8.0
	github.com/stretchr/testify v1.12.1
	github.com/tonimelisma/latchkey/relay v0.0.0
	golang.org/x/image v0.47.0
)

require (
	github.com/google/jsonschema-go v0.4.3 // indirect
	github.com/segmentio/asm v1.2.1 // indirect
	github.com/segmentio/encoding v0.5.4 // indirect
	github.com/yosida95/uritemplate/v3 v3.0.2 // indirect
	go.yaml.in/yaml/v3 v3.0.5 // indirect
	golang.org/x/oauth2 v0.37.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/time v0.16.0 // indirect
)
