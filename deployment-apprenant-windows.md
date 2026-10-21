# Déploiement apprenant : lab OpenStack Sunbeam sous Windows (VirtualBox)

Ce pas à pas installe le lab à partir des deux OVA fournies, `Services-base.ova` et `Sunbeam-base.ova`, sur un **PC Windows 10/11 avec VirtualBox**.

**État validé :** OpenStack fonctionne avec le compte `demo`, une instance Ubuntu avec Nginx a été lancée et jointe en SSH et en HTTP depuis Windows (voir `1-demo-openstack/demo-vm-openstack.md`). Le SSO Keycloak reste à configurer.

Variante pour un hôte Linux : `deployment-apprenant-ubuntu.md`.

## Vue d’ensemble

| VM | Rôle | Carte 1 | Carte 2 : gestion `192.168.56.0/24` | Carte 3 : instances `192.168.57.0/24` |
|---|---|---|---|---|
| **Lab-Services** | Keycloak, DNS (dnsmasq), passerelle des instances | NAT | `mgmt0` = `192.168.56.20` | `provider0` = `192.168.57.2` (MTU 1442) |
| **Lab-Sunbeam** | OpenStack Sunbeam, Ceph, hyperviseur Nova | NAT | `mgmt0` = `192.168.56.10` + API `.201`, `.202`, `.203` | `provider0` sans IP (pont Open vSwitch) |
| **Windows** | Navigateur, SSH, CLI | — | `192.168.56.1` | `192.168.57.1` |

| Nom | Adresse | Service |
|---|---|---|
| `sso.lab.test` | `192.168.56.20` | Keycloak `https://sso.lab.test:8443` |
| `cloud.lab.test` | `192.168.56.201` | Horizon et API publiques |
| `internal.lab.test` | `192.168.56.202` | API internes |
| `rgw.lab.test` | `192.168.56.203` | Stockage objet Ceph |

Les IP flottantes des instances sont prises dans `192.168.57.100–199`. Ces réseaux ne sont joignables que depuis le PC, **pas depuis Internet**.

---

# Partie A : formateur, préparer et exporter les OVA

## A1. Vérifier les corrections dans les VM

Ces réglages sont dans les disques des VM : ils voyagent avec les OVA. Vérifie-les avant chaque export.

Dans **Lab-Sunbeam** :

```bash
cat /etc/modprobe.d/kvm-intel-ept.conf
sudo ls -l /var/snap/microceph/common/data/osd/ceph-1/block
sudo ceph -s | grep -E "osd:|pgs:"
juju status -m openstack | grep -w error
```

| Contrôle | Attendu |
|---|---|
| EPT | `options kvm_intel ept=0` |
| Lien de l’OSD Ceph | `-> /dev/disk/by-path/pci-0000:00:1f.2-ata-2` (et non un chemin `by-id`, qui change à chaque import) |
| Ceph | `1 osds: 1 up` et `289 active+clean` |
| Unités Juju | Aucune ligne |

Dans **Lab-Services** :

```bash
sudo grep -A5 "provider0:" /etc/netplan/60-lab.yaml
ip link show provider0 | grep -o "mtu [0-9]*"
```

Le netplan doit contenir `mtu: 1442` et l’interface doit être en `mtu 1442`.

## A2. Repartir d’un cloud propre

Supprime les ressources créées pendant tes tests (instances, IP flottantes, réseaux, routeurs, groupes de sécurité, clés, flavors de démo). Dans Lab-Sunbeam :

```bash
source ~/demo-openrc
openstack server list
openstack floating ip list
openstack network list
openstack router list
openstack keypair list
```

L’état livré contient seulement `demo-network`, `external-network`, `demo-router`, le groupe de sécurité `default`, l’image `ubuntu` et les flavors `m1.*`.

## A3. Comptes

Dans la console de **chaque VM**, définis un mot de passe connu pour le compte Linux `vagrant` :

```bash
sudo passwd vagrant
```

Les apprenants l’utiliseront dans la console VirtualBox ou en SSH par mot de passe (`ssh vagrant@192.168.56.20`, `ssh vagrant@192.168.56.10`). `vagrant ssh` ne fonctionnera pas chez eux : la clé Vagrant reste sur ton PC.

## A4. Arrêter et exporter

Arrête **Lab-Sunbeam d’abord**, attends son arrêt complet, puis Lab-Services :

```bash
sudo shutdown -h now
```

Exporte chaque VM (**Fichier → Exporter un appareil virtuel**) en conservant **toutes** les adresses MAC (politique MAC : « Inclure toutes les adresses MAC des cartes réseau »). Les interfaces `mgmt0` et `provider0` sont reconnues par leur MAC.

## A5. Dossier à distribuer

```text
Lab-OpenStack/
  Services-base.ova
  Sunbeam-base.ova
  Configurer-Lab-Sunbeam.ps1
  ca.crt
  1-demo-openstack/demo-vm-openstack.md
```

