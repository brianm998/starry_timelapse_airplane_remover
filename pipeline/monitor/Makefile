# The pipeline monitor (plans/PIPELINE.md §13). Run from this directory or with `make -C pipeline/monitor`.
# Builds StarPipeMonitor.app: native notifications need a real bundle, so `make run` opens the .app, not the raw binary.
APP := StarPipeMonitor.app
BIN := .build/release/StarPipeMonitor
ID  := com.brianm998.starpipe.monitor
# The commit this build was made from; the app asks the daemon whether develop has newer monitor code.
SHA := $(shell git rev-parse HEAD)

.PHONY: build test app run clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/StarPipeMonitor
	sed -e 's/@ID@/$(ID)/' -e 's/@SHA@/$(SHA)/' Info.plist.in > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build $(APP)
