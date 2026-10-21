# Déploiement apprenant : lab OpenStack Sunbeam sous Ubuntu (VirtualBox)

Ce pas à pas installe le lab à partir des deux OVA fournies, `Services-base.ova` et `Sunbeam-base.ova`, sur un **hôte Ubuntu 24.04 avec VirtualBox pour Linux**. Les OVA, les adresses et les contrôles sont les mêmes que sous Windows ; seules les commandes côté hôte changent.

**État :** les OVA ont été validées sur un hôte Windows (OpenStack, instance Nginx jointe en SSH et HTTP). **Ce parcours Ubuntu n’a pas encore été rejoué de bout en bout** : teste-le sur un poste avant de le distribuer.

Variante Windows et préparation des OVA par le formateur : `deployment-apprenant-windows.md` (partie A).

## Vue d’ensemble

| VM | Rôle | Carte 1 | Carte 2 : gestion `192.168.56.0/24` | Carte 3 : instances `192.168.57.0/24` |
|---|---|---|---|---|
| **Lab-Services** | Keycloak, DNS (dnsmasq), passerelle des instances | NAT | `mgmt0` = `192.168.56.20` | `provider0` = `192.168.57.2` (MTU 1442) |
| **Lab-Sunbeam** | OpenStack Sunbeam, Ceph, hyperviseur Nova | NAT | `mgmt0` = `192.168.56.10` + API `.201`, `.202`, `.203` | `provider0` sans IP (pont Open vSwitch) |
| **Hôte Ubuntu** | Navigateur, SSH, CLI | — | `vboxnet0` = `192.168.56.1` | `vboxnet1` = `192.168.57.1` |

| Nom | Adresse | Service |
|---|---|---|
| `sso.lab.test` | `192.168.56.20` | Keycloak `https://sso.lab.test:8443` |
| `cloud.lab.test` | `192.168.56.201` | Horizon et API publiques |
| `internal.lab.test` | `192.168.56.202` | API internes |
| `rgw.lab.test` | `192.168.56.203` | Stockage objet Ceph |

Fichiers fournis par le formateur, à placer par exemple dans `~/Lab-OpenStack/` :

```text
Services-base.ova
Sunbeam-base.ova
Configurer-Lab-Sunbeam.sh
ca.crt
1-demo-openstack/demo-vm-openstack.md
```

---

## 1. Vérifier l’hôte Ubuntu

| Ressource | Valeur |
|---|---|
| Système | Ubuntu 24.04 LTS, bureau (pour le navigateur), **installé directement sur le PC** |
| Architecture | **Intel** x86-64 (AMD : prévenir le formateur, voir étape 10.3) |
| RAM | **48 Go conseillés**, 32 Go au strict minimum |
| Processeurs | 16 threads ou plus conseillés |
| Stockage | SSD, environ 300 Go libres |
| Virtualisation | Intel VT-x activé dans l’UEFI/BIOS |

**Pourquoi autant de mémoire :** les deux VM réservent ensemble environ **28 Go** (Lab-Sunbeam 23 675 Mo, Lab-Services 5 056 Mo, réglages des OVA d’octobre 2026). Sur un hôte de 32 Go, il ne reste presque rien pour Ubuntu et le navigateur : constaté sur le PC Windows de référence, avec 0,1 à 0,6 Go libres, une charge très élevée et des pannes aléatoires du cloud. Les VM déclarent aussi 17 processeurs virtuels (12 + 5) : VirtualBox accepte d’en donner plus que l’hôte n’a de threads, mais tout ralentit.

```bash
nproc
free -g
df -h ~
grep -c vmx /proc/cpuinfo
```

`grep -c vmx` doit renvoyer un nombre supérieur à 0. Sinon, VT-x est désactivé dans l’UEFI/BIOS, ou l’hôte Ubuntu est lui-même une VM qui n’expose pas la virtualisation.

### Hôte Ubuntu qui est lui-même une VM

