#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then echo 'Usage: bash sign-vault.sh /path/vault.csr' >&2; exit 2; fi
CSR=$(realpath "$1")
cd /home/vagrant/lab/keycloak
openssl req -in "$CSR" -noout -verify -subject
cat >pki/vault.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
openssl x509 -req -in "$CSR" -CA pki/ca.crt -CAkey pki/ca.key \
  -CAcreateserial -days 365 -sha256 -extfile pki/vault.ext -out pki/vault.crt
openssl verify -CAfile pki/ca.crt pki/vault.crt
base64 -w0 pki/vault.crt
printf '\n'
