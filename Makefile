APP := build/Glimpse.app

.PHONY: app debug run install icon clean

## Build a release app bundle (universal binary) into build/Glimpse.app
app:
	./scripts/build-app.sh release

## Build a debug app bundle
debug:
	./scripts/build-app.sh debug

## Build a debug bundle and open it. Pass an image or a folder with OPEN=path
run: debug
	open -n $(APP) $(if $(OPEN),--args "$(abspath $(OPEN))",)

## Copy the release app into /Applications
install: app
	rm -rf /Applications/Glimpse.app
	cp -R $(APP) /Applications/Glimpse.app
	@echo "Installed /Applications/Glimpse.app"

## Render Resources/AppIcon.icns
icon:
	./scripts/make-icon.sh

clean:
	swift package clean
	rm -rf build
