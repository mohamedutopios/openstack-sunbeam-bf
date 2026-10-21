# Tracer les échanges entre composants OpenStack

Ce dossier contient un **traceur en temps réel** des échanges internes d’OpenStack (API REST, RPC RabbitMQ, SQL MySQL, OVN, hyperviseur, Ceph) et les **commandes manuelles** pour observer chacun de ces canaux. Il sert à montrer aux apprenants ce qui se passe « derrière » une commande `openstack`, en particulier pendant le scénario `1-demo-openstack/demo-vm-openstack.md`.

**Pour une démonstration, suis `PAS-A-PAS.md`** : où taper chaque commande, dans quel ordre, et ce qu’il faut montrer à chaque étape.

| Fichier | Rôle |
|---|---|
| `PAS-A-PAS.md` | Déroulé complet de la démonstration, étape par étape |
| `scenario-demo.sh` | Scénario demo web guidé (Entrée avant chaque étape, marqueurs posés automatiquement) et nettoyage (`nettoyer`) |
| `openstack-trace.py` | Collecteur : lit les sources et publie les événements (Python 3, bibliothèque standard) |
| `index.html` | Page temps réel : schéma animé et fil des échanges |
| `start.sh` / `stop.sh` | Démarrage en arrière-plan et arrêt propre |

**Lecture seule :** le traceur lit des logs, des compteurs et des bases ; il ne modifie aucune configuration. Les identifiants RabbitMQ et MySQL sont obtenus par des actions Juju au démarrage et ne sont jamais envoyés à la page. Le traceur n’a pas d’authentification : il n’écoute que sur le réseau du lab.

---

## 1. Démarrer le traceur

Depuis Windows, copie le dossier dans Lab-Sunbeam :

```powershell
scp -r .\2-trace vagrant@192.168.56.10:~/
```

Dans Lab-Sunbeam (`ssh vagrant@192.168.56.10`) :

```bash
bash ~/2-trace/start.sh
```

Le démarrage prend une vingtaine de secondes (lecture des identifiants par Juju). Ouvre ensuite, depuis Windows :

**http://192.168.56.10:8099/**

Pour arrêter :

```bash
bash ~/2-trace/stop.sh
```

Le journal du traceur est dans `~/2-trace/trace.log`. L’option `-v` (`bash ~/2-trace/start.sh -v`) y écrit aussi chaque événement.

**Avant d’exporter les OVA**, arrête le traceur et supprime le dossier : `bash ~/2-trace/stop.sh && rm -rf ~/2-trace`.

## 2. Utiliser la page

| Élément | Usage |
|---|---|
| Schéma | Un point coloré circule à chaque échange ; l’épaisseur des liens croît avec le nombre d’échanges. Clic sur un composant : filtre le fil sur ce composant |
| Fil des échanges | Plus récent en haut. Pastille colorée = identifiant de requête : un clic affiche toute la chaîne d’une même requête |
| Filtres par canal | API REST, RPC, SQL, OVN, services Nova, libvirt, Ceph |
| Masquer le bruit de fond | Coché par défaut : cache les tâches périodiques et signaux de vie (voir § 4) |
| Marquer l’étape | Insère un séparateur, par exemple « 2. Réseau web-net », avant de lancer la commande |
| Pause / Effacer | Fige l’affichage / repart de zéro |

**Méthode conseillée en formation :** écris l’étape dans « Marquer l’étape », valide, lance la commande, puis commente le fil et le schéma.

## 3. Ce que voit le traceur

