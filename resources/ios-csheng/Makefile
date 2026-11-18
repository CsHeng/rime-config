SHELL := /bin/bash

JSONNET ?= jsonnet
SKIN_NAME := ios-csheng

.PHONY: all build pack clean

all: build

pack: all
	@rm -f ../$(SKIN_NAME).cskin
	@rm -rf /tmp/$(SKIN_NAME)
	@mkdir -p /tmp/$(SKIN_NAME)
	@cp -r config.yaml demo.png light dark jsonnet README.md /tmp/$(SKIN_NAME)/
	@cd /tmp && zip -r $(SKIN_NAME).cskin $(SKIN_NAME) -x "*.DS_Store"
	@mv /tmp/$(SKIN_NAME).cskin ../
	@rm -rf /tmp/$(SKIN_NAME)
	@echo "Created ../$(SKIN_NAME).cskin"

build:
	$(JSONNET) -S -m . jsonnet/main.jsonnet > /dev/null

clean:
	rm -f config.yaml \
		light/pinyinPortrait.yaml dark/pinyinPortrait.yaml \
		light/pinyinLandscape.yaml dark/pinyinLandscape.yaml \
		light/portraitNumeric.yaml dark/portraitNumeric.yaml \
		light/landscapeNumeric.yaml dark/landscapeNumeric.yaml \
		light/panel_portrait.yaml dark/panel_portrait.yaml \
		light/panel_landscape.yaml dark/panel_landscape.yaml
