FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends emacs-nox git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /agent
COPY entrypoint.sh /agent/entrypoint.sh
RUN chmod +x /agent/entrypoint.sh

ENTRYPOINT ["/agent/entrypoint.sh"]
