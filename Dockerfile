ARG ENVOY_VERSION=v1.39-latest


FROM golang:1.27.1 AS go_builder
# Build the Go library.
RUN mkdir /build
COPY ./ /build
WORKDIR /build
RUN	CGO_ENABLED=1 GOARCH=amd64 go build -buildmode=c-shared -o /build/libcoraza_waf.so ./main.go

##### Build the final image #####
FROM envoyproxy/envoy:${ENVOY_VERSION} AS envoy
ENV ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/usr/local/lib
# The Go SDK returns raw Go heap pointers to Envoy as opaque module handles
# (sdk/go/abi manager.record); cgo's result check rejects those.
ENV GODEBUG=cgocheck=0
COPY --from=go_builder /build/libcoraza_waf.so /usr/local/lib/libcoraza_waf.so
COPY config/envoy.yaml /etc/envoy/envoy.yaml