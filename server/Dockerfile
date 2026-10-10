FROM rust:1.99-slim-bookworm AS builder
WORKDIR /app
COPY . .
RUN cargo build --locked --release --manifest-path server/Cargo.toml --target-dir /app/target

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/bw-cloud-server /usr/local/bin/bw-cloud-server
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bw-cloud-server"]