**À éviter.** Ce guide suppose un Ubuntu installé **directement** sur le PC physique, avec VirtualBox dans cet Ubuntu.

Si Ubuntu est lui-même une VM (dans VirtualBox, VMware, Proxmox, Hyper-V, un cloud…), la chaîne devient : PC physique → hyperviseur → Ubuntu → VirtualBox → Lab-Sunbeam → KVM → instances Nova. Les instances tournent alors sur **trois niveaux** de virtualisation imbriquée :

| Niveau | Ce qu’il exige |
|---|---|
| 1. Hyperviseur du PC → Ubuntu | Exposer VT-x à la VM Ubuntu (`grep -c vmx` > 0 dans Ubuntu) |
| 2. VirtualBox dans Ubuntu → Lab-Sunbeam | Que VirtualBox accepte de tourner dans une VM, et y propose encore « VT-x/AMD-V imbriqué » |
| 3. KVM dans Lab-Sunbeam → instances | Que `/dev/kvm` existe dans Lab-Sunbeam |

Ce montage **n’a pas été validé**. Même en partie fonctionnel, il serait très lent : le PC de référence, avec seulement deux niveaux (Windows → VirtualBox → KVM), montait déjà à une charge de 30 à 70 pendant certaines opérations. Et il faudrait une VM Ubuntu d’au moins 48 Go de RAM. **Installe Ubuntu sur le disque du PC** (disque dédié ou double démarrage).

Vérifie aussi que les réseaux `192.168.56.0/24` et `192.168.57.0/24` ne sont pas déjà utilisés par l’hôte :

```bash
ip -br addr | grep -E "192\.168\.5[67]\."
```

Aucune ligne ne doit s’afficher avant la création des réseaux de l’étape 4.

## 2. Libérer VT-x pour VirtualBox

Sur Linux, KVM et VirtualBox ne peuvent pas utiliser VT-x en même temps. Ubuntu charge KVM automatiquement : selon la version du noyau, VirtualBox refuse alors de démarrer une VM avec l’erreur `VERR_VMX_IN_VMX_ROOT_MODE`.

```bash
lsmod | grep -E "^kvm"
uname -r
```

Si des modules `kvm` sont chargés, décharge-les et empêche leur chargement (aucune VM KVM/libvirt ne doit tourner) :

```bash
sudo modprobe -r kvm_intel kvm
```

```bash
printf 'blacklist kvm_intel\nblacklist kvm\n' | sudo tee /etc/modprobe.d/blacklist-kvm-virtualbox.conf
```

Cela rend KVM, libvirt, GNOME Boxes et Multipass inutilisables sur cet hôte. Pour revenir en arrière après la formation : supprime ce fichier et redémarre.

## 3. Installer VirtualBox

Installe VirtualBox depuis le dépôt Oracle, de préférence **la version validée par le formateur** (7.2.x) :

```bash
sudo apt update
sudo apt install -y wget gpg
```

```bash
wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
```

```bash
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $(. /etc/os-release; echo "$VERSION_CODENAME") contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
```

```bash
sudo apt update
sudo apt install -y virtualbox-7.2
sudo usermod -aG vboxusers "$USER"
```

**Secure Boot :** si `mokutil --sb-state` affiche `SecureBoot enabled`, l’installation demande un mot de passe pour signer les modules VirtualBox. Au redémarrage suivant, l’écran bleu **MOK Management** apparaît : choisis **Enroll MOK**, puis saisis ce mot de passe.

Ferme ta session puis rouvre-la (groupe `vboxusers`), ou redémarre. Lance ensuite **Oracle VirtualBox** depuis le menu des applications : **Aide → À propos de VirtualBox** affiche la version installée.

## 4. Créer les deux réseaux Host-only

VirtualBox pour Linux n’accepte que certaines plages pour les réseaux Host-only. Déclare d’abord les deux réseaux du lab, dans un terminal :

```bash
sudo mkdir -p /etc/vbox
echo "* 192.168.56.0/24 192.168.57.0/24" | sudo tee /etc/vbox/networks.conf
```

