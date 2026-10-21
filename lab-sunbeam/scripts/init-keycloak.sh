#!/usr/bin/env bash
set -euo pipefail
cd /home/vagrant/lab/keycloak
umask 077
if [[ -e .env || -e pki/ca.key || -e tls/server.key ]]; then
  echo 'Already initialized. Do not overwrite keys or database passwords.' >&2; exit 1
fi
mkdir -p pki tls
printf 'POSTGRES_PASSWORD=%s\nKEYCLOAK_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" >.env
openssl req -x509 -newkey rsa:3072 -nodes -days 1825 \
  -keyout pki/ca.key -out pki/ca.crt -subj '/CN=Sunbeam Lab Root CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign'
openssl req -new -newkey rsa:2048 -nodes -keyout tls/server.key \
  -out pki/keycloak.csr -subj '/CN=sso.lab.test'
cat >pki/server.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:sso.lab.test,IP:192.168.56.20
EOF
openssl x509 -req -in pki/keycloak.csr -CA pki/ca.crt -CAkey pki/ca.key \
  -CAcreateserial -days 365 -sha256 -extfile pki/server.ext -out tls/server.crt
chmod 755 tls
chmod 644 tls/server.crt realm.json
sudo chown 1000:1000 tls/server.key
chmod 600 tls/server.key
sudo install -m 644 pki/ca.crt /usr/local/share/ca-certificates/sunbeam-lab.crt
sudo update-ca-certificates
install -m 644 pki/ca.crt /home/vagrant/lab/ca.crt
echo 'CA generated. Admin password is in .env (keep private).'
