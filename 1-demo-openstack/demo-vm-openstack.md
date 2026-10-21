# Démo : une VM Nginx sur OpenStack Sunbeam, en CLI

**But :** créer avec le CLI OpenStack tout ce qu’il faut pour lancer une VM Ubuntu avec Nginx, puis s’y connecter en SSH et afficher sa page web **depuis Windows**, la machine hôte.

Ressources créées :

| Ressource | Nom | Valeur |
|---|---|---|
| Image | `ubuntu` | Ubuntu 24.04 cloud image (publique) |
| Flavor | `m1.web` | 1 vCPU, 1 Go RAM, 10 Go disque |
| Réseau privé | `web-net` | — |
| Sous-réseau | `web-subnet` | `10.30.0.0/24`, DNS `192.168.57.2` |
| Routeur | `web-router` | Passerelle sur `external-network` |
| Groupe de sécurité | `web-sg` | ICMP, SSH 22, HTTP 80 depuis Windows `192.168.57.1` |
| Paire de clés | `web-key` | Clé publique générée sous Windows |
| Instance | `web-vm` | Nginx installé par cloud-init |
| IP publique | IP flottante | Prise dans `192.168.57.100–199` |

**Prérequis :** le lab est démarré et validé (étapes 8 à 10 de `deployment-apprenant-windows.md` ou `deployment-apprenant-ubuntu.md`) : `Lab-Services`, puis `Lab-Sunbeam`, et `/dev/kvm` présent. Vérifie aussi les trois points ci-dessous avant de lancer une VM.

| Contrôle | Où | Commande | Attendu |
|---|---|---|---|
| Ceph actif | Lab-Sunbeam | `sudo ceph -s \| grep -E "osd:\|pgs:"` | `1 osds: 1 up` et `active+clean` |
| KVM imbriqué sans EPT | Lab-Sunbeam | `cat /sys/module/kvm_intel/parameters/ept` | `N` |
| MTU du réseau des instances | Lab-Services | `ip -br link show provider0` | `mtu 1442` |

Si un contrôle échoue, applique la correction correspondante dans **Dépannage** avant de continuer.

---

## 0. Comprendre le chemin réseau

```text
 Windows 192.168.57.1 ──(Host-only #2)── IP flottante 192.168.57.1xx
                                              │  NAT 1:1 (Neutron/OVN)
                                         web-router ── web-subnet 10.30.0.0/24 ── web-vm 10.30.0.x
                                              │  SNAT (sortie Internet)
                                   passerelle 192.168.57.2 (Lab-Services) ── NAT ── Internet
```

- **`external-network`** est le réseau « public » du lab (`192.168.57.0/24`). Il n’est **pas** exposé sur Internet : seul le PC Windows y a accès.
- L’**IP flottante** est l’« IP publique » de la VM : Windows s’y connecte directement.
- La VM sort sur Internet (pour installer Nginx) via le routeur, puis via Lab-Services.

---

## 1. Préparer la clé SSH sous Windows

Dans **PowerShell** (utilisateur normal) :

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\web-key"
```

Tu peux laisser la phrase de passe vide pour la démo.

Copie la clé **publique** dans Lab-Sunbeam (mot de passe du compte `vagrant`) :

```powershell
scp "$env:USERPROFILE\.ssh\web-key.pub" vagrant@192.168.56.10:~/web-key.pub
```

La clé **privée** `web-key` reste sur Windows : elle ne doit jamais être copiée ailleurs.

---

## 2. Se connecter à Lab-Sunbeam

```powershell
ssh vagrant@192.168.56.10
```

Toutes les commandes `openstack` suivantes se lancent **dans Lab-Sunbeam**. Deux fichiers d’identification existent :

| Fichier | Compte | Utilisation |
|---|---|---|
| `~/admin-openrc` | `admin` | Ressources partagées : image publique, flavor |
| `~/demo-openrc` | `demo` (domaine `users`, projet `demo`) | Tout le reste : réseau, routeur, VM… |

Vérifie que l’authentification fonctionne :

```bash
source ~/demo-openrc
openstack token issue -c expires -f value
```

---

## 3. Image Ubuntu (admin)

Seul un administrateur peut publier une image pour tous les projets.

```bash
source ~/admin-openrc
openstack image list
```

**Si l’image `ubuntu` existe déjà, passe à l’étape 4.** Sinon, télécharge l’image cloud officielle d’Ubuntu 24.04 et importe-la dans Glance :

```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

```bash
openstack image create ubuntu \
  --file noble-server-cloudimg-amd64.img \
  --disk-format qcow2 --container-format bare \
  --property architecture=x86_64 \
  --public
```

Vérifie que son statut est `active` :

```bash
openstack image show ubuntu -c status -c size -c visibility
```

---

## 4. Flavor (admin)

Le flavor définit le gabarit de la VM. Une image Ubuntu cloud a besoin d’au moins 1 Go de RAM et de quelques Go de disque.

```bash
source ~/admin-openrc
openstack flavor create m1.web --vcpus 1 --ram 1024 --disk 10 --public
openstack flavor show m1.web -c vcpus -c ram -c disk
```