Si ce fichier existait déjà avec d’autres plages, ajoute-les sur la même ligne au lieu de les écraser. Sans ce fichier, VirtualBox refuse l’adresse `192.168.57.1`.

Dans VirtualBox : **Fichier → Outils → Gestionnaire de réseau**, onglet **Réseaux privés hôte**. Clique deux fois sur **Créer** : VirtualBox crée `vboxnet0` puis `vboxnet1`. Pour chacun, sélectionne-le et configure :

| Paramètre | `vboxnet0` : gestion | `vboxnet1` : instances |
|---|---|---|
| Onglet **Adaptateur** | **Configurer l’adaptateur manuellement** | **Configurer l’adaptateur manuellement** |
| Adresse IPv4 | `192.168.56.1` | `192.168.57.1` |
| Masque réseau IPv4 | `255.255.255.0` | `255.255.255.0` |
| Onglet **Serveur DHCP** | **Activer le serveur** décoché | **Activer le serveur** décoché |

Clique sur **Appliquer** après chaque réseau.

Si des réseaux Host-only existaient déjà, les numéros seront différents : **repère chaque réseau par son adresse IP, pas par son nom**.

## 5. Importer les deux OVA

**Fichier → Importer un appareil virtuel** :

1. Sélectionne `~/Lab-OpenStack/Services-base.ova`.
2. Nomme la VM **`Lab-Services`**.
3. Choisis le **dossier de base** sur le SSD.
4. **Politique d’adresse MAC** : **Inclure toutes les adresses MAC des cartes réseau**. N’utilise pas « uniquement les cartes NAT » : dans les VM, netplan reconnaît les cartes 2 et 3 par leur MAC.
5. Clique sur **Terminer**.
6. Recommence avec `Sunbeam-base.ova`, nommée **`Lab-Sunbeam`**.

**Ne démarre pas encore les VM.**

## 6. Brancher les cartes réseau

Pour **chacune des deux VM** : sélectionne-la, puis **Configuration → Réseau**.

| Carte | Mode d’accès réseau | Nom |
|---|---|---|
| Adaptateur 1 | **NAT** | — |
| Adaptateur 2 | **Réseau privé hôte** | Le réseau `192.168.56.1` (`vboxnet0`) |
| Adaptateur 3 | **Réseau privé hôte** | Le réseau `192.168.57.1` (`vboxnet1`) |

Sur les trois cartes : **Activer l’interface réseau** coché. Dans **Avancé** : **Câble branché** coché, type de carte et adresse MAC inchangés.

Sur les adaptateurs **2 et 3**, dans **Avancé**, règle **Mode promiscuité : Tout autoriser** : les IP des API OpenStack et des instances Nova utilisent d’autres MAC que celles des cartes.

Toujours dans **Avancé**, vérifie l’**adresse MAC** des cartes 2 et 3 :

| VM | Adaptateur 2 | Adaptateur 3 |
|---|---|---|
| Lab-Services | `080027560020` | `080027570002` |
| Lab-Sunbeam | `080027560010` | `080027570010` |

Si les MAC diffèrent, supprime la VM (**Supprimer → Supprimer tous les fichiers**) et réimporte-la en choisissant la bonne politique MAC.

## 7. Activer la virtualisation imbriquée de Lab-Sunbeam

VM **Lab-Sunbeam éteinte** : **Configuration → Système**.

1. Onglet **Carte mère** : vérifie la mémoire vive, **23 675 Mo** dans les OVA d’octobre 2026. Ne descends pas sous 20 Go : Kubernetes, Ceph et les services OpenStack en utilisent déjà une douzaine au repos, et chaque instance prend la sienne en plus.
2. Onglet **Processeur** : vérifie le nombre de processeurs, **12** dans ces OVA, et coche **Activer VT-x/AMD-V imbriqué**. Si l’hôte a moins de 16 threads, tu peux descendre à 8.

