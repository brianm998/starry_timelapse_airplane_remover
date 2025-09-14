.PHONY: release clean install

release: 
	time bash release.sh && say 'the release is done' || say 'the release has failed, come have a look at what is wrong'

install: 
	open .build/star_app_*.pkg

clean:
	rm -rf .build
