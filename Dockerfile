# syntax=docker/dockerfile:1
FROM alpine:3.24

# sslh ships in Alpine's community repository. The release branch keeps one
# major.minor of sslh and only receives security rebuilds, so the package is
# deliberately not pinned to an -rN revision: a pinned revision disappears from
# the mirrors as soon as Alpine rebuilds it, which would break scheduled builds.
# hadolint ignore=DL3018
RUN apk add --no-cache sslh

COPY --chmod=755 entry.sh /usr/local/bin/entry.sh

LABEL org.opencontainers.image.title="sslh-hub" \
      org.opencontainers.image.description="sslh protocol multiplexer on Alpine Linux: SSH, TLS, OpenVPN, HTTP and more behind one port" \
      org.opencontainers.image.source="https://github.com/shaddysignal/sslh-hub" \
      org.opencontainers.image.licenses="Unlicense"

EXPOSE 443
ENTRYPOINT ["/usr/local/bin/entry.sh"]
