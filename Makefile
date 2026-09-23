.PHONY: build test app install uninstall snapshots clean

# With only the Command Line Tools installed, Swift Testing's macros need their plugin path.
TESTING_PLUGINS := $(shell d="$$(xcode-select -p)/usr/lib/swift/host/plugins/testing"; [ -d "$$d" ] && echo "-Xswiftc -plugin-path -Xswiftc $$d")

build:
	swift build

test:
	swift test $(TESTING_PLUGINS)

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

# Renders the popover with made-up data into docs/screenshots.
snapshots: build
	"$$(swift build --show-bin-path)/Claudon" --snapshot docs/screenshots --demo

clean:
	rm -rf .build build