Pour Lab-Services, laisse les réglages de l’OVA (5 056 Mo, 5 processeurs).

## 8. Démarrer les VM

### 8.0 Empêcher la mise en veille de l’hôte

Une mise en veille de l’hôte fige les deux VM. À leur réveil, leur horloge a sauté et la charge explose : constaté sur le lab de référence le 17 octobre (1 h 31 de figeage), avec des `503` aléatoires pendant longtemps. Le 18 octobre, Lab-Services est même restée bloquée (`rcu_preempt detected expedited stalls` en boucle sur sa console).

Pendant toute la durée de la formation, désactive la mise en veille :

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**Pourquoi `mask` :** la mise en veille d’Ubuntu passe par ces cibles de `systemd` ; les masquer les rend impossibles à atteindre, quelle que soit la cause (inactivité, couvercle fermé, menu). Pour revenir en arrière après la formation :

```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 8.1 Lab-Services d’abord

Sélectionne **Lab-Services** et clique sur **Démarrer**. La console de la VM s’ouvre dans une fenêtre ; tu peux t’y connecter avec `vagrant`, ou utiliser SSH depuis un terminal de l’hôte.

Attends une minute, puis :

```bash
ssh vagrant@192.168.56.20
```

```bash
ip -br addr
ip link show provider0 | grep -o "mtu [0-9]*"
systemctl is-active docker dnsmasq
sudo docker ps --format "{{.Names}} {{.Status}}"
exit
```

| Attendu | |
|---|---|
| `mgmt0` | `192.168.56.20/24` |
| `provider0` | `192.168.57.2/24`, `mtu 1442` |
| Services | `active` et `active` |
| Conteneurs | `keycloak-keycloak-1` et `keycloak-postgres-1` démarrés |

### 8.2 Lab-Sunbeam ensuite

Sélectionne **Lab-Sunbeam** et clique sur **Démarrer**.

Si VirtualBox affiche une erreur `VERR_VMX_IN_VMX_ROOT_MODE`, KVM occupe VT-x : reprends l’étape 2.

Vérifie le moteur utilisé par VirtualBox : clic droit sur **Lab-Sunbeam → Afficher le journal**, onglet `VBox.log`, puis recherche `HMR3Init` (champ de recherche en bas de la fenêtre).

| Résultat | Signification |
|---|---|
| `VT-x w/ nested paging and unrestricted guest execution hw support`, et plus bas `VT-x nested-guest init` | ✅ Configuration correcte |
| Pas de `nested-guest init` | ❌ Case **VT-x/AMD-V imbriqué** non cochée : éteins la VM et reprends l’étape 7 |

Puis :

```bash
ssh vagrant@192.168.56.10
```

```bash
ip -br addr show mgmt0
ip -br addr show provider0
ls -l /dev/kvm
```

`mgmt0` porte `192.168.56.10/24` ; `provider0` est `UP` **sans adresse IP** (pont Open vSwitch : ne lui en ajoute pas) ; `/dev/kvm` existe.

**Après chaque démarrage, Sunbeam a besoin de 10 à 15 minutes** pour relancer Kubernetes et les services OpenStack. Pendant ce temps, Horizon peut ne pas répondre ou renvoyer une erreur 503 : attends avant de diagnostiquer.

## 9. Configurer les noms et le certificat sur l’hôte

```bash
cd ~/Lab-OpenStack
sudo bash ./Configurer-Lab-Sunbeam.sh
```

Le script ajoute les quatre noms du lab à `/etc/hosts` (avec sauvegarde) et approuve la CA du lab pour le système (`curl`, `openssl`…).

| Message du script | Signification |
|---|---|
| `OK : <nom> -> <adresse>` pour les quatre noms | ✅ `/etc/hosts` correct |
| `OK : Keycloak, port 8443 accessible.` | ✅ Lab-Services joignable |
| `OK : Horizon HTTP, port 80 accessible.` | ✅ Lab-Sunbeam joignable (après 10 à 15 min) |
| `AVERTISSEMENT : OpenStack HTTPS ... inaccessible` | **Attendu** : Horizon est encore en HTTP dans ces OVA |

Les navigateurs ont leur propre magasin de certificats. Pour Keycloak, importe `ca.crt` :

- **Firefox** : Paramètres → Vie privée et sécurité → Certificats → **Afficher les certificats** → onglet **Autorités** → **Importer**, coche « Confirmer cette AC pour identifier des sites web ».
- **Chrome / Chromium** : `chrome://settings/certificates` → **Autorités** → **Importer**, même case à cocher.