Le fichier `ca.crt` doit correspondre aux certificats présents dans **ces OVA**. Joins une fiche d’accès :

| Accès | Informations à transmettre |
|---|---|
| Console et SSH des deux VM | `vagrant` et mot de passe défini |
| Horizon | Domaine `users`, utilisateur `demo`, mot de passe |
| Administration Keycloak | `kcadmin` et mot de passe du lab |

**Avant de distribuer à toute la classe, rejoue cette partie B sur un autre PC jusqu’au test `1-demo-openstack/demo-vm-openstack.md`.**

---

# Partie B : apprenant, installer le lab

## 1. Vérifier le PC

| Ressource | Valeur |
|---|---|
| Architecture | PC **Intel** x86-64 (processeur AMD : prévenir le formateur, voir étape 10.3) |
| RAM | 32 Go minimum |
| Processeurs | 12 threads ou plus conseillés (les VM en utilisent 10) |
| VM Sunbeam | 20 Go de RAM, 8 vCPU |
| VM Services | 3 Go de RAM, 2 vCPU |
| Stockage | SSD, environ 300 Go libres |
| Virtualisation | Intel VT-x activé dans l’UEFI/BIOS |

Tu n’as **pas besoin d’installer Vagrant ou Docker dans Windows** : les logiciels du lab sont dans les VM.

## 2. Désactiver l’hyperviseur Windows

**Prérequis bloquant.** Si l’hyperviseur Windows est actif (Hyper-V, VBS, intégrité de la mémoire, WSL2…), VirtualBox fonctionne au-dessus d’Hyper-V en mode NEM : Sunbeam devient extrêmement lent, les services OpenStack ne démarrent pas et `/dev/kvm` est absent. **C’est tout le lab qui ne démarre pas.**

### 2.1 Vérifier

Dans PowerShell :

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

Si le résultat est `False`, passe à l’étape 3. Si c’est `True`, continue (sur un **PC personnel dédié au lab**).

### 2.2 Désactiver l’intégrité de la mémoire

**Sécurité Windows → Sécurité de l’appareil → Isolation du noyau** : désactive **Intégrité de la mémoire**. Ne redémarre pas encore.

### 2.3 Désactiver VBS, l’hyperviseur et les fonctionnalités Hyper-V

Dans PowerShell **en administrateur** :

```powershell
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
```

```powershell
bcdedit /set hypervisorlaunchtype off
```

```powershell
bcdedit /enum "{current}" | findstr /i hypervisor
```

La dernière commande doit afficher `hypervisorlaunchtype Off`. Liste ensuite les fonctionnalités qui utilisent l’hyperviseur :

```powershell
dism /online /get-features /format:table | findstr /i "Hyper-V VirtualMachinePlatform HypervisorPlatform Subsystem-Linux Containers DisposableClientVM"
```

Désactive chaque fonctionnalité marquée **Activé**, par exemple :

```powershell
dism /online /disable-feature /featurename:Microsoft-Hyper-V-All /norestart
```

```powershell
dism /online /disable-feature /featurename:VirtualMachinePlatform /norestart
```

```powershell
dism /online /disable-feature /featurename:HypervisorPlatform /norestart
```

**Redémarre Windows.** Ces réglages ne prennent effet qu’après le redémarrage. Ils rendent WSL2, Docker Desktop, Windows Sandbox et Hyper-V inutilisables. Pour revenir en arrière après la formation : `bcdedit /set hypervisorlaunchtype auto`, réactive les fonctionnalités (`dism /online /enable-feature /featurename:<nom>`) et l’intégrité de la mémoire, puis redémarre.

### 2.4 Contrôler après le redémarrage

Les deux commandes doivent afficher `False` puis `0` :

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

```powershell
(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus
```

Si `HypervisorPresent` reste à `True`, une stratégie d’entreprise (GPO, Intune) impose probablement VBS : fais valider le PC par son administrateur.

## 3. Installer VirtualBox

