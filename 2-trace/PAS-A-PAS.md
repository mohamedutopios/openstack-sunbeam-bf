# Pas à pas : montrer les échanges OpenStack pendant le scénario demo web

Ce pas à pas déroule le scénario `1-demo-openstack/demo-vm-openstack.md` (réseau, sous-réseau, routeur, groupe de sécurité, clé, VM Nginx, IP flottante) **en affichant en direct** les échanges entre composants OpenStack dans un navigateur. Pour le détail du traceur et les commandes d’observation manuelle : `2-trace/README.md`.

## Où se passe quoi

Tout se fait depuis le **PC Windows**, avec trois fenêtres :

| Fenêtre | Ce que c’est | Ce qu’on y fait |
|---|---|---|
| **A** | **PowerShell** sous Windows, dans le dossier du dépôt (`openstack-sunbeam`) | Copier les fichiers, créer la clé SSH, tester la VM à la fin |
| **B** | **Session SSH dans Lab-Sunbeam** : `ssh vagrant@192.168.56.10` | Démarrer le traceur, jouer le scénario |
| **C** | **Navigateur** Windows | Regarder la page du traceur : `http://192.168.56.10:8099/` |

```text
 PC Windows
 ├── A  PowerShell ──── scp / ssh-keygen / ping / ssh ubuntu@IP
 ├── B  ssh vagrant@192.168.56.10 ──► Lab-Sunbeam : traceur + commandes openstack
 └── C  Navigateur ──── http://192.168.56.10:8099/  (page du traceur, servie par Lab-Sunbeam)
```

**En formation :** projette **B et C côte à côte**. Les apprenants voient la commande à gauche et ses conséquences à droite.

Le traceur et le scénario tournent **dans Lab-Sunbeam**, pas sous Windows : Windows sert seulement à piloter (SSH) et à regarder (navigateur).

---

## Étape 0 : vérifier que le lab est prêt

Les deux VM tournent depuis au moins **15 minutes** (Lab-Services d’abord, puis Lab-Sunbeam).

**Fenêtre B** : ouvre la session SSH (mot de passe du compte `vagrant`) :

```powershell
ssh vagrant@192.168.56.10
```

Puis, dans Lab-Sunbeam :

```bash
juju status -m openstack | grep -w error
sudo ceph -s | grep -E "osd:|pgs:"
cat /sys/module/kvm_intel/parameters/ept
source ~/demo-openrc && openstack token issue -c expires -f value
```

| Contrôle | Attendu | Sinon |
|---|---|---|
| Unités Juju en erreur | Aucune ligne | `juju resolved -m openstack <unité>` pour chacune (étape 10.1 du guide apprenant) |
| Ceph | `1 osds: 1 up`, `289 active+clean` | Étape 10.2 du guide apprenant |
| EPT | `N` | Étape 10.3 du guide apprenant |
| Jeton | Une date d’expiration | Attendre quelques minutes, puis refaire 10.1 |

## Étape 1 : copier le traceur dans Lab-Sunbeam

**Fenêtre A** (PowerShell), dans le dossier du dépôt :

```powershell
cd C:\Users\<toi>\Documents\formation\openstack-sunbeam
scp -r .\2-trace vagrant@192.168.56.10:~/
```

Le dossier arrive dans `/home/vagrant/2-trace` de Lab-Sunbeam. À refaire seulement si les fichiers du dossier `2-trace` changent.

## Étape 2 : créer la clé SSH de la future VM

