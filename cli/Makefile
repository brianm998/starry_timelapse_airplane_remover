.PHONY: build release clean

# non-release build
build: 
	swift build

# release build
release: 
	swift build -c release && say 'the release is done' || say 'the release has failed, come have a look at what is wrong'

# star finds its localization tables at <exe dir>/../share/star (StarResources.swift); without them
# it prints message keys instead of text anywhere the build directory has since been deleted.
install: 
	cp .build/release/star /usr/local/bin
	mkdir -p /usr/local/share/star
	rm -rf /usr/local/share/star/StarCore_StarCore.resources
	cp -R ../StarCore/Sources/StarCore/Resources /usr/local/share/star/StarCore_StarCore.resources

clean:
	rm -rf .build
