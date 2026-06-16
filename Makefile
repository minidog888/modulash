.PHONY: test lint clean

SHELL_SCRIPTS := $(shell find bin lib vendor -type f -name "*.sh")
lint:
	shellcheck $(SHELL_SCRIPTS)

test:
	bats tests/

clean:
	rm -rf tmp/

build:
	./bin/modulash build --force