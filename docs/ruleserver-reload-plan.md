# Dynamic module RuleServer reload plan

## Goal

Add periodic RuleServer polling to the native Go Envoy dynamic module so updated Coraza rules can be activated without restarting Envoy or changing its filter configuration. Keep the existing local directives as a known-good startup ruleset and retain the last valid WAF if an update cannot be loaded.

This plan changes the native WAF integration. It does not require changes to Envoy, the Envoy Go SDK, or Coraza core.

## Current implementation

This repository is a thin dynamic-module wrapper. [`main.go`](../main.go) registers the WAF factories from `github.com/tetratelabs/built-on-envoy/extensions/composer/waf`.

The Composer implementation is in `extensions/composer/waf/waf.go` in the Built on Envoy repository. Its `wafPluginFactory` stores a `*SharedWAF`; `Create` copies that pointer into each stream filter. The WAF is built when the HTTP filter configuration is created. Composer's shared-WAF cache checks directives and included files when it is called again, but it does not watch files or replace the WAF used by existing factories. See [`waf.go`](https://github.com/tetratelabs/built-on-envoy/blob/v0.12.0/extensions/composer/waf/waf.go#L29-L119) and [`shared.go`](https://github.com/tetratelabs/built-on-envoy/blob/v0.12.0/extensions/composer/waf/coraza/shared.go#L21-L65).

## What to fork

Fork the Built on Envoy repository and modify only its Composer WAF package, under `extensions/composer/waf/`. Prefer contributing the change upstream and consuming a released Composer version if that is feasible.

The Composer package types that need to participate in reload are private. A fork or upstream change is therefore the smallest way to preserve the existing WAF filter's request processing, metrics, and Envoy integration. Copying the complete WAF filter into this repository would duplicate that behavior.

Composer's module is `github.com/tetratelabs/built-on-envoy/extensions/composer`. Keep its existing module boundary and `go.mod`; Composer documents that embedded plugins must share the same module and dependency versions for Go runtime compatibility. Do not create a separate Go module for the WAF package.

Do not fork Envoy, the Envoy dynamic module SDK, or Coraza core. The current SDK provides the filter-factory lifecycle hook needed to own and stop a reload manager.

## Reload lifecycle and WAF ownership

In the Composer fork, modify `extensions/composer/waf/waf.go`:

1. Add a reload manager to `wafPluginFactory` alongside the current mode and metrics.
2. In `wafPluginConfigFactory.Create`, parse the existing local directives, build the initial WAF synchronously, then create and start the reload manager if RuleServer settings are present.
3. In `wafPluginFactory.Create`, load the currently published WAF generation and retain that generation in the new stream filter.
4. Implement `wafPluginFactory.OnDestroy` to cancel polling and wait for the poller to stop.

The Go SDK's `HttpFilterFactory` contract says implementations must be thread-safe and provides `OnDestroy` for cleanup, generally after the configuration is replaced and streams using the old factory have finished. See the [SDK factory interface](https://github.com/envoyproxy/envoy/blob/90594f45b3ed/source/extensions/dynamic_modules/sdk/go/shared/api.go#L179-L199).

Keep a single immutable WAF generation active at a time. Build new candidates away from request callbacks, and publish only after a complete successful build. Each stream holds the generation it obtained when created, so in-flight requests finish with that WAF while new streams use the replacement. Keep the old WAF alive until no stream references it; reuse or extend Composer's `SharedWAF` lifetime handling rather than closing an old WAF immediately after swapping the pointer.

Do not mutate a live Coraza WAF. Do not call Envoy SDK handles from the polling goroutine. Use an atomic pointer or equivalent thread-safe publication for the active generation.

## RuleServer client and bundle loading

Add a small client in the Composer fork's WAF package, for example `extensions/composer/waf/reloader.go`. Use Go's standard `net/http`, ticker, JSON, and atomic facilities. A filesystem watcher is not needed for server polling.

The client should:

1. Poll the RuleServer's latest-version endpoint, for example `/rules/{instance}/latest`.
2. Compare the returned UUID with the active generation's UUID.
3. If it changed, fetch `/rules/{instance}` for the complete ruleset bundle.
4. Validate HTTP status, response size, required fields, and that the returned bundle UUID matches the requested latest version.
5. Build a candidate Coraza WAF from the complete bundle.
6. Atomically publish the WAF and record its UUID only after construction succeeds.

The bundle should include the rules and any referenced data files needed to build the WAF. The current builder code is under `extensions/composer/waf/coraza/`, especially `config.go`, `directives_fs.go`, `recording_fs.go`, and `shared.go`. Extend that builder to accept the downloaded files as an `fs.FS` input while preserving the embedded Coraza/CRS files and existing WAF cleanup behavior.

Use one poll loop per configured filter factory for the first version. Prevent overlapping polls, bound HTTP timeouts and bundle size, and use bounded retry/backoff after errors. Retain the current WAF on network failures, authentication failures, invalid JSON, version mismatch, or Coraza build errors. Do not update the active UUID when a candidate fails.

The first version should reload only the filter-level default WAF. Composer also supports per-route WAF configurations through `CreatePerRoute`; dynamically reloading those would require a separate ownership and lifecycle model. Keep per-route configuration static unless it is an explicit requirement.

