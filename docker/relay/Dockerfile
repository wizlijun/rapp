# Build from the repo root: docker build -f docker/relay/Dockerfile .   (see scripts/build-relay-image.sh)
# Only rust/ goes into the build context (Dockerfile.dockerignore).

# The build stage runs on the build machine's own architecture and cross-compiles to the target one
# (clang + lld, static musl), so a multi-arch build never runs rustc or cc under QEMU: emulated cc
# used to SIGSEGV on ring's x86_64 assembly, and emulated builds took half an hour.
FROM --platform=$BUILDPLATFORM rust:1.99.1-alpine3.23 AS build
ARG TARGETARCH
RUN apk add --no-cache musl-dev clang lld
RUN case "$TARGETARCH" in \
      amd64) t=x86_64-unknown-linux-musl ;; \
      arm64) t=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac && echo "$t" > /target && rustup target add "$t"
COPY rust/ /src/rust/
WORKDIR /src/rust
# The whole workspace has to be present for cargo to resolve it; only rapp-relay is compiled.
RUN t=$(cat /target) && u=$(echo "$t" | tr - _) && U=$(echo "$u" | tr a-z A-Z) && \
    env "CC_$u=clang" "CFLAGS_$u=--target=$t" \
        "CARGO_TARGET_${U}_LINKER=clang" \
        "CARGO_TARGET_${U}_RUSTFLAGS=-C link-arg=--target=$t -C link-arg=-fuse-ld=lld" \
      cargo build --profile relay -p rapp-relay --locked --target "$t" && \
    cp "target/$t/relay/rapp-relay" /rapp-relay

FROM alpine:3.23.8@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2
LABEL org.opencontainers.image.source="https://github.com/wizlijun/rapp" \
      org.opencontainers.image.description="rapp relay: device-key auth, ciphertext-only relaying"
COPY --from=build /rapp-relay /usr/local/bin/rapp-relay
# Owned by the runtime user, or a fresh named volume could not be written.
RUN mkdir -m 0700 /data && chown 10001:10001 /data
USER 10001:10001
VOLUME /data
EXPOSE 22026/udp
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["rapp-relay", "check"]
ENTRYPOINT ["rapp-relay"]
