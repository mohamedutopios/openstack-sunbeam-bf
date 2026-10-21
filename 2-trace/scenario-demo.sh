#!/usr/bin/env bash
# Scenario demo web pas a pas, avec un marqueur d'etape dans le traceur avant chaque etape.
# A lancer dans Lab-Sunbeam, compte vagrant :
#   bash ~/2-trace/scenario-demo.sh            deroule les etapes, Entree avant chacune
#   bash ~/2-trace/scenario-demo.sh nettoyer   supprime tout ce que le scenario a cree
# Prerequis : traceur demarre (bash ~/2-trace/start.sh) et cle publique copiee dans ~/web-key.pub.
# AUTO=1 enchaine les etapes sans attendre Entree.
set -euo pipefail

TRACE=http://127.0.0.1:8099
PUBKEY=~/web-key.pub
CLOUD_INIT=~/nginx-cloud-init.yaml

mark() {
    curl -s -m 3 -X POST -H "Content-Type: application/json" -d "{\"label\": \"$1\"}" "$TRACE/mark" >/dev/null \
        || echo "   (traceur injoignable : marqueur non pose)"
}

step() {
    echo
    echo "================================================================"
    echo " $1"
    echo "================================================================"
    if [ "${AUTO:-0}" != 1 ]; then
        read -r -p " Entree pour lancer cette etape (Ctrl+C pour arreter)... " _
    fi
    mark "$1"
    sleep 1
}

run() {
    echo "+ $*"
    "$@"
}

pause_obs() {
    # Laisse le temps aux echanges asynchrones (OVN, RPC) d'apparaitre avant l'etape suivante.
    echo "   ... observe la page (${1:-8} s)"
    sleep "${1:-8}"
}

nettoyer() {
    set +e
    source ~/demo-openrc
    echo "Suppression des ressources du scenario..."
    openstack server delete web-vm --wait 2>/dev/null && echo " instance web-vm supprimee"
    for ip in $(openstack floating ip list -f value -c "Floating IP Address"); do
        openstack floating ip delete "$ip" && echo " IP flottante $ip supprimee"
    done
    openstack router remove subnet web-router web-subnet 2>/dev/null
    openstack router unset --external-gateway web-router 2>/dev/null
    openstack router delete web-router 2>/dev/null && echo " routeur web-router supprime"
    openstack subnet delete web-subnet 2>/dev/null && echo " sous-reseau web-subnet supprime"
    openstack network delete web-net 2>/dev/null && echo " reseau web-net supprime"
    openstack security group delete web-sg 2>/dev/null && echo " groupe de securite web-sg supprime"
    openstack keypair delete web-key 2>/dev/null && echo " paire de cles web-key supprimee"
    source ~/admin-openrc
    openstack flavor delete m1.web 2>/dev/null && echo " flavor m1.web supprime"
    rm -f "$CLOUD_INIT"
    source ~/demo-openrc
    echo "Reste dans le projet demo : $(openstack server list -f value | wc -l) instance(s)," \
         "reseaux : $(openstack network list -f value -c Name | tr '\n' ' ')"
}

if [ "${1:-}" = "nettoyer" ]; then
    nettoyer
    exit 0
fi

if [ ! -f "$PUBKEY" ]; then
    echo "Cle publique absente : $PUBKEY"
    echo "Sous Windows : ssh-keygen -t ed25519 -f \"\$env:USERPROFILE\\.ssh\\web-key\""
    echo "puis : scp \"\$env:USERPROFILE\\.ssh\\web-key.pub\" vagrant@192.168.56.10:~/web-key.pub"
    exit 1
fi
if ! curl -s -m 3 -o /dev/null "$TRACE/history"; then
    echo "Le traceur ne repond pas sur $TRACE : lance d'abord bash ~/2-trace/start.sh"
    exit 1
fi
source ~/demo-openrc
if openstack network show web-net >/dev/null 2>&1; then
    echo "Le reseau web-net existe deja : lance d'abord bash ~/2-trace/scenario-demo.sh nettoyer"
    exit 1
fi

step "1. Flavor m1.web (admin)"
source ~/admin-openrc
run openstack flavor create m1.web --vcpus 1 --ram 1024 --disk 10 --public -c name -c vcpus -c ram -c disk
pause_obs

step "2. Reseau web-net"
source ~/demo-openrc
run openstack network create web-net -c name -c id -c mtu
pause_obs

step "3. Sous-reseau web-subnet"
run openstack subnet create web-subnet --network web-net --subnet-range 10.30.0.0/24 \
    --gateway 10.30.0.1 --dns-nameserver 192.168.57.2 -c name -c cidr -c gateway_ip
pause_obs

step "4. Routeur web-router"
run openstack router create web-router -c name -c id
run openstack router set web-router --external-gateway external-network
run openstack router add subnet web-router web-subnet
pause_obs 10

step "5. Groupe de securite web-sg"
run openstack security group create web-sg --description "SSH et HTTP depuis Windows" -c name -c id
run openstack security group rule create web-sg --ingress --protocol icmp --remote-ip 192.168.57.1/32 -c id
run openstack security group rule create web-sg --ingress --protocol tcp --dst-port 22 --remote-ip 192.168.57.1/32 -c id
run openstack security group rule create web-sg --ingress --protocol tcp --dst-port 80 --remote-ip 192.168.57.1/32 -c id
pause_obs

step "6. Paire de cles web-key"
run openstack keypair create web-key --public-key "$PUBKEY" -c name -c fingerprint
pause_obs

cat > "$CLOUD_INIT" <<'EOF'
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: |
      <!doctype html>
      <html lang="fr">
      <head><meta charset="utf-8"><title>Demo OpenStack</title></head>
      <body>
        <h1>Nginx sur OpenStack Sunbeam</h1>
        <p>Instance : __HOSTNAME__</p>
      </body>
      </html>
runcmd:
  - sed -i "s/__HOSTNAME__/$(hostname)/" /var/www/html/index.html
  - systemctl enable --now nginx
EOF

step "7. Instance web-vm"
run openstack server create web-vm --image ubuntu --flavor m1.web --network web-net \
    --security-group web-sg --key-name web-key --user-data "$CLOUD_INIT" --wait -c name -c status -c addresses
pause_obs 15

step "8. IP flottante"
FIP=$(openstack floating ip create external-network -c floating_ip_address -f value)
echo "+ openstack floating ip create external-network  ->  $FIP"
run openstack server add floating ip web-vm "$FIP"
run openstack server show web-vm -c name -c status -c addresses
pause_obs

mark "Fin du scenario"
echo
echo "================================================================"
echo " Scenario termine. IP flottante : $FIP"
echo " Depuis Windows (PowerShell), une fois cloud-init termine (1 a 3 min) :"
echo "   ping $FIP"
echo "   ssh -i \"\$env:USERPROFILE\\.ssh\\web-key\" ubuntu@$FIP"
echo "   navigateur : http://$FIP/"
echo " Suivi de cloud-init : openstack console log show web-vm --lines 20"
echo " Pour tout supprimer : bash ~/2-trace/scenario-demo.sh nettoyer"
echo "================================================================"