| Canal | Source lue | Ce qui est affiché |
|---|---|---|
| **API REST** | `kubectl logs -f` des pods Keystone, Nova, Neutron, Glance, Placement, Cinder | Appelant → service, méthode, URL, code HTTP. L’appelant vient du *User-Agent* (`nova-scheduler keystoneauth1…`, `openstacksdk…`) ou de l’adresse IP |
| **Validation des jetons** | Lignes `GET /v3/auth/tokens` de Keystone | Chaque service vérifie auprès de Keystone le jeton reçu du client |
| **RPC** | API de gestion RabbitMQ (`192.168.56.211:15672`) | Qui publie (nom du processus oslo.messaging) et sur quelle file (`conductor`, `scheduler`, `compute.sunbeam`, `q-plugin`…) |
| **SQL** | `performance_schema` de MySQL | Nombre de `SELECT`, `INSERT`, `UPDATE`, `DELETE` par base (`neutron_server`, `nova`, `nova_api`, `placement_api`, `keystone`…) |
| **OVN Northbound** | `ovsdb-client monitor` | Traduction des objets Neutron : `Logical_Switch`, `Logical_Router`, `Logical_Switch_Port`, `ACL`, `Port_Group`, `NAT`, `DHCP_Options` |
| **OVN Southbound** | `ovsdb-client monitor` | Écritures d’`ovn-northd` (`Datapath_Binding`, `Port_Binding`) et d’`ovn-controller` (`chassis` et `up` d’un `Port_Binding`, quand l’hyperviseur prend le port en charge) |
| **ovn-controller** | Fichier `/var/snap/openstack-hypervisor/common/log/ovn/ovn-controller.log` | `Claiming lport`, `ovn-installed in OVS`, `up in Southbound` |
| **Services Nova** | Journaux de `nova-compute`, `nova-scheduler`, `nova-conductor`, agent metadata | Messages liés à une requête : `Claim successful`, `Creating image(s)`, `Took … seconds to spawn` |
| **libvirt** | `virsh event --all --loop` | Cycle de vie de la VM : `Defined`, `Started`, `Paused`, `Resumed` |
| **Ceph** | `ceph osd pool stats` | Lectures et écritures par pool (`glance`, `cinder-volume-ceph`) |

### Corrélation par identifiant de requête

Chaque appel API reçoit un identifiant `req-…`. Quand un service en appelle un autre, il transmet l’identifiant d’origine (*global request id*). Exemple observé pour `openstack server create` : la même pastille relie le `POST /servers` du client, les appels du Scheduler à Placement, le message RPC vers `nova-compute`, le `POST /ports` vers Neutron et les messages `Claim successful`, puis `Took 16.59 seconds to spawn`.

### Limites

- **RPC et SQL sont des compteurs**, relevés toutes les 1 à 2 secondes : on voit qui publie et combien de requêtes, pas le contenu des messages ni le texte SQL.
- Le **bruit de fond** est classé automatiquement : un échange sans identifiant de requête est rattaché au client s’il survient dans les 8 secondes d’une activité du client et dépasse le volume habituel de sa source au repos. Décoche « Masquer le bruit de fond » pour tout voir.
- Les **lectures Ceph** n’apparaissent qu’au premier lancement d’une image : ensuite, `nova-compute` la garde en cache local (`_base`).

## 4. Ce qu’on observe pendant le scénario demo web

Séquences relevées sur le lab en déroulant `1-demo-openstack/demo-vm-openstack.md`, bruit de fond masqué.

