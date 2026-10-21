#!/usr/bin/env bash
set -euo pipefail
UPLINK=$(ip -4 route show default | awk 'NR==1 {print $5}')
test -n "$UPLINK"
iptables -N DOCKER-USER 2>/dev/null || true
iptables -C FORWARD -j DOCKER-USER 2>/dev/null || iptables -I FORWARD 1 -j DOCKER-USER
for item in mgmt0:192.168.56.0/24 provider0:192.168.57.0/24; do
  LAN=${item%%:*}; CIDR=${item#*:}
  iptables -t nat -C POSTROUTING -s "$CIDR" -o "$UPLINK" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$CIDR" -o "$UPLINK" -j MASQUERADE
  iptables -C DOCKER-USER -i "$LAN" -o "$UPLINK" -s "$CIDR" -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 1 -i "$LAN" -o "$UPLINK" -s "$CIDR" -j ACCEPT
  iptables -C DOCKER-USER -i "$UPLINK" -o "$LAN" -d "$CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 1 -i "$UPLINK" -o "$LAN" -d "$CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
 done