1. Télécharge VirtualBox pour **Windows hosts** depuis le [site officiel](https://www.virtualbox.org/wiki/Downloads), de préférence **la version validée par le formateur** (7.2.x).
2. Lance l’installation, conserve les composants réseau et accepte les pilotes Oracle.
3. Redémarre Windows si demandé.

## 4. Créer les deux réseaux Host-only

**Fichier → Outils → Gestionnaire de réseau**, onglet **Réseaux privés hôte**. Clique deux fois sur **Créer** et configure :

| Paramètre | Réseau de gestion | Réseau des instances |
|---|---|---|
| Adresse IPv4 de l’adaptateur | `192.168.56.1` | `192.168.57.1` |
| Masque | `255.255.255.0` | `255.255.255.0` |
| Serveur DHCP (onglet dédié) | **Décoché** | **Décoché** |

Note le nom de chaque adaptateur, par exemple `VirtualBox Host-Only Ethernet Adapter` et `VirtualBox Host-Only Ethernet Adapter #2`. **Ne te fie pas au numéro `#2` : repère chaque adaptateur par son adresse IP.** Ne configure aucune passerelle sur ces adaptateurs : le PC garde sa connexion Internet habituelle.

## 5. Importer les deux OVA

**Fichier → Importer un appareil virtuel** :

1. Sélectionne `Services-base.ova` et nomme la VM **`Lab-Services`**.
2. Choisis un dossier de stockage sur le SSD.
3. Politique MAC : **Inclure toutes les adresses MAC des cartes réseau**. N’utilise pas « uniquement les cartes NAT » : dans les VM, netplan reconnaît les cartes 2 et 3 par leur MAC.
4. Lance l’import.
5. Recommence avec `Sunbeam-base.ova`, nommée **`Lab-Sunbeam`**.

**Ne démarre pas encore les VM.**

## 6. Brancher les cartes réseau

Pour **chacune des deux VM** : **Configuration → Réseau**.

| Carte | Mode | Réseau |
|---|---|---|
| Adaptateur 1 | **NAT** | — |
| Adaptateur 2 | **Réseau privé hôte** | L’adaptateur Windows `192.168.56.1` |
| Adaptateur 3 | **Réseau privé hôte** | L’adaptateur Windows `192.168.57.1` |

Sur les trois cartes : **Activer l’interface réseau** et **Câble branché** cochés ; garde le type de carte et l’adresse MAC importés. Sur les adaptateurs **2 et 3**, ouvre **Avancé** et règle **Mode promiscuité : Tout autoriser** (les IP des API OpenStack et des instances Nova utilisent d’autres MAC que celles des cartes).

## 7. Activer la virtualisation imbriquée de Lab-Sunbeam

VM **Lab-Sunbeam éteinte** : **Configuration → Système**.

1. Onglet **Carte mère** : vérifie **20480 Mo** de mémoire vive.
2. Onglet **Processeur** : vérifie **8** processeurs et coche **Activer VT-x/AMD-V imbriqué**.

Si la case est grisée, l’hyperviseur Windows est encore actif : reprends l’étape 2.

## 8. Démarrer les VM

### 8.1 Lab-Services d’abord

Démarre **Lab-Services**, puis connecte-toi dans sa console ou depuis PowerShell :

```powershell
ssh vagrant@192.168.56.20
```

```bash
ip -br addr
ip link show provider0 | grep -o "mtu [0-9]*"
systemctl is-active docker dnsmasq
sudo docker ps --format "{{.Names}} {{.Status}}"
```

| Attendu | |
|---|---|
| `mgmt0` | `192.168.56.20/24` |
| `provider0` | `192.168.57.2/24`, `mtu 1442` |
| Services | `active` et `active` |
| Conteneurs | `keycloak-keycloak-1` et `keycloak-postgres-1` démarrés |

### 8.2 Lab-Sunbeam ensuite

Sélectionne **Lab-Sunbeam** et clique sur **Démarrer**. Dès qu’elle a démarré, vérifie que VirtualBox utilise bien VT-x et pas Hyper-V : clic droit sur **Lab-Sunbeam → Afficher le journal**, onglet `VBox.log`, puis recherche `HMR3Init` (champ de recherche en bas de la fenêtre).

Une tortue verte dans la barre d’état de la fenêtre de la VM signale aussi le mode Hyper-V (NEM).

| Résultat | Signification |
|---|---|
| `VT-x w/ nested paging and unrestricted guest execution hw support`, et plus bas `VT-x nested-guest init` | ✅ Configuration correcte |
| `Attempting fall back to NEM: VT-x is not available` | ❌ L’hyperviseur Windows est actif : éteins les VM et reprends l’étape 2 |

Puis dans la VM :

```powershell
ssh vagrant@192.168.56.10
```

```bash
ip -br addr show mgmt0
ip -br addr show provider0
ls -l /dev/kvm
```

`mgmt0` porte `192.168.56.10/24` ; `provider0` est `UP` **sans adresse IP** (pont Open vSwitch : ne lui en ajoute pas) ; `/dev/kvm` existe.

**Après chaque démarrage, Sunbeam a besoin de 10 à 15 minutes** pour relancer Kubernetes et les services OpenStack. Pendant ce temps, Horizon peut ne pas répondre ou renvoyer une erreur 503 : attends avant de diagnostiquer.

## 9. Configurer les noms et le certificat dans Windows

Place les fichiers fournis ensemble, par exemple :

```text
C:\Lab-OpenStack\Configurer-Lab-Sunbeam.ps1
C:\Lab-OpenStack\ca.crt
```

Dans PowerShell **en administrateur** :

```powershell
cd C:\Lab-OpenStack
Unblock-File .\Configurer-Lab-Sunbeam.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Configurer-Lab-Sunbeam.ps1
```

Le script ajoute les quatre noms du lab au fichier `hosts` (avec sauvegarde) et importe la CA du lab pour tous les utilisateurs du PC.

| Message du script | Signification |
|---|---|
| `OK : <nom> -> <adresse>` pour les quatre noms | ✅ Fichier `hosts` correct |
| `OK : Keycloak, port 8443 accessible.` | ✅ Lab-Services joignable |
| `AVERTISSEMENT : OpenStack HTTPS inaccessible` | **Attendu** : Horizon est encore en HTTP dans ces OVA |

Vérifie plutôt Horizon en HTTP :

```powershell
Test-NetConnection cloud.lab.test -Port 80
Test-NetConnection sso.lab.test -Port 8443
```

Les deux doivent afficher `TcpTestSucceeded : True`.

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
- tout reste figé, charge très élevée (`uptime`) : vérifier l’hyperviseur Windows (étape 2) et la virtualisation imbriquée (étape 7).

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

Attendu : `N` (fixé par `/etc/modprobe.d/kvm-intel-ept.conf`). Avec EPT actif, KVM dans VirtualBox corrompt la mémoire des instances, qui plantent au démarrage (`Kernel panic`, `BUG: kernel NULL pointer dereference` dans `openstack console log show`).

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

## 11. Se connecter depuis Windows

Horizon : [http://cloud.lab.test/openstack-horizon](http://cloud.lab.test/openstack-horizon)

| Champ | Valeur |
|---|---|
| Domaine | `users` |
| Utilisateur | `demo` |
| Mot de passe | Celui transmis par le formateur |

Keycloak : [https://sso.lab.test:8443/admin/](https://sso.lab.test:8443/admin/)

La connexion à Horizon utilise le compte local OpenStack : **la présence de Keycloak ne signifie pas que la fédération SSO est configurée.**

## 12. Premier test : une instance Nginx

Suis `1-demo-openstack/demo-vm-openstack.md` : réseau, routeur, groupe de sécurité, clé SSH, VM Ubuntu avec Nginx, IP flottante, puis SSH et navigateur depuis Windows. C’est le test qui valide le calcul, Ceph et le réseau des instances, au-delà d’Horizon.

## 13. Arrêter et conserver le lab

En fin de séance :

1. Arrête les instances Nova (Horizon ou `openstack server stop`).
2. Dans **Lab-Sunbeam** : `sudo shutdown -h now`, et attends l’arrêt complet.
3. Dans **Lab-Services** : `sudo shutdown -h now`.

Pour reprendre : **Services d’abord, Sunbeam ensuite**, puis attends 10 à 15 minutes et refais l’étape 10.1.

Après la première validation complète, crée un snapshot des **deux VM éteintes**, par exemple `Base-importee-validee`, et restaure les deux ensemble si besoin.

---

## Dépannage rapide

| Symptôme | Cause probable | Étape |
|---|---|---|
| Sunbeam très lente, load énorme, pods en `Unknown`, `/dev/kvm` absent | Hyperviseur Windows actif (mode NEM) | 2 et 8.2 |
| `mgmt0` ou `provider0` absente, IP manquantes | MAC non conservées à l’import, ou carte sur le mauvais adaptateur | 5 et 6 |
| Horizon 503 ou ne répond pas juste après le démarrage | Services encore en cours de démarrage | Attendre 10 à 15 min |
| `openstack ...` : `HTTP 500` sur l’authentification | Unité `keystone-mysql-router` en erreur | 10.1 |
| `juju status` : `mysql/0` en `maintenance`, routeurs `*-mysql-router` en `error`, `nova`, `neutron`, `placement` en `blocked` « healthcheck failed » | Démarrage : la base de données n’est pas encore prête | 10.1 (attendre `mysql`, puis `juju resolved`) |
| Une unité reste en `error` ou `blocked` | À diagnostiquer | 10.1 (« Si une unité reste en défaut ») |
| Lancement d’instance : `ERROR`, `HTTP 502` Glance dans les logs Nova | OSD Ceph arrêté | 10.2 |
| Volume en `error`, `cinder-volume` `down` dans `openstack volume service list` | Charms `microceph` et `cinder-volume` figés au démarrage | 10.2 (service des volumes) |
| Instance `ACTIVE` sans ping ni SSH, `Kernel panic` dans sa console | EPT actif | 10.3 |
| Instance : ping Internet OK, `apt`/HTTPS bloqués | MTU de `provider0` à 1500 | 10.4 |
| `juju status -m openstack-machines` : `not found` | Nom du modèle | `admin/openstack-machines` |
| Avertissement HTTPS 443 du script Windows | Horizon encore en HTTP | Normal |