## 10. Vérifier OpenStack

Toutes les commandes se lancent dans **Lab-Sunbeam** (`ssh vagrant@192.168.56.10`), sauf 10.4.

### 10.1 Unités Juju

```bash
juju status -m openstack
juju status -m admin/openstack-machines
```

Le modèle des machines appartient à l’utilisateur Juju `admin` : `juju status -m openstack-machines` renvoie `model ... not found`. À la fin, toutes les applications doivent être `active`.

Pour ne voir que ce qui ne va pas :

```bash
juju status -m openstack --format short | grep -v "workload:active"
```

Attendu, une fois le cloud prêt : aucune ligne.

#### Juste après le démarrage : un écran plein de rouge, c’est normal

Dans les 10 à 15 minutes qui suivent le démarrage de Lab-Sunbeam, on voit en général (constaté sur le lab le 18 octobre 2026) :

| Unité | État | Ce que ça veut dire |
|---|---|---|
| `mysql/0` | `maintenance` « Starting mysqld » | **La cause** : la base de données démarre encore |
| `*-mysql-router/0` | `error` « hook failed: "start" » ou « "update-status" » | Le routeur a essayé de joindre une base pas encore prête ; son charm a échoué une fois, et Juju attend qu’on lui dise de réessayer |
| `neutron/0`, `nova/0`, `placement/0` | `blocked` « (container:…) healthcheck failed: online » | Pebble, le gestionnaire de processus du conteneur, vérifie que le service répond ; sans base de données, il ne répond pas |

Tout dépend de la base : les services dépendent des routeurs, qui dépendent de `mysql`. On répare **de bas en haut** :

**1. Attendre que MySQL soit prêt.** Relancer la commande toutes les 30 secondes, jusqu’à lire `active` et `Primary` :

```bash
juju status -m openstack mysql
```

**2. Relancer les unités en `error`.** Une unité en `error` ne réessaie jamais seule : `juju resolved` relance l’étape qui a échoué. Pour toutes d’un coup :

```bash
for u in $(juju status -m openstack --format short | grep "workload:error" | sed "s/^- \([^:]*\):.*/\1/"); do echo "$u"; juju resolved -m openstack "$u"; done
```

Ou une par une, par exemple : `juju resolved -m openstack keystone-mysql-router/0`. Un `keystone-mysql-router` resté en erreur bloque toute authentification (`HTTP 500`).

**3. Attendre les `blocked`.** Neutron, Nova et Placement repassent `active` seuls, 1 à 3 minutes après le retour de la base : Pebble refait son test régulièrement. Pour suivre :

```bash
watch -n 15 "juju status -m openstack --format short | grep -v workload:active"
```

`Ctrl+C` pour quitter `watch` quand l’écran est vide.

#### Si une unité reste en défaut : creuser

Exemple avec `nova/0` ; remplacer par l’unité concernée.

| Question | Commande |
|---|---|
| Quand a-t-elle changé d’état, et pourquoi ? | `juju show-status-log -m openstack nova/0` |
| Quelle est l’erreur exacte de son charm (« hook failed ») ? | `juju debug-log -m openstack --replay --no-tail --include nova/0 \| tail -30` |
| Quel test de Pebble échoue ? | `sudo k8s kubectl -n openstack exec nova-0 -c nova-api -- /charm/bin/pebble checks` |
| Que dit le service lui-même ? | `sudo k8s kubectl -n openstack logs nova-0 -c nova-api --tail=30` |

