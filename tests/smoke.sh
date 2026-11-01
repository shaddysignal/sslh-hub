#!/bin/sh
# Smoke test for the sslh-hub image: starts throw-away backends on a private
# Docker network, pushes traffic through sslh and checks where it ends up.
#
#   tests/smoke.sh [IMAGE]        default IMAGE: sslh-hub:test
#
# Needs a working docker CLI. Every scenario is self-contained and the script
# cleans up after itself.
set -eu

IMAGE=${1:-sslh-hub:test}
ALPINE=${ALPINE_IMAGE:-alpine:3.24}
NET="sslh-smoke-$$"
SSLH="sslh-$$"
SSHB="sshb-$$"
TLSB="tlsb-$$"
CFG=$(mktemp)
failures=0

cleanup() {
    docker rm -f "$SSLH" "$SSHB" "$TLSB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -f "$CFG"
}
trap cleanup EXIT INT TERM

check() { # check DESCRIPTION COMMAND...
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $desc"
    else
        echo "  FAIL  $desc"
        failures=$((failures + 1))
    fi
}
contains()     { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }

# A banner server: answers every TCP connection with one fixed line.
backend() { # backend NAME PORT BANNER
    docker run -d --rm --name "$1" --network "$NET" "$ALPINE" sh -c \
        "while true; do (echo '$3'; sleep 2) | nc -l -p $2; done" >/dev/null
}

# Runs a shell snippet in a client container, sends its output to sslh on
# port 443 and prints whatever comes back.
client() { # client SNIPPET
    docker run --rm --network "$NET" "$ALPINE" sh -c \
        "($1; sleep 1) | nc -w 3 $SSLH 443"
}

# A minimal but valid TLS 1.2 ClientHello without extensions.
HELLO="printf '\\x16\\x03\\x01\\x00\\x2f\\x01\\x00\\x00\\x2b\\x03\\x03'; head -c 32 /dev/zero; printf '\\x00\\x00\\x02\\x00\\x2f\\x01\\x00\\x00\\x00'"

start_sslh() { # start_sslh DOCKER_RUN_ARGS...
    docker rm -f "$SSLH" >/dev/null 2>&1 || true
    docker run -d --rm --name "$SSLH" --network "$NET" "$@" "$IMAGE" >/dev/null
    # Wait for a LISTEN socket on port 443 (0x01BB) without connecting to it.
    i=0
    until docker exec "$SSLH" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q ":01BB [0-9A-F:]* 0A"'; do
        i=$((i + 1))
        if [ "$i" -ge 20 ]; then
            echo "  sslh did not start listening; logs:"; docker logs "$SSLH" 2>&1 | sed 's/^/    /'
            return 1
        fi
        sleep 0.5
    done
}
sslh_cmdline() { docker exec "$SSLH" sh -c "tr '\\0' ' ' </proc/1/cmdline"; }
sslh_user()    { docker exec "$SSLH" sh -c "ps -o pid,user | awk '\$1 == 1 { print \$2 }'"; }
sslh_capeff()  { docker exec "$SSLH" sh -c "awk '/^CapEff/ { print \$2 }' /proc/1/status"; }

docker network create "$NET" >/dev/null
backend "$SSHB" 2222 SSH-2.0-backend
backend "$TLSB" 8443 TLS-BACKEND
BACKENDS="-e SSH_HOST=$SSHB -e SSH_PORT=2222 -e HTTPS_HOST=$TLSB -e HTTPS_PORT=8443"

echo "# environment variable mode"
# shellcheck disable=SC2086  # BACKENDS is a list of docker options
start_sslh $BACKENDS -e CMD_OPTS="--http $TLSB:80"
cmd=$(sslh_cmdline)
check "sslh-select is PID 1"                  contains "$cmd" "sslh-select -f -n -u nobody"
check "runs as nobody"                        test "$(sslh_user)" = nobody
check "CMD_OPTS come before the catch-all"    contains "$cmd" "--http $TLSB:80 --anyprot localhost:8388"
check "SSH is routed to the SSH backend"      test "$(client "printf 'SSH-2.0-client\r\n'")" = SSH-2.0-backend
check "TLS is routed to the TLS backend"      test "$(client "$HELLO")" = TLS-BACKEND
start=$(date +%s); docker stop -t 8 "$SSLH" >/dev/null; elapsed=$(( $(date +%s) - start ))
check "stops promptly on SIGTERM (${elapsed}s)" test "$elapsed" -lt 8

echo "# disabled protocols and legacy names"
start_sslh -e HTTPS_HOST= -e OPENVPN_HOST= -e SHADOWSOCKS_HOST="$TLSB" -e SHADOWSOCKS_PORT=1
cmd=$(sslh_cmdline)
check "empty HTTPS_HOST removes --tls"        not_contains "$cmd" "--tls"
check "empty OPENVPN_HOST removes --openvpn"  not_contains "$cmd" "--openvpn"
check "SHADOWSOCKS_* still set the catch-all" contains "$cmd" "--anyprot $TLSB:1"

echo "# configuration file mode"
cat >"$CFG" <<CFGEOF
listen: ( { host: "0.0.0.0"; port: "443"; } );
protocols: (
    { name: "ssh"; host: "$SSHB"; port: "2222"; },
    { name: "tls"; host: "$TLSB"; port: "8443"; }
);
CFGEOF
start_sslh -v "$CFG:/etc/sslh/sslh.cfg:ro"
check "mounted file is used"                  contains "$(sslh_cmdline)" "-F /etc/sslh/sslh.cfg"
check "runs as nobody"                        test "$(sslh_user)" = nobody
check "SSH is routed (config file)"           test "$(client "printf 'SSH-2.0-client\r\n'")" = SSH-2.0-backend

echo "# hardened: read-only, minimal capabilities, no-new-privileges"
# shellcheck disable=SC2086
start_sslh $BACKENDS --read-only --cap-drop ALL \
    --cap-add NET_BIND_SERVICE --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges
check "runs as nobody"                        test "$(sslh_user)" = nobody
check "no effective capabilities remain"      test "$(sslh_capeff)" = 0000000000000000
check "SSH is routed (hardened)"              test "$(client "printf 'SSH-2.0-client\r\n'")" = SSH-2.0-backend

echo "# strict: container started as an unprivileged user"
# shellcheck disable=SC2086
start_sslh $BACKENDS --user 65534:65534 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --sysctl net.ipv4.ip_unprivileged_port_start=0
check "no -u when already unprivileged"       not_contains "$(sslh_cmdline)" " -u "
check "SSH is routed (strict)"                test "$(client "printf 'SSH-2.0-client\r\n'")" = SSH-2.0-backend

echo
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
