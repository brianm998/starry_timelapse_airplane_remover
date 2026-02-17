.PHONY: build release clean

# non-release build
build: 
	swift build

# release build
release: 
	swift build -c release && say 'the release is done' || say 'the release has failed, come have a look at what is wrong'

install: 
	cp .build/release/star /usr/local/bin

clean:
	rm -rf .build