Le nom du conteneur (`nova-api`) se lit dans le message `(container:nova-api)` de `juju status`. La fiche `4-juju-cli/DEPANNAGE-SERVICES.md` reprend cette démarche service par service (Keystone, MySQL, Glance, Nova, Neutron, Cinder, Ceph, accès). Le guide `4-juju-cli/DEMOS-PANNES.md` la met en pratique, avec une panne Pebble provoquée puis corrigée (partie 5).

**Quand s’inquiéter :**

- `mysql/0` reste en `maintenance` plus de 20 minutes : lire `juju debug-log -m openstack --replay --no-tail --include mysql/0 | tail -30` ;
- une unité repasse en `error` juste après `juju resolved` : la cause n’est pas la base ; lire son `debug-log` ;
- tout reste figé, charge très élevée (`uptime`) : vérifier que VT-x est libre pour VirtualBox (étape 2) et la virtualisation imbriquée (étape 7).

### 10.2 Ceph

```bash
sudo ceph -s | grep -E "osd:|pgs:"
```

Attendu : `1 osds: 1 up` et `289 active+clean`. Le `HEALTH_WARN` « pools have no replicas configured » est normal sur un nœud unique.

Si l’OSD est `0 up`, vérifie son lien :

```bash
sudo ls -l /var/snap/microceph/common/data/osd/ceph-1/block
```

S’il ne pointe pas vers `/dev/disk/by-path/pci-0000:00:1f.2-ata-2` :

```bash
sudo ln -sfn /dev/disk/by-path/pci-0000:00:1f.2-ata-2 /var/snap/microceph/common/data/osd/ceph-1/block
sudo systemctl reset-failed snap.microceph.osd.service
sudo snap restart microceph.osd
```

Sans Ceph, Glance ne fournit pas les images et Nova échoue (`HTTP 502`).

**Le service des volumes (Cinder)**

Ceph peut être sain alors que Cinder n’a plus accès au stockage. C’est arrivé sur le lab après une réimportation : au démarrage, les charms `microceph` et `cinder-volume` ont dépassé un délai et sont restés figés, alors que `ceph -s` était correct.

```bash
source ~/admin-openrc
openstack volume service list -c Binary -c Host -c State -c "Updated At"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
```

Attendu : `cinder-volume … up`, et `microceph/0` comme `cinder-volume/0` en `workload:active`.

| Symptôme | Signification |
|---|---|
| `cinder-volume … down`, `Updated At` figé à l’heure du démarrage | Cinder n’a plus de stockage : toute création de volume passe en `error` |
| `microceph/0 … workload:blocked` (« Error in charm: timed out ») | Le charm MicroCeph a échoué au démarrage et ne transmet plus les informations de Ceph |
| `cinder-volume/0 … workload:waiting` (« Not all relations are ready ») | Conséquence du point précédent : le service `cinder-volume` reste désactivé |

Correction : relancer la configuration des deux charms, **MicroCeph d’abord**, en vérifiant après chacun.

```bash
juju exec -m admin/openstack-machines --unit microceph/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
juju exec -m admin/openstack-machines --unit cinder-volume/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
```

Les deux unités doivent passer en `workload:active` (MicroCeph peut afficher encore une fois « timed out » avant d’aboutir). Redémarrer l’agent Juju de la machine ne suffit pas : l’état figé est conservé.

Vérifier avec un vrai volume :

```bash
openstack volume service list -c Binary -c State
source ~/demo-openrc
openstack volume create lab-vol-test --size 1 -c status
openstack volume show lab-vol-test -c status
openstack volume delete lab-vol-test
source ~/admin-openrc
```

Le volume doit passer `available` en moins d’une minute.

### 10.3 KVM imbriqué sans EPT

```bash
cat /sys/module/kvm_intel/parameters/ept
```

