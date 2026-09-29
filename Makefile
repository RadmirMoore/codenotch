SHELL := /bin/bash
APP := build/Codenotch Local.app
SIGN_IDENTITY ?= -
SWIFT_FLAGS ?=
export SWIFT_FLAGS

.PHONY: build test verify install

build:
	swift build $(SWIFT_FLAGS) -c release --product CodenotchLocal
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp .build/release/CodenotchLocal "$(APP)/Contents/MacOS/CodenotchLocal"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	python3 Scripts/package-resources.py
	xcrun actool Sources/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist build/assets-info.plist
	cp LICENSE "$(APP)/Contents/Resources/LICENSE"
	codesign --force --options runtime --entitlements Resources/CodenotchLocal.entitlements --sign "$(SIGN_IDENTITY)" "$(APP)"
	$(MAKE) verify

test:
	swift test $(SWIFT_FLAGS)

verify:
	python3 Scripts/verify-security.py "$(APP)"

# Local, per-user install. Does not launch, change Keychain, or add login items.
install: build
	mkdir -p "$(HOME)/Applications"
	@if [ -e "$(HOME)/Applications/Codenotch Local.app" ]; then \
		echo "Existing installation left untouched. Quit it and replace it manually with the build output."; exit 1; \
	fi
	ditto "$(APP)" "$(HOME)/Applications/Codenotch Local.app"