| Étape | Enchaînement observé |
|---|---|
| **Flavor** (admin) | Client → Keystone `POST /auth/tokens` → Client → Nova API `POST /flavors` → Nova API valide le jeton → base `nova_api` : `INSERT` |
| **Réseau** | Client → Neutron `POST /networks` → validation du jeton → `neutron_server` : `INSERT` → OVN NB `Logical_Switch` « web-net » → OVN SB `Datapath_Binding` → port `network:distributed` (metadata) en NB, `Port_Binding localport` en SB |
| **Sous-réseau** | Client → Neutron `POST /subnets` → `neutron_server` : `INSERT` → OVN NB `DHCP_Options 10.30.0.0/24` → port metadata mis à jour avec `10.30.0.2` |
| **Routeur** | `POST /routers` → NB `Logical_Router` → `PUT …/update_external_gateways` → NB `Logical_Router_Port`, `Gateway_Chassis`, `Logical_Router_Static_Route`, `NAT snat` → SB `Datapath_Binding`, `Port_Binding` → `add_router_interface` : port de routeur sur `web-net` |
| **Groupe de sécurité** | `POST /security-groups` → NB `Port_Group` + `ACL` par défaut → chaque `POST /security-group-rules` → une `ACL` (`ip4.src == 192.168.57.1/32 && tcp.dst == 22`…) |
| **Paire de clés** | Client → Nova API `POST /os-keypairs` → base `nova_api` : `INSERT` |
| **Instance** | Client → Glance (image), Nova API (flavor), Neutron (réseau, groupe) → `POST /servers` (202) → Nova API publie sur RabbitMQ → **Scheduler** → Placement `GET /allocation_candidates`, `PUT /allocations` → file `compute.sunbeam` → **nova-compute** : `Claim successful`, `Creating image(s)` → Glance `GET /images/{id}` → Neutron `POST /ports`, `PUT /ports` → NB `Logical_Switch_Port`, `Port_Group` → SB `Port_Binding requested_chassis` → libvirt `Defined` → **ovn-controller** `Claiming lport`, `ovn-installed in OVS`, `up in Southbound` → SB `chassis`, `up=True` → NB `up=True` → Neutron → Nova API `POST /os-server-external-events` (`network-vif-plugged`) → libvirt `Started` → agent metadata `Provisioning metadata` → `Took … seconds to spawn` |
| **IP flottante** | `POST /floatingips` → `PUT /floatingips/{id}` (association) → NB `NAT dnat_and_snat 192.168.57.x <-> 10.30.0.x` → SB `Port_Binding nat_addresses` |

---

## 5. Commandes manuelles pour observer chaque canal

Toutes les commandes se lancent dans **Lab-Sunbeam**. Pour alléger :

```bash
K="sudo k8s kubectl -n openstack"
```

### 5.1 Le client : appels REST et identifiants de requête

```bash
source ~/demo-openrc
openstack --debug network show web-net 2>&1 | grep -E "^REQ: curl|^RESP: \[|X-Openstack-Request-Id"
```

On y voit chaque requête HTTP (`REQ: curl …`), son code (`RESP: [200]`) et son identifiant (`X-Openstack-Request-Id: req-…`). La première requête va toujours à Keystone pour obtenir un jeton.

### 5.2 Les API : logs des pods

| Service | Commande |
|---|---|
| Keystone | `$K logs -f keystone-0 -c keystone` |
| Nova API | `$K logs -f nova-0 -c nova-api` |
| Nova Scheduler | `$K logs -f nova-0 -c nova-scheduler` |
| Nova Conductor | `$K logs -f nova-0 -c nova-conductor` |
| Neutron | `$K logs -f neutron-0 -c neutron-server` |
| Glance | `$K logs -f glance-0 -c glance-api` |
| Placement | `$K logs -f placement-0 -c placement-api` |

Suivre une requête dans tous les services (remplace l’identifiant) :

```bash
REQ=req-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
for pc in nova-0/nova-api nova-0/nova-scheduler nova-0/nova-conductor neutron-0/neutron-server placement-0/placement-api; do
  echo "== $pc"; $K logs ${pc%/*} -c ${pc#*/} --since=15m | grep "$REQ" | cut -c1-200
done
sudo journalctl -u snap.openstack-hypervisor.nova-compute --since "-15min" | grep "$REQ" | cut -c1-200
```

### 5.3 RPC : RabbitMQ

Files et consommateurs :

```bash
$K exec rabbitmq-0 -c rabbitmq -- rabbitmqctl list_queues -p openstack name messages consumers | grep -E "^(conductor|scheduler|compute\.|q-plugin)\s"
```

Processus connectés (nom annoncé par oslo.messaging), via l’API de gestion :

