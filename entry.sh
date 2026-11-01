#!/bin/sh
# sslh-hub entrypoint.
#
# Two modes:
#   1. Configuration file: if SSLH_CONFIG is set, or a file is mounted at
#      /etc/sslh/sslh.cfg, sslh runs with that file (-F).
#   2. Environment variables (default): a command line is assembled from the
#      *_HOST/*_PORT variables documented in README.md. An unset variable gets
#      its default; an empty one disables that protocol.
#
# In both modes sslh runs in the foreground, logs addresses numerically (no
# reverse DNS lookups) and, when the container starts as root, drops to
# SSLH_USER right after binding its listening socket.
set -eu

: "${SSLH_BIN=sslh-select}"
: "${SSLH_USER=nobody}"
: "${SSLH_CONFIG=}"
: "${CMD_OPTS=}"

if [ -z "$SSLH_CONFIG" ] && [ -f /etc/sslh/sslh.cfg ]; then
    SSLH_CONFIG=/etc/sslh/sslh.cfg
fi

# Only root can switch user. When the container itself is started with
# --user, sslh keeps that identity and needs no -u.
drop_user=""
if [ "$(id -u)" -eq 0 ] && [ -n "$SSLH_USER" ]; then
    drop_user="$SSLH_USER"
fi

# POSIX sh has no arrays, so the command line is assembled in "$@" back to
# front: whatever is prepended last ends up first. "$@" starts out holding
# any extra arguments given after the image name on `docker run`.

if [ -n "$SSLH_CONFIG" ]; then
    # shellcheck disable=SC2086  # CMD_OPTS is deliberately word-split
    set -- -F "$SSLH_CONFIG" $CMD_OPTS "$@"
else
    : "${LISTEN_IP=0.0.0.0}"
    : "${LISTEN_PORT=443}"
    : "${SSH_HOST=localhost}"
    : "${SSH_PORT=22}"
    : "${HTTPS_HOST=localhost}"
    : "${HTTPS_PORT=8443}"
    : "${OPENVPN_HOST=localhost}"
    : "${OPENVPN_PORT=1194}"
    : "${HTTP_HOST=}"
    : "${HTTP_PORT=80}"
    # SHADOWSOCKS_* are the historical names of the catch-all target.
    : "${DEFAULT_HOST=${SHADOWSOCKS_HOST-localhost}}"
    : "${DEFAULT_PORT=${SHADOWSOCKS_PORT-8388}}"
    : "${SSLH_TIMEOUT=2}"
    : "${SSLH_LOG_CONNECTIONS=1}"

    # The catch-all accepts anything, so it must be probed last: after the
    # built-in protocols and after anything added through CMD_OPTS or extra
    # arguments.
    if [ -n "$DEFAULT_HOST" ]; then
        set -- "$@" --anyprot "$DEFAULT_HOST:$DEFAULT_PORT"
    fi
    # shellcheck disable=SC2086  # CMD_OPTS is deliberately word-split
    set -- $CMD_OPTS "$@"
    if [ -n "$HTTP_HOST" ]; then
        set -- --http "$HTTP_HOST:$HTTP_PORT" "$@"
    fi
    if [ -n "$OPENVPN_HOST" ]; then
        set -- --openvpn "$OPENVPN_HOST:$OPENVPN_PORT" "$@"
    fi
    if [ -n "$HTTPS_HOST" ]; then
        set -- --tls "$HTTPS_HOST:$HTTPS_PORT" "$@"
    fi
    if [ -n "$SSH_HOST" ]; then
        set -- --ssh "$SSH_HOST:$SSH_PORT" "$@"
    fi
    set -- --listen "$LISTEN_IP:$LISTEN_PORT" \
           --timeout "$SSLH_TIMEOUT" \
           --verbose-connections "$SSLH_LOG_CONNECTIONS" \
           "$@"
fi

if [ -n "$drop_user" ]; then
    set -- -u "$drop_user" "$@"
fi

exec "$SSLH_BIN" -f -n "$@"
