#!/usr/bin/env bash
# Issues the certificate a test Postgres serves TLS with, and trusts the CA that
# signed it, so `ENVIO_PG_SSL_MODE=verify-full` has something to verify against.
#
#   scripts/pg-tls.sh <dir> [uid:gid]
#
# The certificate names `localhost` and nothing else. That is what lets a test
# tell a verified connection from an unverified one: the same server reached as
# 127.0.0.1 has to be refused.
set -euo pipefail

DIR=${1:?usage: pg-tls.sh <dir> [uid:gid]}
OWNER=${2:-}
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)

mkdir -p "$DIR"
cd "$DIR"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ca.key -out ca.crt -subj "/CN=Envio Test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes \
  -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -extfile san.ext 2>/dev/null

# Postgres refuses to start if its key is readable by anyone else.
chmod 600 server.key
chmod 644 server.crt
if [ -n "$OWNER" ]; then
  $SUDO chown "$OWNER" server.key server.crt
fi

$SUDO cp ca.crt /usr/local/share/ca-certificates/envio-test-ca.crt
$SUDO update-ca-certificates >/dev/null

echo "$DIR"