À partir d’ici, **tout se fait avec le compte `demo`**.

---

## 5. Réseau et sous-réseau privés

```bash
source ~/demo-openrc
openstack network create web-net
```

```bash
openstack subnet create web-subnet \
  --network web-net \
  --subnet-range 10.30.0.0/24 \
  --gateway 10.30.0.1 \
  --dns-nameserver 192.168.57.2
```

Le serveur DNS `192.168.57.2` est le dnsmasq de Lab-Services : il permet à la VM de résoudre les noms des dépôts Ubuntu.

---

## 6. Routeur

Le routeur relie le réseau privé au réseau externe et fait le NAT.

```bash
openstack router create web-router
openstack router set web-router --external-gateway external-network
openstack router add subnet web-router web-subnet
```

Vérifie l’adresse externe du routeur :

```bash
openstack router show web-router -c external_gateway_info -f yaml
```

Depuis **Windows**, cette adresse `192.168.57.1xx` doit répondre au ping :

```powershell
ping 192.168.57.1xx
```

---

## 7. Groupe de sécurité

Par défaut, tout le trafic entrant est bloqué. On autorise uniquement le PC Windows (`192.168.57.1`).

```bash
openstack security group create web-sg --description "SSH et HTTP depuis Windows"
```

```bash
openstack security group rule create web-sg --ingress --protocol icmp --remote-ip 192.168.57.1/32
openstack security group rule create web-sg --ingress --protocol tcp --dst-port 22 --remote-ip 192.168.57.1/32
openstack security group rule create web-sg --ingress --protocol tcp --dst-port 80 --remote-ip 192.168.57.1/32
```

```bash
openstack security group rule list web-sg
```

Le trafic sortant reste autorisé : la VM peut télécharger Nginx.

---

## 8. Paire de clés

On importe la clé publique copiée à l’étape 1 :

```bash
openstack keypair create web-key --public-key ~/web-key.pub
openstack keypair list
```

---

## 9. Script cloud-init : installer Nginx au premier démarrage

```bash
cat > ~/nginx-cloud-init.yaml <<'EOF'
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
```

cloud-init s’exécute une seule fois, au premier démarrage : il installe Nginx et remplace la page d’accueil.

---

## 10. Lancer la VM

```bash
openstack server create web-vm \
  --image ubuntu \
  --flavor m1.web \
  --network web-net \
  --security-group web-sg \
  --key-name web-key \
  --user-data ~/nginx-cloud-init.yaml \
  --wait
```

Le premier lancement peut prendre plusieurs minutes : Nova copie l’image depuis Glance/Ceph vers l’hyperviseur. Le statut final doit être `ACTIVE`.

```bash
openstack server list
```

Si le statut est `ERROR`, consulte le paragraphe **Dépannage**.

---

## 11. IP publique (IP flottante)

```bash
FIP=$(openstack floating ip create external-network -c floating_ip_address -f value)
openstack server add floating ip web-vm "$FIP"
echo "$FIP"
```

```bash
openstack server show web-vm -c status -c addresses
```

La VM a maintenant deux adresses : `10.30.0.x` (privée) et `192.168.57.1xx` (flottante). **Note l’IP flottante.**

---

## 12. Suivre le démarrage et cloud-init

```bash
openstack console log show web-vm --lines 30
```

Attends une ligne du type `Cloud-init v. ... finished`. L’installation de Nginx prend 1 à 3 minutes après le démarrage.

---

## 13. Depuis Windows : SSH et navigateur

Remplace `192.168.57.1xx` par l’IP flottante notée.

**Ping :**

```powershell
ping 192.168.57.1xx
```

**SSH** (le compte des images Ubuntu cloud est `ubuntu`) :

```powershell
ssh -i "$env:USERPROFILE\.ssh\web-key" ubuntu@192.168.57.1xx
```

Dans la VM :

```bash
systemctl is-active nginx
curl -s localhost | head -5
exit
```

**Navigateur :** ouvre `http://192.168.57.1xx/`. La page « Nginx sur OpenStack Sunbeam » s’affiche avec le nom de l’instance.

Test rapide depuis PowerShell :

```powershell
(Invoke-WebRequest http://192.168.57.1xx/ -UseBasicParsing).Content
```

---

## 14. Nettoyage

Dans Lab-Sunbeam, dans l’ordre inverse de la création :

```bash
source ~/demo-openrc
openstack server delete web-vm --wait
openstack floating ip delete "$FIP"
openstack router remove subnet web-router web-subnet
openstack router unset --external-gateway web-router
openstack router delete web-router
openstack subnet delete web-subnet
openstack network delete web-net
openstack security group delete web-sg
openstack keypair delete web-key
```

Si la variable `$FIP` est perdue, `openstack floating ip list` affiche l’adresse à supprimer.

Le flavor et l’image sont partagés : supprime-les seulement s’ils ne servent plus.

```bash
source ~/admin-openrc
openstack flavor delete m1.web
```

---

## Dépannage