## Filter configuration

Update config parsing in the Composer WAF package and `extensions/composer/waf/config.schema.json`. The filter config is supplied as a protobuf `Struct`; this repo currently passes a `directives` array in that struct.

Add the minimum fields needed for RuleServer polling:

- RuleServer HTTPS URL.
- Ruleset instance ID.
- Poll interval.
- Token-file path.
- Request timeout and maximum ruleset bundle size, if these are operator-configurable rather than fixed safe defaults.

These field names are proposed; there is no RuleServer reload schema today. Keep the existing `directives` as the initial fallback ruleset. Treat a successfully fetched bundle as a complete replacement. If remote rules are meant to be merged with local rules, define the merge and ordering contract explicitly instead of concatenating directives implicitly.

Validate required values and supported URL schemes while creating the filter configuration. Require a usable initial local WAF in the first version so a RuleServer outage does not leave startup without rules.

## Service-account token mounting

There are currently no Kubernetes manifests in this repository. Add an example workload manifest, for example `deploy/kubernetes/envoy.yaml`, with the following:

- A dedicated ServiceAccount for the Envoy pod.
- An explicit projected `serviceAccountToken` volume.
- A custom `audience` configured to match what the RuleServer accepts.
- A bounded token lifetime, such as 3600 seconds subject to cluster policy.
- A read-only mount into the Envoy container, for example at `/var/run/secrets/coraza/token`.
- No `subPath` mount for the projected token.
- `automountServiceAccountToken: false` if the pod should not receive Kubernetes' default token mount in addition to the explicit projection.

Set the filter's token-file path to the mounted path. Reopen and read that file for each outbound poll request; projected tokens rotate, so caching the initial token would eventually result in authentication failures. Kubernetes documents projected token volumes and their audience and expiration behavior in its [projected volumes guide](https://kubernetes.io/docs/concepts/storage/projected-volumes/) and [service-account guide](https://kubernetes.io/docs/concepts/security/service-accounts/).

The RuleServer must validate the projected token's issuer, identity, and audience. A mounted service-account token is not automatically accepted by an arbitrary service. The Envoy ServiceAccount does not need Kubernetes API RBAC merely to present its token to the RuleServer; grant RBAC only if Envoy itself must call the Kubernetes API. Never put token contents in source control, Envoy configuration, Docker build arguments, or the image.

## Changes in this repository

| File | Planned change |
|---|---|
| [`go.mod`](../go.mod) | Point the Composer dependency at the upstream release or the pinned fork commit. Keep the Envoy SDK version compatible with the Envoy binary. |
| [`main.go`](../main.go) | Keep registering `WellKnownHttpFilterConfigFactories()` if the fork preserves that factory registration API. |
| [`config/envoy.yaml`](../config/envoy.yaml) | Add RuleServer URL, instance, polling interval, and token-file path to the filter configuration. |
| [`config/envoy-demo.yaml`](../config/envoy-demo.yaml) | Keep the existing mounted-file demo, or add `config/envoy-ruleserver-demo.yaml` for RuleServer mode. |
| [`Makefile`](../Makefile) | Keep `run-demo` as the local mounted-rule example. Add a separate RuleServer target only if a local RuleServer endpoint is available; accept a caller-supplied token-file path and do not create a credential fixture. |
| New `deploy/kubernetes/envoy.yaml` | Demonstrate the ServiceAccount, projected token volume, read-only mount, and matching filter configuration. |
| New `docs/ruleserver-reload.md` | Document the runtime configuration, RuleServer endpoints/bundle format, token audience, and update/failure behavior. |

No token-related change is needed in `Dockerfile` or `Dockerfile.library`; credentials are mounted at runtime. Preserve the existing SDK-to-Envoy version matching in the Docker build.

In the dynamic module config in `config/envoy.yaml` and the RuleServer demo config, set Envoy's `do_not_close` option to keep the Go shared library mapped for the Envoy process lifetime. The poller must still stop through `OnDestroy`; `do_not_close` prevents Envoy from calling `dlclose` when filter references disappear. See the [Envoy dynamic-module configuration](https://www.envoyproxy.io/docs/envoy/v1.39.1/api-v3/extensions/dynamic_modules/v3/dynamic_modules.proto).

## Networking constraint

This design uses Go's `net/http` from inside the dynamic module to connect directly to the RuleServer. That outbound request is not routed through an Envoy-managed cluster, so it will not inherit that cluster's routing, retries, or telemetry. Confirm direct egress and TLS trust are acceptable. If outbound calls must go through Envoy clusters, a separate fetcher can publish versioned rules to a mounted volume, but the native WAF adapter still needs to detect the new generation, build it, and atomically swap it; a sidecar that only writes files does not reload the active WAF.

## Completion criteria

- Envoy starts with and enforces its configured local WAF before a successful RuleServer poll.
- A changed remote UUID triggers a fetch and a candidate WAF build.
- New streams use a candidate only after the complete ruleset builds successfully; existing streams retain their current generation.
- Network, authentication, payload, and WAF-build failures preserve the last valid WAF.
- Token rotation is observed without restarting Envoy.
- Destroying the filter factory cancels the poller and prevents it from continuing after teardown.
- Logs or metrics expose the active ruleset version and update failures without exposing credentials.
