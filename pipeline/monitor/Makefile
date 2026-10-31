# The pipeline monitor (plans/PIPELINE.md §13). Run from this directory or with `make -C pipeline/monitor`.
# Builds StarPipeMonitor.app: native notifications need a real bundle, so `make run` opens the .app, not the raw binary.
APP := StarPipeMonitor.app
BIN := .build/release/StarPipeMonitor
ID  := com.brianm998.starpipe.monitor

.PHONY: build test app run clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/StarPipeMonitor
	sed 's/@ID@/$(ID)/' Info.plist.in > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build $(APP)
