.PHONY: build test test-short lint fmt run tidy claude-check mac-check

# Pinned and built with the installed Go, so every contributor lints the same way.
GOLANGCI_LINT = go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0

build:
	go build -o bin/relay ./cmd/relay

test:
	go test -race ./...

# Skips the headless-Chrome test.
test-short:
	go test -race -short ./...

# Real Claude Code against a private relay and the pretend Mac (needs Chrome and Claude Code).
claude-check:
	./scripts/claude-code-check.sh

# The Mac app's real connection code against a private relay on this Mac (needs Xcode and Chrome).
mac-check:
	cd ../macos && xcodegen generate --quiet
	go run ./cmd/maccheck

lint:
	$(GOLANGCI_LINT) run

fmt:
	$(GOLANGCI_LINT) fmt

tidy:
	go mod tidy

# Local run with development defaults; override any variable on the command line.
run: export PUBLIC_URL ?= http://localhost:8080
run: export DATA_DIR ?= $(CURDIR)/.data
run: export SMTP_HOST ?= localhost
run: export SMTP_PORT ?= 1025
run: export SMTP_FROM ?= Latchkey <dev@localhost>
run:
	mkdir -p "$(DATA_DIR)"
	go run ./cmd/relay
