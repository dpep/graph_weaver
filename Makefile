.PHONY: check generate test tc

# full verify loop: regenerate, test, typecheck
check: generate test tc

generate:
	bundle exec ruby bin/generate

test:
	bundle exec rspec

tc:
	bundle exec srb tc
