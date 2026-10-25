.PHONY: build test test-short lint fmt run tidy tidy-check vuln secrets semgrep shellcheck deps security script-tests claude-check mac-check

# Pinned and built with the installed Go, so every contributor lints the same way.
GOLANGCI_LINT = go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0
GOVULNCHECK = go run golang.org/x/vuln/cmd/govulncheck@v1.9.0
GITLEAKS = go run github.com/zricethezav/gitleaks/v8@v8.30.1
SEMGREP = uvx --from semgrep==1.182.0 semgrep
OSV_SCANNER = go run github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.7.0
SHELLCHECK_IMAGE = koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

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

# Fails if go.mod or go.sum aren't tidy.
tidy-check:
	go mod tidy -diff

# Known vulnerabilities the relay's code can reach (Go itself and every module). Fails on any.
vuln:
	$(GOVULNCHECK) ./...

# Secrets committed anywhere in the repository's history, and this deployment's private values
# (relay host, DNS zone, VM, cloud project, Apple team ID: read from the gitignored .env and
# macos/Config/Local.xcconfig) in tracked files or history. Fails on any.
secrets:
	cd .. && scripts/private-values-check.sh
	cd .. && $(GITLEAKS) git --redact --no-banner .

# Static analysis of the Go relay and the Swift app: Semgrep's public Go, Swift, secrets, and
# Dockerfile rules (fetched from the registry at run time, so not pinned) plus Latchkey's own
# rules in scripts/semgrep/, whose tests run first. Fails on any finding; a reviewed safe line
# carries `nosemgrep: <rule id> -- <why>`.
semgrep:
	cd .. && $(SEMGREP) --test --metrics=off scripts/semgrep
	cd .. && $(SEMGREP) scan --metrics=off --error --quiet --config p/golang --config p/swift \
		--config p/secrets --config p/dockerfile --config scripts/semgrep/latchkey.yml \
		--exclude 'scripts/semgrep' --exclude 'CLAUDE-SECURITY-*' --exclude '.claude/worktrees'

# Every tracked shell script, at warning level and above (needs Docker).
shellcheck:
	cd .. && git ls-files -z '*.sh' | xargs -0 docker run --rm -v "$$PWD:/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) -S warning

# Known vulnerabilities in dependencies: the relay's Go modules (OSV database) and the Mac app's
# Sparkle. Fails on any.
deps:
	$(OSV_SCANNER) -L go.mod
	../scripts/sparkle-advisories.sh

# Tests of the deploy and repository scripts, in temporary folders: no server, no network.
script-tests:
	cd .. && deploy/tests/lib_test.sh
	cd .. && python3 -m unittest discover -q -s deploy/tests -p 'test_*.py'
	cd .. && scripts/tests/private_values_test.sh
	cd .. && scripts/tests/hooks_guard_test.sh
	cd .. && scripts/tests/tidy_test.sh
	cd .. && scripts/tests/loose_ends_test.sh
	cd .. && scripts/tests/install_pairing_test.sh

# Every security check; the deploy script and CI run it.
security: tidy-check vuln secrets semgrep shellcheck deps

# Local run with development defaults; override any variable on the command line.
run: export PUBLIC_URL ?= http://localhost:8080
run: export DATA_DIR ?= $(CURDIR)/.data
run: export SMTP_HOST ?= localhost
run: export SMTP_PORT ?= 1025
run: export SMTP_FROM ?= Latchkey <dev@localhost>
run:
	mkdir -p "$(DATA_DIR)"
	go run ./cmd/relay