**Fenêtre A** :

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\web-key"
```

Laisse la phrase de passe vide pour la démo. Puis copie la clé **publique** dans Lab-Sunbeam :

```powershell
scp "$env:USERPROFILE\.ssh\web-key.pub" vagrant@192.168.56.10:~/web-key.pub
```

La clé privée reste sous Windows : c’est elle qui servira à `ssh ubuntu@…` à la fin.

## Étape 3 : démarrer le traceur

**Fenêtre B** (Lab-Sunbeam) :

```bash
bash ~/2-trace/start.sh
```

Attendu au bout d’une vingtaine de secondes :

```text
Traceur demarre : http://192.168.56.10:8099/
```

Le traceur tourne en arrière-plan : la fenêtre B reste libre pour le scénario.

## Étape 4 : ouvrir la page

**Fenêtre C** (navigateur Windows) : **http://192.168.56.10:8099/**

| Zone | Contenu |
|---|---|
| En haut à gauche | `● en direct` en vert : la page reçoit le flux |
| Bandeau | Filtres par canal (API REST, RPC, SQL, OVN, Services Nova, libvirt, Ceph), case **Masquer le bruit de fond** (laisse-la cochée), champ **Étape** et bouton **Marquer l’étape** |
| Gauche | Schéma des composants : un point circule à chaque échange |
| Droite | Fil des échanges, le plus récent en haut |

Au repos, le fil reste presque vide : les signaux de vie périodiques sont masqués. Décoche un instant **Masquer le bruit de fond** pour montrer qu’OpenStack échange en permanence (nova-compute ↔ conductor, Cinder ↔ MySQL…), puis recoche-la.

## Étape 5 : jouer le scénario

Deux façons, au choix.

### Mode guidé (recommandé)

**Fenêtre B** :

```bash
bash ~/2-trace/scenario-demo.sh
```

Le script affiche le titre de l’étape et attend **Entrée**. À chaque Entrée, il pose le marqueur d’étape dans la page, affiche chaque commande (`+ openstack …`) puis l’exécute, et laisse 8 à 15 secondes pour observer. Commente la page, puis Entrée pour l’étape suivante. Ctrl+C arrête le scénario à tout moment.

### Mode manuel

Pour chaque étape ci-dessous : écris son titre dans le champ **Étape** de la page (C), clique **Marquer l’étape**, puis tape les commandes dans B. Au préalable, dans B : `source ~/demo-openrc`.

---

## Étape 6 : ce qu’il faut montrer à chaque étape

Les séquences ci-dessous ont été relevées sur le lab, bruit de fond masqué. L’ordre exact peut varier de quelques lignes.

### 6.1 Flavor `m1.web` (compte admin)

```bash
source ~/admin-openrc
openstack flavor create m1.web --vcpus 1 --ram 1024 --disk 10 --public
```

**À voir dans la page :**

1. Client → Keystone : `POST /v3/auth/tokens -> 201` (le client obtient un jeton)
2. Client → Nova API : `POST /v2.1/flavors -> 200`
3. Nova API → Keystone : `GET /v3/auth/tokens -> 200 (validation du jeton)`
4. SQL : base `nova_api` : `INSERT`

**À expliquer :** chaque commande commence par l’obtention d’un jeton ; chaque service vérifie ensuite ce jeton auprès de Keystone. Un flavor n’est qu’une ligne en base : aucun RPC, aucun réseau.

**Vérifier :** `openstack flavor show m1.web`

### 6.2 Réseau `web-net`

```bash
source ~/demo-openrc
openstack network create web-net
```

**À voir :**

1. Client → Neutron : `POST /v2.0/networks -> 201`
2. Neutron → Keystone : validation du jeton
3. SQL : base `neutron_server` : `INSERT`
4. OVN : Neutron → OVN Northbound : `Logical_Switch : ajout reseau web-net`
5. OVN : ovn-northd → OVN Southbound : `Datapath_Binding : ajout`
6. OVN : `Logical_Switch_Port : ajout network:distributed port …` puis `Port_Binding … localport` (port du service metadata)

**À expliquer :** Neutron n’a pas d’agent qui « crée » le réseau : il écrit un **switch logique** dans OVN Northbound. `ovn-northd` le traduit en **datapath** dans Southbound, la base que lisent les hyperviseurs.

**Vérifier :**

```bash
sudo k8s kubectl -n openstack exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock show | grep -A2 web-net
```

### 6.3 Sous-réseau `web-subnet`

```bash
openstack subnet create web-subnet --network web-net --subnet-range 10.30.0.0/24 --gateway 10.30.0.1 --dns-nameserver 192.168.57.2
```

**À voir :**

1. Client → Neutron : `GET /v2.0/networks?name=web-net` (le client résout le nom en identifiant), puis `POST /v2.0/subnets -> 201`
2. SQL : `neutron_server` : `INSERT`
3. OVN NB : `DHCP_Options : ajout DHCP 10.30.0.0/24`
4. OVN NB/SB : le port metadata reçoit l’adresse `10.30.0.2`

**À expliquer :** le DHCP n’est pas un serveur dnsmasq : c’est une table OVN, servie directement par `ovn-controller` sur l’hyperviseur.

### 6.4 Routeur `web-router`

```bash
openstack router create web-router
openstack router set web-router --external-gateway external-network
openstack router add subnet web-router web-subnet
```

**À voir :**

1. `POST /v2.0/routers` → OVN NB `Logical_Router : ajout routeur web-router` → SB `Datapath_Binding`
2. `PUT …/update_external_gateways` → NB `Logical_Switch_Port network:router_gateway`, `Logical_Router_Port`, `Gateway_Chassis`, `Logical_Router_Static_Route`, `NAT snat`
3. `PUT …/add_router_interface` → NB `Logical_Router_Port` sur `web-net` → SB `Port_Binding`
4. Beaucoup de SQL `neutron_server` (`INSERT`, `UPDATE`)

**À expliquer :** le routeur est entièrement logique : un `Logical_Router` avec un port vers `external-network` (passerelle, SNAT de tout `10.30.0.0/24`) et un port vers `web-net`. `Gateway_Chassis` désigne l’hyperviseur qui porte la passerelle.

**Vérifier :**

```bash
sudo k8s kubectl -n openstack exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock lr-nat-list neutron-$(openstack router show web-router -f value -c id)
```

### 6.5 Groupe de sécurité `web-sg`

```bash
openstack security group create web-sg --description "SSH et HTTP depuis Windows"
openstack security group rule create web-sg --ingress --protocol icmp --remote-ip 192.168.57.1/32
openstack security group rule create web-sg --ingress --protocol tcp --dst-port 22 --remote-ip 192.168.57.1/32
openstack security group rule create web-sg --ingress --protocol tcp --dst-port 80 --remote-ip 192.168.57.1/32
```

**À voir :**

1. `POST /v2.0/security-groups` → OVN NB `Port_Group : ajout` + `ACL` par défaut (sortie autorisée en IPv4 et IPv6)
2. Chaque `POST /v2.0/security-group-rules` → une `ACL : ajout to-lport … ip4.src == 192.168.57.1/32 && tcp.dst == 22`

**À expliquer :** une règle de groupe de sécurité devient une **ACL OVN** appliquée à un **Port_Group**. Aucune VM n’utilise encore ce groupe : les règles existent mais ne filtrent rien.

**Vérifier :**

```bash
sudo k8s kubectl -n openstack exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock acl-list pg_$(openstack security group show web-sg -f value -c id | tr - _)
```

### 6.6 Paire de clés `web-key`

```bash
openstack keypair create web-key --public-key ~/web-key.pub
```

**À voir :** Client → Nova API `POST /v2.1/os-keypairs -> 201`, puis SQL `nova_api` : `INSERT`.

**À expliquer :** Nova stocke seulement la clé **publique** ; elle sera injectée dans la VM au démarrage par le service metadata.

### 6.7 Instance `web-vm`

Le mode guidé crée le fichier `~/nginx-cloud-init.yaml` (Nginx et sa page d’accueil). En mode manuel, crée-le comme indiqué dans `1-demo-openstack/demo-vm-openstack.md`, étape 9, puis :

```bash
openstack server create web-vm --image ubuntu --flavor m1.web --network web-net --security-group web-sg --key-name web-key --user-data ~/nginx-cloud-init.yaml --wait
```

C’est l’étape la plus riche (20 à 40 secondes). Clique sur la **pastille** de la ligne `POST /v2.1/servers` : le fil n’affiche plus que cette requête, de bout en bout.

**À voir, dans l’ordre :**

| # | Échange | Ce qui se passe |
|---|---|---|
| 1 | Client → Glance, Nova API, Neutron : `GET …?name=ubuntu`, `m1.web`, `web-net`, `web-sg` | Le client résout les noms en identifiants |
| 2 | Nova API → Neutron : `GET /networks`, `/security-groups`, `/quotas` | Nova API vérifie la demande |
| 3 | Client → Nova API : `POST /v2.1/servers -> 202` | Demande acceptée, traitement **asynchrone** |
| 4 | RPC : Nova API → RabbitMQ → file `scheduler` | Nova demande où placer la VM |
| 5 | Nova Scheduler → Placement : `GET /allocation_candidates`, `PUT /allocations/{id} -> 204` | Choix de l’hyperviseur et réservation des ressources |
| 6 | RPC : RabbitMQ → file `compute.sunbeam` | Ordre de construction envoyé à l’hyperviseur |
| 7 | nova-compute : `Claim successful on node sunbeam`, `Creating image(s)` | L’hyperviseur prend la VM en charge |
| 8 | nova-compute → Glance : `GET /v2/images/{id}` | Récupération de l’image (gardée en cache ensuite) |
| 9 | nova-compute → Neutron : `POST /v2.0/ports -> 201`, `PUT /ports/{id}` | Création et rattachement du port réseau |
| 10 | OVN NB : `Logical_Switch_Port : ajout port … 10.30.0.x`, `Port_Group : modification` | Le port est déclaré et mis dans le groupe de sécurité |
| 11 | OVN SB : `Port_Binding : ajout`, puis `requested_chassis` | `ovn-northd` publie le port pour l’hyperviseur |
| 12 | libvirt : `Defined Added` | La VM est définie dans KVM |
| 13 | ovn-controller : `Claiming lport …`, `Setting lport … ovn-installed in OVS`, `… up in Southbound` | L’hyperviseur branche le port dans `br-int` |
| 14 | ovn-controller → OVN SB : `Port_Binding : modification … chassis=…`, puis `up=True` | L’hyperviseur déclare le port actif |
| 15 | OVN NB : `Logical_Switch_Port : modification … up=True` | Neutron voit le port actif… |
| 16 | Neutron → Nova API : `POST /v2.1/os-server-external-events` | … et prévient Nova (`network-vif-plugged`) |
| 17 | libvirt : `Started Booted` ; nova-compute : `VM Started`, `Instance spawned successfully` | La VM démarre |
| 18 | Agent metadata : `Provisioning metadata for network …` | Le service metadata est prêt pour cloud-init |
| 19 | nova-compute : `Took … seconds to spawn the instance` | Fin |

**À expliquer :** `POST /servers` répond 202 en une seconde, mais la VM est construite ensuite par d’autres services, reliés par **RabbitMQ** (RPC) et par des **appels REST** entre services. Nova attend que Neutron confirme le branchement réseau (`network-vif-plugged`) avant de démarrer la VM.

**Vérifier :**

```bash
openstack server show web-vm -c status -c addresses
sudo openstack-hypervisor.virsh list --all
```

### 6.8 IP flottante

```bash
FIP=$(openstack floating ip create external-network -c floating_ip_address -f value)
openstack server add floating ip web-vm "$FIP"
echo "$FIP"
```

**À voir :**

1. Client → Neutron : `POST /v2.0/floatingips -> 201`
2. Client → Nova API : `GET /servers/detail?name=web-vm`, puis Client → Neutron `GET /ports?device_id=…` et `PUT /floatingips/{id}` (le client cherche le port de la VM et y associe l’IP)
3. OVN NB : `NAT : ajout dnat_and_snat 192.168.57.x <-> 10.30.0.x`, `Logical_Router : modification … nat=…`
4. OVN SB : `Port_Binding : modification … nat_addresses=…`

**À expliquer :** l’IP flottante est une simple règle **NAT 1:1** sur le routeur logique. Note l’adresse affichée.

---

## Étape 7 : tester la VM depuis Windows

Attends 1 à 3 minutes que cloud-init installe Nginx. **Fenêtre B**, pour suivre :

```bash
openstack console log show web-vm --lines 20
```

**Fenêtre A** (PowerShell), en remplaçant l’adresse :

```powershell
ping 192.168.57.1xx
ssh -i "$env:USERPROFILE\.ssh\web-key" ubuntu@192.168.57.1xx
```

**Fenêtre C** : nouvel onglet sur `http://192.168.57.1xx/` : page « Nginx sur OpenStack Sunbeam ».

