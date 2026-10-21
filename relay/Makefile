.PHONY: build test lint fmt run tidy

# Pinned and built with the installed Go, so every contributor lints the same way.
GOLANGCI_LINT = go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0

build:
	go build -o bin/relay ./cmd/relay

test:
	go test -race ./...

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
