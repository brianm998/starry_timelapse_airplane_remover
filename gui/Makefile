.PHONY: release local-release clean install local-install

release:
	time bash release.sh && say 'the release is done' || say 'the release has failed, come have a look at what is wrong'

local-release:
	time bash local_release.sh && say 'local release done' || say 'local release failed'

install:
	open .build/star_app_*.pkg

local-install:
	cp -rf .build/AdHoc/Star.app /Applications/Star.app

clean:
	rm -rf .build