Attendu : `N` (fixé par `/etc/modprobe.d/kvm-intel-ept.conf`). Avec EPT actif, KVM dans VirtualBox peut corrompre la mémoire des instances, qui plantent au démarrage (`Kernel panic`, `BUG: kernel NULL pointer dereference` dans `openstack console log show`).

Si le résultat est `Y`, aucune instance ne doit tourner :

```bash
echo "options kvm_intel ept=0" | sudo tee /etc/modprobe.d/kvm-intel-ept.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
```

Sur un PC **AMD**, `/sys/module/kvm_intel` n’existe pas : ce réglage n’a pas été validé, préviens le formateur.

### 10.4 MTU du réseau des instances (Lab-Services)

```bash
ip link show provider0 | grep -o "mtu [0-9]*"
```

Attendu : `mtu 1442`. Avec 1500, le NAT VirtualBox renvoie des paquets trop gros pour le réseau des instances : ping OK, mais `apt` et HTTPS bloqués dans les VM Nova. Correction : ajoute `mtu: 1442` sous `provider0` dans `/etc/netplan/60-lab.yaml`, puis `sudo netplan apply`.

### 10.5 DNS de Kubernetes

```bash
sudo k8s get dns
```

`upstream-nameservers` doit contenir **`192.168.56.20`**.

### 10.6 API OpenStack

```bash
source ~/demo-openrc
openstack token issue -c expires -f value
openstack network list
openstack subnet list
openstack router list
openstack image list
openstack flavor list
```

Les commandes doivent répondre sans erreur d’authentification, 500 ou 503.

**Ne relance jamais `sunbeam cluster bootstrap` ou `sunbeam configure` : les OVA contiennent déjà le cloud configuré.**

## 11. Se connecter depuis l’hôte

