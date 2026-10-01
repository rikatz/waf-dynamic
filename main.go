package main

import (
	// Linked in for its //export'ed ABI symbols (envoy_dynamic_module_on_program_init etc.).
	_ "github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go/abi"

	sdk "github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go"
	waf "github.com/tetratelabs/built-on-envoy/extensions/composer/waf"
)

func main() {}

func init() {
	sdk.RegisterHttpFilterConfigFactories(waf.WellKnownHttpFilterConfigFactories()) // nolint:revive
}
