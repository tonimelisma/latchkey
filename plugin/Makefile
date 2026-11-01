# The Latchkey plugin for Claude (spec 011). Needs Claude Code (`claude`), jq, and git.
.PHONY: test lint measure

# Contract checks, their own tests, and Claude Code's validator on the plugin and the catalog.
test: lint
	tests/contract_test.sh

lint:
	claude plugin validate --strict .
	claude plugin validate --strict ..

# Eval cases with real Claude, with and without the plugin, on pretend Latchkey tools
# (plan D8). Real model calls on your account; the report stays in evals/results/.
MODEL ?= sonnet
RUNS ?= 3
CASE ?= *
measure:
	claude plugin eval . --trust-plugin --no-publish --model $(MODEL) --judge-model haiku \
		--runs $(RUNS) --case '$(CASE)' --threshold 0.66 --max-cost-usd 15 --concurrency 4