```bash
RMQ=$(juju run -m openstack rabbitmq/0 get-operator-info --format=json 2>/dev/null | python3 -c "import sys,json; r=list(json.load(sys.stdin).values())[0]['results']; print(r['operator-user']+':'+r['operator-password'])")
curl -s -u "$RMQ" "http://192.168.56.211:15672/api/connections?columns=client_properties.connection_name" | python3 -c "import sys,json,collections; print(collections.Counter(c['client_properties']['connection_name'].split(':')[0] for c in json.load(sys.stdin)))"
```

### 5.4 SQL : MySQL

```bash
MYSQL_PWD=$(juju run -m openstack mysql/0 get-password --format=json 2>/dev/null | python3 -c "import sys,json; print(list(json.load(sys.stdin).values())[0]['results']['password'])")
```

Requêtes par base depuis le démarrage :

```bash
$K exec mysql-0 -c mysql -- env MYSQL_PWD="$MYSQL_PWD" mysql -uroot -e "SELECT SCHEMA_NAME, SUM(COUNT_STAR) FROM performance_schema.events_statements_summary_by_digest WHERE SCHEMA_NAME IS NOT NULL GROUP BY 1 ORDER BY 2 DESC"
```

Ce que chaque service a écrit (à relancer après chaque étape) :

```bash
$K exec mysql-0 -c mysql -- env MYSQL_PWD="$MYSQL_PWD" mysql -uroot -e "SELECT name, status FROM neutron_server.networks; SELECT hostname, vm_state, task_state FROM nova.instances WHERE deleted=0;"
```

### 5.5 OVN

État logique (Northbound) : réseaux, ports, routeurs :

```bash
$K exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock show
```

Règles NAT d’un routeur (IP flottante et SNAT) :

```bash
RID=$(openstack router show web-router -f value -c id)
$K exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock lr-nat-list neutron-$RID
```

Règles des groupes de sécurité :

```bash
$K exec ovn-central-0 -c ovn-nb-db-server -- ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock acl-list pg_$(openstack security group show web-sg -f value -c id | tr - _)
```

État physique (Southbound) : hyperviseurs et ports qui y sont rattachés :

```bash
$K exec ovn-central-0 -c ovn-sb-db-server -- ovn-sbctl --db=unix:/var/run/ovn/ovnsb_db.sock show
```

Suivre les changements en direct (Ctrl+C pour arrêter) :

```bash
$K exec ovn-central-0 -c ovn-nb-db-server -- ovsdb-client monitor unix:/var/run/ovn/ovnnb_db.sock OVN_Northbound Logical_Switch_Port name,up,addresses
```

### 5.6 Hyperviseur

```bash
sudo journalctl -fu snap.openstack-hypervisor.nova-compute | grep --line-buffered "\[instance:"
```

```bash
sudo tail -f /var/snap/openstack-hypervisor/common/log/ovn/ovn-controller.log | grep --line-buffered binding
```

```bash
sudo openstack-hypervisor.ovs-vsctl show
sudo openstack-hypervisor.virsh list --all
sudo openstack-hypervisor.virsh event --all --loop
```

`ovs-vsctl show` montre `br-int` (ports des instances, `tap…`) et `br-ex` (sortie vers `provider0`).

### 5.7 Ceph

```bash
sudo ceph -s
sudo ceph osd pool stats glance
sudo rbd ls -p glance
```

`rbd ls -p glance` liste les images Glance stockées dans Ceph : l’identifiant affiché est celui de `openstack image list`.

---

## 6. Dépannage du traceur

| Symptôme | Vérification |
|---|---|
| La page ne s’ouvre pas | `bash ~/2-trace/start.sh` a-t-il affiché « Traceur demarre » ? `ss -ltn \| grep 8099` dans Lab-Sunbeam |
| « reconnexion… » en haut de la page | Le traceur s’est arrêté : `tail ~/2-trace/trace.log`, puis `bash ~/2-trace/start.sh` |
| Aucun événement RPC ni SQL | Unités Juju en erreur ou OpenStack pas encore prêt après démarrage (étape 10.1 du guide apprenant) |
| Une source se tait | `grep interrompu ~/2-trace/trace.log` : la source est relancée toutes les 5 secondes |
