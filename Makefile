.PHONY: build app dmg install run clean

build:
	swift build

app dmg:
	./scripts/build-app.sh

# Build for this Mac only and install into /Applications.
install:
	ARCHS="$$(uname -m)" ./scripts/build-app.sh
	rm -rf /Applications/Snippy.app
	cp -R build/Snippy.app /Applications/
	open /Applications/Snippy.app

run: build
	.build/debug/Snippy

clean:
	rm -rf .build build
