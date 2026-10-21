#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cpu-checker jq python3-venv python3-yaml openssl curl dnsutils
cat >/etc/netplan/60-lab.yaml <<'EOF'
network:
  version: 2
  ethernets:
    mgmt0:
      match: {macaddress: '08:00:27:56:00:10'}
      set-name: mgmt0
      addresses: [192.168.56.10/24]
      dhcp4: false
      nameservers:
        addresses: [192.168.56.20]
        search: [lab.test]
    provider0:
      match: {macaddress: '08:00:27:57:00:10'}
      set-name: provider0
      dhcp4: false
      dhcp6: false
      link-local: []
      optional: true
EOF
chmod 600 /etc/netplan/60-lab.yaml
netplan apply
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/lab.conf <<'EOF'
[Resolve]
DNS=192.168.56.20
Domains=~lab.test
EOF
systemctl restart systemd-resolved
# Entries aid bootstrap; Kubernetes DNS is checked separately in the guide.
if ! grep -q '# BEGIN SUNBEAM LAB' /etc/hosts; then
cat >>/etc/hosts <<'EOF'
# BEGIN SUNBEAM LAB
192.168.56.10 sunbeam
192.168.56.20 sso.lab.test
192.168.56.201 cloud.lab.test
192.168.56.202 internal.lab.test
192.168.56.203 rgw.lab.test
# END SUNBEAM LAB
EOF
fi
chown -R vagrant:vagrant /home/vagrant/lab
