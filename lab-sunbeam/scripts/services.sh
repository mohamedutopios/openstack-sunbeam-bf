#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl dnsmasq iptables python3
cat >/etc/netplan/60-lab.yaml <<'EOF'
network:
  version: 2
  ethernets:
    mgmt0:
      match: {macaddress: '08:00:27:56:00:20'}
      set-name: mgmt0
      addresses: [192.168.56.20/24]
      dhcp4: false
    provider0:
      match: {macaddress: '08:00:27:57:00:02'}
      set-name: provider0
      addresses: [192.168.57.2/24]
      dhcp4: false
EOF
chmod 600 /etc/netplan/60-lab.yaml
netplan apply
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
ARCH=$(dpkg --print-architecture)
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker vagrant
systemctl enable --now docker
cat >/etc/dnsmasq.d/lab.conf <<'EOF'
interface=mgmt0
interface=provider0
bind-dynamic
no-resolv
server=1.1.1.1
server=9.9.9.9
address=/sso.lab.test/192.168.56.20
address=/cloud.lab.test/192.168.56.201
address=/internal.lab.test/192.168.56.202
address=/rgw.lab.test/192.168.56.203
EOF
systemctl restart dnsmasq
printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/70-lab-router.conf
sysctl --system >/dev/null
install -m 0755 /home/vagrant/lab/scripts/router.sh /usr/local/sbin/lab-router
mkdir -p /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/lab-router.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/lab-router
EOF
systemctl daemon-reload
/usr/local/sbin/lab-router
chown -R vagrant:vagrant /home/vagrant/lab