Horizon : [http://cloud.lab.test/openstack-horizon](http://cloud.lab.test/openstack-horizon)

| Champ | Valeur |
|---|---|
| Domaine | `users` |
| Utilisateur | `demo` |
| Mot de passe | Celui transmis par le formateur |

Keycloak : [https://sso.lab.test:8443/admin/](https://sso.lab.test:8443/admin/)

La connexion à Horizon utilise le compte local OpenStack : **la présence de Keycloak ne signifie pas que la fédération SSO est configurée.**

## 12. Premier test : une instance Nginx

Suis `1-demo-openstack/demo-vm-openstack.md`. Les commandes OpenStack sont identiques ; sur l’hôte Ubuntu, remplace les commandes PowerShell par :

| Action | Commande Ubuntu |
|---|---|
| Créer la clé | `ssh-keygen -t ed25519 -f ~/.ssh/web-key` |
| Copier la clé publique | `scp ~/.ssh/web-key.pub vagrant@192.168.56.10:~/web-key.pub` |
| Ping | `ping -c 3 192.168.57.1xx` |
| SSH | `ssh -i ~/.ssh/web-key ubuntu@192.168.57.1xx` |
| Page web | `curl http://192.168.57.1xx/` ou le navigateur |

Les règles du groupe de sécurité autorisent `192.168.57.1/32` : c’est l’adresse de `vboxnet1`, donc de l’hôte Ubuntu, comme pour Windows.

## 13. Arrêter et conserver le lab

En fin de séance :

1. Arrête les instances Nova (Horizon ou `openstack server stop`).
2. Dans **Lab-Sunbeam** : `sudo shutdown -h now`. Dans VirtualBox, attends que la VM passe à l’état **Éteinte**.
3. Dans **Lab-Services** : `sudo shutdown -h now`.

Tu peux aussi utiliser, dans la fenêtre de la VM, **Machine → Extinction par ACPI**. N’utilise pas **Éteindre** (coupure brutale) : les services OpenStack et Ceph doivent s’arrêter proprement.

Pour reprendre : **Services d’abord, Sunbeam ensuite**, puis attends 10 à 15 minutes et refais l’étape 10.1.

Après la première validation complète, crée un snapshot des **deux VM éteintes** : sélectionne la VM, bouton de menu à droite de son nom → **Instantanés** → **Prendre**, nommé par exemple `Base-importee-validee`. Pour revenir à cette base, restaure l’instantané des **deux** VM, éteintes.

⚠ **Jamais d’instantané VM allumée.** Essayé sur Lab-Services le 18 octobre : l’instantané « à chaud » est resté bloqué à 90 % pendant des heures (état `livesnapshotting`), sans jamais être enregistré. Un instantané à chaud copie la mémoire pendant que la VM continue d’écrire ; sur un hôte à court de mémoire, la copie ne rattrape jamais la VM. VM éteinte, l’instantané prend quelques secondes.

**Restaurer :** VM éteinte, dans la liste des instantanés, clique sur la **ligne de l’instantané** (pas sur « État actuel »), puis **Restaurer**, et décoche « Créer un instantané de l’état actuel ».

**Si une VM ne répond plus du tout** (ping possible, SSH muet, console figée) : **Machine → Fermer → Éteindre la machine**, puis **Démarrer**. *Réinitialiser* n’a pas suffi sur Lab-Services le 18 octobre : son noyau bloqué a continué après la réinitialisation.

---

## Dépannage rapide

| Symptôme | Cause probable | Étape |
|---|---|---|
| `VERR_VMX_IN_VMX_ROOT_MODE` au démarrage d’une VM | KVM de l’hôte occupe VT-x | 2 |
| `VERR_VMX_NO_VMX` ou `grep -c vmx` = 0 | VT-x désactivé, ou hôte virtuel sans virtualisation imbriquée | 1 |
| Adresse `192.168.57.1` refusée dans le Gestionnaire de réseau (« E_ACCESSDENIED ») | Plage absente de `/etc/vbox/networks.conf` | 4 |
| Module `vboxdrv` absent après installation | Clé MOK non enrôlée (Secure Boot) | 3 |
| `mgmt0` ou `provider0` absente, IP manquantes | MAC non conservées à l’import, ou carte sur le mauvais `vboxnet` | 5 et 6 |
| Horizon 503 ou ne répond pas juste après le démarrage | Services encore en cours de démarrage | Attendre 10 à 15 min |
| `openstack ...` : `HTTP 500` sur l’authentification | Unité `keystone-mysql-router` en erreur | 10.1 |
| `juju status` : `mysql/0` en `maintenance`, routeurs `*-mysql-router` en `error`, `nova`, `neutron`, `placement` en `blocked` « healthcheck failed » | Démarrage : la base de données n’est pas encore prête | 10.1 (attendre `mysql`, puis `juju resolved`) |
| Une unité reste en `error` ou `blocked` | À diagnostiquer | 10.1 (« Si une unité reste en défaut ») |
| Lancement d’instance : `ERROR`, `HTTP 502` Glance dans les logs Nova | OSD Ceph arrêté | 10.2 |
| Volume en `error`, `cinder-volume` `down` dans `openstack volume service list` | Charms `microceph` et `cinder-volume` figés au démarrage | 10.2 (service des volumes) |
| Instance `ACTIVE` sans ping ni SSH, `Kernel panic` dans sa console | EPT actif | 10.3 |
| Instance : ping Internet OK, `apt`/HTTPS bloqués | MTU de `provider0` à 1500 | 10.4 |
| `juju status -m openstack-machines` : `not found` | Nom du modèle | `admin/openstack-machines` |
| Certificat Keycloak refusé dans le navigateur | CA non importée dans le navigateur | 9 |
| `503 … Keystone service is temporarily unavailable` partout, après une pause | Hôte mis en veille, ou Lab-Services figée | 8.0 ; Lab-Services : 13 (« Si une VM ne répond plus ») |
| Tout est très lent, charge énorme dans Lab-Sunbeam (`uptime`) | Hôte à court de mémoire | 1 (RAM) : fermer les applications, ou plus de RAM |
| Instantané bloqué (`livesnapshotting`) | Instantané pris VM allumée | 13 |
