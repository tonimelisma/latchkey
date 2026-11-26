.PHONY: project build test lint fmt run dmg install clean sandbox sandbox-stop evals

XCODEBUILD = xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -destination 'platform=macOS' -derivedDataPath build/DerivedData

# Generates Latchkey.xcodeproj from project.yml (never edit the .xcodeproj by hand).
project:
	../scripts/link-local-files.sh
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) build -quiet

test: project
	$(XCODEBUILD) test -quiet

lint:
	swift format lint --strict -r App Shared Helper Tests

fmt:
	swift format -i -r App Shared Helper Tests

# Builds and opens the app from build/.
run: build
	open build/DerivedData/Build/Products/Debug/Latchkey.app

# Builds the installable disk image: build/Latchkey-<version>.dmg (Release, signed).
dmg: project
	./scripts/package.sh

# Builds the disk image, installs it into /Applications, and starts it (every increment, CLAUDE.md).
# The version is the commit's release tag mac-<x.y.z>, made by CI (.github/workflows/mac-tag.yml);
# install.sh refuses a commit without it. Afterwards it sets up the updater (updater-setup.sh).
install: project
	./scripts/install.sh

# The sandbox Mac (spec 016 plan D3): the working tree's Release build, signed with the sandbox's
# own identity, installed in a Tart copy of the eval image and checked against the real Mac apps
# with test data (macos/scripts/sandbox.sh). The copy stays up for the next run until
# sandbox-stop. ARGS="--checks files,notes" runs some checks only.
sandbox:
	./scripts/sandbox.sh $(ARGS)

sandbox-stop:
	./scripts/sandbox.sh --stop

# Real Claude doing the eval tasks in a fresh copy (spec 016 plan D4): the working tree's build,
# or ARGS=--release for the newest release; ARGS=--send also sends the result.
evals:
	./scripts/evals.sh $(ARGS)

clean:
	rm -rf build Latchkey.xcodeproj