| Symptôme | Vérification |
|---|---|
| `server create` : statut `ERROR`, « Exhausted all hosts » | `source ~/admin-openrc` puis `openstack server show <ID> -c fault` |
| Erreur Glance `HTTP 502 Proxy Error` dans les logs Nova | Ceph est arrêté : `sudo ceph -s` doit afficher `HEALTH_OK` ou `HEALTH_WARN` avec `1 osds: 1 up` |
| `osd: 1 osds: 0 up` et `Operation not permitted` dans `journalctl -u snap.microceph.osd` | Le disque Ceph a changé d’identifiant après l’import de l’OVA : voir la section suivante |
| VM `ACTIVE` mais ni ping ni SSH ; `Kernel panic`, `BUG: kernel NULL pointer dereference` ou `Oops` dans `openstack console log show web-vm` | Mémoire corrompue par KVM imbriqué dans VirtualBox : voir **KVM imbriqué : désactiver EPT** |
| Ping du routeur impossible depuis Windows | Carte 3 de Lab-Sunbeam sur l’adaptateur `192.168.57.1`, promiscuité « Tout autoriser » |
| Ping de la VM OK, SSH refusé | Clé importée ? Compte `ubuntu` ? `openstack console log show web-vm` pour voir si la VM a fini de démarrer |
| SSH OK, page web absente | cloud-init pas terminé, ou pas d’Internet : dans la VM, `cloud-init status` et `ping -c2 ubuntu.com` |
| Ping vers Internet OK depuis la VM, mais `apt` bloqué (`Connection failed`, `Ign:`) et HTTPS figé | Paquets trop gros pour le réseau de la VM : voir **MTU du réseau des instances** |
| Pas d’Internet dans la VM | Lab-Services démarrée ? `192.168.57.2` est la passerelle et le DNS |

### KVM imbriqué : désactiver EPT

Sur certains processeurs (notamment Intel hybrides de 12e à 14e génération), KVM dans Sunbeam, lui-même dans VirtualBox, corrompt la mémoire des instances : le noyau invité plante à des endroits différents à chaque démarrage. Désactiver EPT dans le KVM de Sunbeam corrige le problème.

Dans **Lab-Sunbeam**, arrête d’abord toutes les instances :

```bash
source ~/demo-openrc
openstack server stop web-vm
sudo openstack-hypervisor.virsh list --all
```

Toutes les instances doivent être `shut off`. Puis :

```bash
echo "options kvm_intel ept=0" | sudo tee /etc/modprobe.d/kvm-intel-ept.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
cat /sys/module/kvm_intel/parameters/ept
```

Le résultat doit être `N`. Le fichier `/etc/modprobe.d/kvm-intel-ept.conf` rend le réglage permanent. Redémarre ensuite l’instance :

```bash
openstack server start web-vm
```

Si cloud-init n’a pas pu aller au bout lors du premier démarrage, reconstruis l’instance pour repartir d’un disque propre :

```bash
openstack server rebuild web-vm --image ubuntu --wait
```

### MTU du réseau des instances

Le réseau privé `web-net` a une MTU de 1442 (encapsulation Geneve d’OVN). Le NAT VirtualBox de Lab-Services ignore le MSS annoncé par la VM et renvoie des segments TCP de 1480 octets : OVN les jette. Les petits échanges passent (ping, DNS, petites pages), les téléchargements restent bloqués.

Dans **Lab-Services**, abaisse la MTU de `provider0` à 1442 : Lab-Services fragmente alors les paquets avant de les envoyer vers les instances.

```bash
sudo ip link set provider0 mtu 1442
ip -br link show provider0
```

Pour rendre le réglage permanent, ajoute `mtu: 1442` sous `provider0` dans `/etc/netplan/60-lab.yaml` :

```yaml
    provider0:
      match: {macaddress: '08:00:27:57:00:02'}
      set-name: provider0
      addresses: [192.168.57.2/24]
      dhcp4: false
      mtu: 1442
```

Puis :

```bash
sudo netplan apply
```

Test depuis la VM :

```bash
curl -4 -s -o /dev/null -w "%{http_code} %{size_download}\n" http://archive.ubuntu.com/ubuntu/dists/noble/Release
```

Le résultat attendu est `200` suivi de la taille du fichier, en moins d’une seconde.

### OSD Ceph arrêté après l’import des OVA

VirtualBox attribue un nouvel identifiant au disque Ceph lors de l’import : si le lien de l’OSD utilise un chemin `/dev/disk/by-id/...`, il pointe ensuite vers un disque qui n’existe plus. Les OVA corrigées utilisent un chemin par port SATA, stable à l’import.

```bash
sudo ls -l /var/snap/microceph/common/data/osd/ceph-1/block
```

Si le lien ne pointe pas vers `/dev/disk/by-path/pci-0000:00:1f.2-ata-2`, corrige-le puis redémarre l’OSD :

```bash
sudo ln -sfn /dev/disk/by-path/pci-0000:00:1f.2-ata-2 /var/snap/microceph/common/data/osd/ceph-1/block
sudo systemctl reset-failed snap.microceph.osd.service
sudo snap restart microceph.osd
sudo ceph -s
```

L’OSD doit revenir à `1 osds: 1 up, 1 in` et les PG passer en `active+clean`.
