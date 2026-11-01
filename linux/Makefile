# Latchkey's server program for Linux (spec 010). Run in linux/.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
GOLANGCI := github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0
VERSION := $(shell cat VERSION)

.PHONY: test test-linux lint fmt build release check

## test: the tests that run anywhere (the Linux-only ones skip themselves)
test:
	go test -race -count=1 ./...

## test-linux: every test, on Debian with systemd in a container (needs Docker)
test-linux:
	sh test/run-tests.sh

## lint: golangci-lint with gofumpt, 0 issues
lint:
	go run $(GOLANGCI) run

fmt:
	go run $(GOLANGCI) fmt

## build: the program for both architectures, in build/
build:
	mkdir -p build
	for arch in amd64 arm64; do \
	  CGO_ENABLED=0 GOOS=linux GOARCH=$$arch go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" \
	    -o build/latchkey-linux-$$arch ./cmd/latchkey; \
	done

## release: build, sign, and publish server-v$(VERSION) on GitHub (needs SERVER_SIGNING_KEY in ../.env)
release:
	sh scripts/release.sh

## check: the end-to-end check: a private relay, a pretend Mac, and this program in a Debian
## container installed with install.sh, driven by a real MCP client
check:
	cd ../relay && go run ./cmd/linuxcheck -docker
