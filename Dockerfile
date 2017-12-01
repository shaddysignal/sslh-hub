FROM alpine:3.6
MAINTAINER Anon <someone@shaddy.space>

ENV LISTEN_IP 0.0.0.0
ENV LISTEN_PORT 443
ENV SSH_HOST localhost
ENV SSH_PORT 22
ENV OPENVPN_HOST localhost
ENV OPENVPN_PORT 1194
ENV HTTPS_HOST localhost
ENV HTTPS_PORT 8443
ENV SHADOWSOCKS_HOST localhost
ENV SHADOWSOCKS_PORT 8388

RUN apk update && \
       apk add --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ sslh && \
       rm -rf /var/cache/apk/*

CMD sslh -f -u root --listen $LISTEN_IP:$LISTEN_PORT --ssh $SSH_HOST:$SSH_PORT --ssl $HTTPS_HOST:$HTTPS_PORT --openvpn $OPENVPN_HOST:$OPENVPN_PORT --anyprot $SHADOWSOCKS_HOST:$SHADOWSOCKS_PORT
