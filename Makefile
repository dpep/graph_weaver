.PHONY: check generate test tc integration docs

# full verify loop: regenerate, test, typecheck
check: generate test tc

# manual/one-off checks against real GraphQL APIs (network; GitHub needs
# `gh auth login` or GITHUB_TOKEN)
integration:
	INTEGRATION=1 bundle exec rspec spec/integration

generate:
	bundle exec ruby bin/generate

test:
	bundle exec rspec

tc:
	bundle exec srb tc

# preview what rubydoc.info will render
docs:
	bundle exec yard doc
	open doc/index.html
