# TODO: track tooling and Make in the same derivation
.DEFAULT_GOAL := help

# Porcelain
# ###############
.PHONY: all run build lint test upload activate esure-dev-env env-dev-down env-dev-recreate env-dev-up env-container prerequisites-verify run-watch upstream sign

env-dev-up:  ## set up development environemnt, idempotent
	$(eval EXTENSION_FQN := $(shell yq < $(_ENTRYPOINT) '.name' | tr -d \"))
	$(eval DOCKER_NAME := $(shell (echo companion-$(EXTENSION_FQN) | tr  : -)))
	docker container inspect $(DOCKER_NAME) > /dev/null 2>&1 || (docker run --rm -v `pwd`/companion/snmp-data:/usr/local/snmpsim/data --name $(DOCKER_NAME) -d -p $(DOCKER_PORT):161/udp tandrup/snmpsim:v0.4 && sleep 3)

env-dev-down: ## tear down development environment
	$(eval EXTENSION_FQN := $(shell yq < $(_ENTRYPOINT) '.name' | tr -d \"))
	$(eval DOCKER_NAME := $(shell (echo companion-$(EXTENSION_FQN) | tr  : -)))
	docker rm -f $(DOCKER_NAME)

env-dev-recreate: env-dev-down env-dev-up ## recreate developmenet environment
	$(eval EXTENSION_FQN := $(shell yq < $(_ENTRYPOINT) '.name' | tr -d \"))
	$(eval DOCKER_NAME := $(shell (echo companion-$(EXTENSION_FQN) | tr  : -)))
	docker logs -f $(DOCKER_NAME)

env-container:  ## containerize the build environment
	nix build docker.image -f default.nix
	$(eval EXTENSION_FQN := $(shell yq < $(_ENTRYPOINT) '.name' | tr -d \"))
	docker load < result
	docker tag extension-env:builded $(EXTENSION_FQN)-build-env:latest

# this typo is deliberate, so that it doesn't show up when typing en[TAB]
esure-dev-env: env-dev-up

all: upload activate ## make it work on the tenant

build: extension.zip ## create artifact

sign: bundle.zip ## sign the artifact

lint: $(_ENTRYPOINT) ## run static analysis
	dt ext validate-schema --instance $(_ENTRYPOINT) --schema-entrypoint $(shell dirname $$(which __dt_cluster_schema))/../schemas/extension.schema.json

upload: secrets/tenant secrets/token bundle.zip ## upload the extension
	curl -X POST "https://$(RETREIVE_TENANT)/api/v2/extensions" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $(RETREIVE_API_TOKEN)" -H "Content-Type: multipart/form-data" -F "file=@bundle.zip;type=application/x-zip-compressed" --silent | jq

activate: secrets/tenant secrets/token ## upload the configuration/activation
	$(eval EXTENSION_FQN := $(shell yq < $(_ENTRYPOINT) '.name' | tr -d \"))
	$(eval EXTENSION_VERSION := $(shell yq < $(_ENTRYPOINT) '.version' | tr -d \"))
	curl -X POST "https://$(RETREIVE_TENANT)/api/v2/extensions/$(EXTENSION_FQN)/environmentConfiguration" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $(RETREIVE_API_TOKEN)" -H "Content-Type: application/json" -d "{\"version\":\"$(EXTENSION_VERSION)\"}" --silent | jq
	sleep 10 # wait for the environement configuration to propagate
	curl -X POST "https://$(RETREIVE_TENANT)/api/v2/extensions/$(EXTENSION_FQN)/monitoringConfigurations" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $(RETREIVE_API_TOKEN)" -H "Content-Type: application/json" -d @remote-activation.json --silent | jq

# Plumbing
# ###############
.PHONY: gitclean gitclean-with-libs raw-run common_clean

extension.zip: $(SOURCES)
	dt extension assemble --force

bundle.zip: extension.zip secrets/developer.pem
	# TODO: move this to default and remove
	dt extension sign --key secrets/developer.pem --force

secrets/tenant:
	# Please provide a tenant url
	# Format: URL *without* protocol
	# Example: lwp00649.dev.dynatracelabs.com
	./scripts/acquire-secret $@

secrets/token:
	# Please provide a Dynatrace API token, obtained via:
	# (goto tentant UI) -> Settings -> Integration -> DynatraceAPI -> Generate token ->
	# -> (set name, doesn't matter) -> (set permissions, see below) -> Generate
	# under APIv2 following permissions are required:
	# - Write extensions
	# - Write extension environment configuration
	# - Write extension monitoring configuration
	# Format:  dt0c01.XXXXXXXXXXXXXXXXXXXXXXXX.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
	# Example: dt0c01.XYNU6UOAF2BJYI2LYPDWVHQI.K4COMU6UOQMOR7IRGHMTEDGTDOQI4HKR4QJ2O34ALTM2EPTYUQMQNMAXZQ32NTDI
	./scripts/acquire-secret $@

secrets/developer.pem:
	# for details:
	# see https://www.dynatrace.com/support/help/extend-dynatrace/extensions20/sign-extension/	
	# or
	# possibly generate the keys in a known location and just symlink them here
	# in that case you should know what you're doing
	#
	# the pipeline will now fail - acquire the file and try again
	@false	

# TODO: fix this and push upstream
gitclean:
	@# will remove everything in .gitignore expect for blocks starting with dep* or lib* comment
	diff --new-line-format="" --unchanged-line-format="" <(grep -v '^#' .gitignore | grep '\S' | sort) <(awk '/^# *(dep|lib)/,/^$/' testowy | head -n -1 | tail -n +2 | sort) | xargs rm -rf

gitclean-with-libs:
	diff --new-line-format="" --unchanged-line-format="" <(grep -v '^#' .gitignore | grep '\S' | sort) | xargs rm -rf

# TODO: impelment for extension - does that even make sense?
common_clean:

.PHONY: help todo
help: ## print this message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | cut -d':' -f 2- | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

todo: ## list all TODOs in the project
	git grep -I --line-number TODO | grep -v 'list all TODOs in the project' | grep TODO
