#!/bin/sh

sslh -f -u root --listen $LISTEN_IP:$LISTEN_PORT \
   --ssh $SSH_HOST:$SSH_PORT \
   --ssl $HTTPS_HOST:$HTTPS_PORT \
   --openvpn $OPENVPN_HOST:$OPENVPN_PORT \
   --anyprot $SHADOWSOCKS_HOST:$SHADOWSOCKS_PORT \
   $@