**À montrer dans le traceur pendant ces tests :** rien ne se passe. Le ping, le SSH et le HTTP passent par le **plan de données** (Open vSwitch, programmé par OVN), sans aucun appel aux API, à RabbitMQ ou à MySQL. Le **plan de contrôle** n’intervient que pour créer ou modifier les ressources.

## Étape 8 : revenir sur une étape

- **Pastille d’une ligne** : n’affiche que la requête correspondante (bouton « Retirer le filtre » en haut du fil).
- **Clic sur un composant du schéma** : n’affiche que ses échanges (par exemple, *ovn-controller*).
- **Filtres par canal** : par exemple, seulement **OVN** pour revoir la traduction réseau.
- **Pause** fige le fil pendant une explication ; **Reprendre** affiche ce qui est arrivé entre-temps.

## Étape 9 : nettoyer et arrêter

**Fenêtre B** :

```bash
bash ~/2-trace/scenario-demo.sh nettoyer
```

Le script supprime l’instance, l’IP flottante, le routeur, le sous-réseau, le réseau, le groupe de sécurité, la clé et le flavor. Le traceur affiche aussi ces suppressions : c’est l’occasion de montrer le chemin inverse.

Puis :

```bash
bash ~/2-trace/stop.sh
```

**Avant un export des OVA**, supprime aussi le dossier : `rm -rf ~/2-trace ~/web-key.pub`.

---

## Dépannage

| Symptôme | Solution |
|---|---|
| `scenario-demo.sh` : « Cle publique absente » | Refaire l’étape 2 (copie de `web-key.pub`) |
| `scenario-demo.sh` : « Le traceur ne repond pas » | Refaire l’étape 3 |
| `scenario-demo.sh` : « Le reseau web-net existe deja » | Un scénario précédent n’a pas été nettoyé : `bash ~/2-trace/scenario-demo.sh nettoyer` |
| Page : « reconnexion… » | Traceur arrêté : `tail ~/2-trace/trace.log` dans B, puis `bash ~/2-trace/start.sh` |
| Page vide pendant une étape | Case « Masquer le bruit de fond » : la décocher ; vérifier les filtres par canal |
| Une commande `openstack` répond `HTTP 500` | Unités Juju en erreur : étape 0 |
| Instance en `ERROR` | `source ~/admin-openrc && openstack server show web-vm -c fault`, puis étapes 10.2 et 10.3 du guide apprenant |
| SSH ou page web injoignables, ping OK | cloud-init pas terminé, ou MTU de Lab-Services (étape 10.4 du guide apprenant) |
