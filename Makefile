ENVOY_VERSION ?= v1.39-latest
IMG ?= waf-dynamic:$(ENVOY_VERSION)

ENVOY_REPO := https://github.com/envoyproxy/envoy.git

.PHONY: build
build: ## Build the Go dynamic module.
	go build -buildmode=c-shared -o build/libcoraza_waf.so ./main.go

.PHONY: build-docker
build-docker: ## Build the image against ENVOY_VERSION, pinning the SDK to match.
	@REF=$$(echo "$(ENVOY_VERSION)" | sed -nE 's,^(v[0-9]+\.[0-9]+).*,refs/heads/release/\1,p'); \
	REF=$${REF:-refs/heads/main}; \
	SHA=$$(git ls-remote $(ENVOY_REPO) "$$REF" | cut -f1); \
	test -n "$$SHA" || { echo "no Envoy ref $$REF for ENVOY_VERSION=$(ENVOY_VERSION)" >&2; exit 1; }; \
	echo "Envoy $(ENVOY_VERSION): SDK from $$REF ($$SHA)"; \
	docker build --build-arg ENVOY_VERSION=$(ENVOY_VERSION) --build-arg SDK_VERSION=$$SHA -t $(IMG) .
