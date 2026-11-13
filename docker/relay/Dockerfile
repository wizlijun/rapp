# Build from the repo root: docker build -f docker/relay/Dockerfile .   (see scripts/build-relay-image.sh)
# Only rust/ goes into the build context (Dockerfile.dockerignore).

FROM rust:1.99.1-alpine3.23 AS build
RUN apk add --no-cache musl-dev
COPY rust/ /src/rust/
WORKDIR /src/rust
# The whole workspace has to be present for cargo to resolve it; only rapp-relay2 is compiled.
RUN cargo build --profile relay -p rapp-relay2 --locked

FROM alpine:3.23.8@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2
LABEL org.opencontainers.image.source="https://github.com/wizlijun/rapp" \
      org.opencontainers.image.description="rapp relay: device-key auth, ciphertext-only relaying"
COPY --from=build /src/rust/target/relay/rapp-relay2 /usr/local/bin/rapp-relay
# Owned by the runtime user, or a fresh named volume could not be written.
RUN mkdir -m 0700 /data && chown 10001:10001 /data
USER 10001:10001
VOLUME /data
EXPOSE 21116/udp
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["rapp-relay", "check"]
ENTRYPOINT ["rapp-relay"]
