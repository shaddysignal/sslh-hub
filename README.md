# sslh-hub

[![Docker Pulls](https://img.shields.io/docker/pulls/shaddysignal/sslh-hub.svg)](https://hub.docker.com/r/shaddysignal/sslh-hub/)
[![CI](https://github.com/shaddysignal/sslh-hub/actions/workflows/ci.yml/badge.svg)](https://github.com/shaddysignal/sslh-hub/actions/workflows/ci.yml)

[sslh](https://github.com/yrutschle/sslh) in a small Alpine Linux container.
sslh listens on one port, typically 443, looks at the first bytes of each
connection and forwards it to the right backend: SSH, TLS, OpenVPN, HTTP and
others. Configure it with a handful of environment variables, or mount a full
sslh configuration file.

- Alpine 3.24 with sslh 2.3.1 from Alpine's community repository, about 10 MB.
- Multi-arch: `linux/amd64`, `linux/arm64`, `linux/arm/v7`.
- Runs as `nobody`, works read-only, and needs only three capabilities.
- Never does reverse DNS on client addresses; per-connection logging can be
  switched off.
- Rebuilt weekly so Alpine security fixes reach the image, and scanned with
  Trivy before publishing.

Images: `shaddysignal/sslh-hub` on Docker Hub and `ghcr.io/shaddysignal/sslh-hub`.
Tags: `latest`, the sslh version such as `2.3.1`, and a dated build such as
`2.3.1-20261101` for pinning.

## Quick start

sslh forwards to *other* services, so it must be able to reach them. The
defaults point at `localhost`, which inside a container is the container
itself, so tell sslh where your backends are. Two common setups:

**Backends on the Docker host** (sshd on 22, a TLS server on 8443, OpenVPN on
1194): share the host's network, and `localhost` means the host.

```bash
docker run -d --name sslh --network host --restart unless-stopped \
  shaddysignal/sslh-hub
```

**Backends in other containers**: put everything on one network and use
container names.

```bash
docker network create edge
docker run -d --name sslh --network edge -p 443:443 --restart unless-stopped \
  -e SSH_HOST=openssh -e SSH_PORT=2222 \
  -e HTTPS_HOST=web -e HTTPS_PORT=443 \
  -e DEFAULT_HOST=web -e DEFAULT_PORT=443 \
  shaddysignal/sslh-hub
```

[examples/compose.yaml](examples/compose.yaml) shows the same with Docker
Compose, including the hardening options from the security section below.

## Configuration

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `LISTEN_IP` | `0.0.0.0` | Address to listen on. `[::]` listens on IPv6, and on IPv4 too on most hosts. |
| `LISTEN_PORT` | `443` | Port to listen on. |
| `SSH_HOST`, `SSH_PORT` | `localhost`, `22` | SSH backend. |
| `HTTPS_HOST`, `HTTPS_PORT` | `localhost`, `8443` | TLS backend: HTTPS or anything else wrapped in TLS. |
| `OPENVPN_HOST`, `OPENVPN_PORT` | `localhost`, `1194` | OpenVPN backend. |
| `HTTP_HOST`, `HTTP_PORT` | unset, `80` | Plain HTTP backend. Off until `HTTP_HOST` is set. |
| `DEFAULT_HOST`, `DEFAULT_PORT` | `localhost`, `8388` | Catch-all for connections nothing recognised. `SHADOWSOCKS_HOST` and `SHADOWSOCKS_PORT` are accepted as the older names. |
| `SSLH_TIMEOUT` | `2` | Seconds to wait for identifiable bytes before using the catch-all. |
| `SSLH_LOG_CONNECTIONS` | `1` | Log one line per connection with client and backend addresses. `0` logs none. |
| `SSLH_USER` | `nobody` | User sslh switches to after binding its port. Empty keeps whatever the config file says. |
| `SSLH_BIN` | `sslh-select` | `sslh-fork` runs one process per connection instead. |
| `SSLH_CONFIG` | unset | Path of a configuration file. A file at `/etc/sslh/sslh.cfg` is picked up automatically. |
| `CMD_OPTS` | empty | Extra sslh options, for example `--transparent` or `--wireguard vpn:51820`. |

Set any `*_HOST` to an empty string to disable that protocol. Options in
`CMD_OPTS`, and any arguments given after the image name, are placed before the
catch-all so protocols added there are probed. Run `docker run --rm
--entrypoint sslh-select shaddysignal/sslh-hub --help` for the full option list.

```bash
docker run -d -p 443:443 -e OPENVPN_HOST= -e CMD_OPTS="--http web:80" shaddysignal/sslh-hub
```

A startup line `Landlock: Failed to open /etc/ld.so.cache` is harmless: sslh's
Landlock sandbox pre-opens a glibc file that does not exist on Alpine.

### Configuration file

For anything beyond host and port pairs, such as routing by SNI or ALPN, regex
probes, UDP protocols like WireGuard, per-protocol log levels or re-resolving
backend names on every connection, mount an sslh configuration file:

```bash
docker run -d --name sslh -p 443:443 \
  -v "$PWD/sslh.cfg:/etc/sslh/sslh.cfg:ro" \
  shaddysignal/sslh-hub
```

[examples/sslh.cfg](examples/sslh.cfg) is a commented starting point and
upstream's [example.cfg](https://github.com/yrutschle/sslh/blob/master/example.cfg)
lists every option. In this mode the `*_HOST` and `*_PORT` variables are
ignored. The entrypoint still adds `-f` (foreground), `-n` (numeric logging)
and `-u $SSLH_USER`, which override the file; set `SSLH_USER` to an empty
string to let the file choose the user.

### Transparent proxying

Normally backends see every connection coming from sslh's own address. With
`--transparent`, sslh connects to the backend using the client's address, so
tools like fail2ban on the backend see the real source. This needs
`CAP_NET_ADMIN` and `CAP_NET_RAW`, the host network, and routing rules on the
host described in upstream's
[transparent proxy guide](https://github.com/yrutschle/sslh/blob/master/doc/tproxy.md).

```bash
docker run -d --name sslh --network host --cap-add NET_ADMIN --cap-add NET_RAW \
  -e CMD_OPTS=--transparent shaddysignal/sslh-hub
```

sslh keeps `CAP_NET_RAW` after switching to `nobody`, so running as root is
not required.

## Security and privacy

**Privileges.** The container starts as root only to bind port 443. sslh then
switches to `nobody` and ends up with no effective capabilities at all. The
recommended way to run it drops everything else up front:

```bash
docker run -d --name sslh -p 443:443 \
  --read-only --cap-drop ALL \
  --cap-add NET_BIND_SERVICE --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  shaddysignal/sslh-hub
```

To never be root at all, start the container as an unprivileged user and let
the kernel allow low ports inside its network namespace. This does not combine
with `--network host`, because the sysctl applies to the container's own
namespace.

```bash
docker run -d --name sslh -p 443:443 \
  --user 65534:65534 --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  shaddysignal/sslh-hub
```

**What sslh sees.** Only the first bytes of each connection, enough to
recognise the protocol. For TLS that includes the SNI hostname, which is sent
unencrypted by every client. sslh does not terminate TLS and never holds your
keys. Unrecognised traffic is forwarded unchanged to the catch-all after the
timeout.

**Logging.** By default every connection produces one log line with the client
address and port and the chosen backend. That is personal data: set
`SSLH_LOG_CONNECTIONS=0` to stop recording it, and give the container a Docker
logging driver with the retention you want.

**DNS.** Client addresses are never resolved, so no reverse lookups carry
client IPs to a resolver. Backend hostnames are resolved once at startup. If a
backend container restarts with a new address, sslh keeps using the old one;
use a configuration file and set `resolve_on_forward: true` on the affected
protocols for such setups.

**Source address.** Unless transparent mode is used, backends see sslh's
address, so per-IP rate limiting or banning has to happen in front of sslh or
in transparent mode.

**Image contents.** sslh, its three small libraries, BusyBox and apk. No
package cache, no shell history, no setuid binaries. The image is rebuilt from
`alpine:3.24` every week and the build fails on HIGH or CRITICAL findings that
have a fix. Pin a dated tag when you need reproducible deployments.

## Building and testing

```bash
docker build -t sslh-hub:test .
tests/smoke.sh sslh-hub:test
```

The smoke test starts throw-away backends on a private network and checks
protocol routing, the configuration-file mode, both hardened run modes and
clean shutdown. CI runs hadolint, shellcheck, actionlint, the smoke test and a
Trivy scan before publishing.

## Upgrading from the 2018 image

The image published until now was Alpine 3.6 with sslh 1.19c, running as
root. What changed:

- sslh runs as `nobody`. `SSLH_USER=root` restores the old behaviour.
- `sslh-select` replaces `sslh-fork`. `SSLH_BIN=sslh-fork` switches back.
- `--tls` replaces the `--ssl` alias. The behaviour is identical.
- `CMD_OPTS` and extra arguments now come before the catch-all, so protocols
  added through them are actually probed.
- `SHADOWSOCKS_HOST` and `SHADOWSOCKS_PORT` still work; `DEFAULT_HOST` and
  `DEFAULT_PORT` are the new names.
- `docker stop` stops sslh immediately instead of waiting for the kill timeout.

## Credits and license

sslh is written by Yves Rütschlé and released under the GPL. Thanks to the
amondit/sslh image for the original inspiration. This repository is released
under the [Unlicense](UNLICENSE).
