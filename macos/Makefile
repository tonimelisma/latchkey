.PHONY: project build test lint fmt run clean

XCODEBUILD = xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -destination 'platform=macOS' -derivedDataPath build/DerivedData

# Generates Latchkey.xcodeproj from project.yml (never edit the .xcodeproj by hand).
project:
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

clean:
	rm -rf build Latchkey.xcodeproj
