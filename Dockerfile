ARG ENVOY_VERSION=v1.39-latest
ARG LIBRARY_IMAGE=waf-library:v1.39-latest

FROM ${LIBRARY_IMAGE} AS library

##### Build the final image #####
FROM envoyproxy/envoy:${ENVOY_VERSION} AS envoy
ENV ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/usr/local/lib
# The Go SDK returns raw Go heap pointers to Envoy as opaque module handles
# (sdk/go/abi manager.record); cgo's result check rejects those.
ENV GODEBUG=cgocheck=0
COPY --from=library /libcoraza_waf.so /usr/local/lib/libcoraza_waf.so
COPY config/envoy.yaml /etc/envoy/envoy.yaml
