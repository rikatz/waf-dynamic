.PHONY: build
build: ## Build the Go dynamic module.
	go build -buildmode=c-shared -o build/libcoraza_waf.so ./main.go