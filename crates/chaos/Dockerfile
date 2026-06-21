FROM rust:1.91-slim as builder

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN cargo build --release --bin chaos-agent

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/chaos-agent /usr/local/bin/

ENTRYPOINT ["chaos-agent"]
