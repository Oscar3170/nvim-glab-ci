.PHONY: test format format-check

test:
	nvim --headless --clean -l tests/run.lua

format:
	stylua lua plugin tests

format-check:
	stylua --check lua plugin tests
