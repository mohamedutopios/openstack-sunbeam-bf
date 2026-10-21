# Le client OpenStack, expliqué pas à pas : informations, débogage, diagnostic

Ce guide montre comment utiliser la commande `openstack` pour **inventorier** un cloud, **comprendre** ce que fait une commande, et **diagnostiquer** une VM, un volume ou un refus. Il est construit autour de **six démos** jouables sur le lab. Pour chaque commande, tu trouveras toujours :

| Rubrique | Ce qu’elle contient |
|---|---|
| **À quoi ça sert** | La question à laquelle la commande répond, et quand la lancer |
| **La commande, mot par mot** | Le rôle de chaque mot et de chaque option |
| **Ce que tu vois** | La sortie **réelle**, relevée sur le lab |
| **Comment le lire** | Colonne par colonne, valeur par valeur |
| **Si tu vois autre chose** | Ce que signifie un résultat différent, et quoi faire |

Les commandes marquées ✅ ont été exécutées sur le lab : client `openstack` 7.5.0, OpenStack 2024.1. Les sorties datent du 16 et du 17 octobre ; elles sont parfois abrégées (`…`). Les démos qui créent des ressources les suppriment à la fin.

**Où taper les commandes :** dans **Lab-Sunbeam**, avec le compte `vagrant`. Depuis Windows :

```powershell
ssh vagrant@192.168.56.10
```

**Avec quel compte :** la commande `openstack` lit son identité dans des variables. Deux fichiers les chargent :

```bash
source ~/admin-openrc     # l’administrateur, projet admin : voit et gère tout le cloud
source ~/demo-openrc      # l’utilisateur demo, projet demo : un utilisateur ordinaire
```

`source` charge les variables `OS_*` du fichier dans la session courante ; elles restent valables jusqu’au prochain `source` ou à la fermeture de la session. Le contenu de ces variables est expliqué dans le guide `3-sunbeam-cli/`, démo 2.

**Où se situe ce guide :** `sunbeam` installe et fait évoluer le cloud (guide `3-sunbeam-cli/`) ; `juju` en surveille les services (guide `4-juju-cli/`) ; `openstack` le **consomme** et l’interroge, comme le ferait un utilisateur ou une application.

---

## 1. Syntaxe générale

```text
openstack [options globales] <objet> <action> [nom ou ID] [options] [options de sortie]
```

Exemple : `openstack --debug server show lab-diag -c status -f json`

| Morceau | Ici | Rôle |
|---|---|---|
| `[options globales]` | `--debug` | Modifient le comportement du client lui-même ; toujours **avant** l’objet |
| `<objet>` | `server` | Ce qu’on manipule : `server` (VM), `network`, `volume`, `image`, `flavor`, `project`, `user`… |
| `<action>` | `show` | Ce qu’on fait : `list`, `show`, `create`, `set`, `delete` |
| `[nom ou ID]` | `lab-diag` | Quel objet. Un nom ne marche que s’il est **unique dans ta portée** ; un identifiant marche toujours |
| `[options de sortie]` | `-c status -f json` | Quelles colonnes, quel format |

| Famille | Option | Effet |
|---|---|---|
| Aide | `openstack help server create` | L’aide d’une commande, avec toutes ses options |
| Identité | `--os-cloud NOM` | Utiliser un profil d’un fichier `clouds.yaml` au lieu des variables |
| Débogage | `--debug` | Afficher chaque requête HTTP envoyée et chaque réponse (démo 2) |
| Débogage | `--timing` | Afficher la durée de chaque requête (démo 2) |
| Version | `--os-compute-api-version 2.96` | Choisir la **microversion** de l’API (§ 3.3) |
| Sortie | `-f table` / `json` / `yaml` / `value` / `csv` | Le format : `table` pour lire, `value` pour les boucles `bash`, `json` pour les scripts, `csv` pour un tableur |
| Sortie | `-c COLONNE` (répétable) | Ne garder que certaines colonnes |
| Sortie | `--sort-column COLONNE --sort-descending` | Trier |

Exemple de `-f value -c` : `openstack network list -f value -c Name` donne seulement les noms, une ligne par réseau, sans tableau. C’est la forme à utiliser pour stocker un résultat dans une variable : `ID=$(openstack server show lab-diag -f value -c id)`.

---

## 2. Démo 1 : l’état de la plateforme (10 min) ✅

**Objectif :** savoir en quelques commandes si le cloud fonctionne, et quelle capacité il lui reste. C’est le premier contrôle à faire quand « rien ne marche ».

```bash
source ~/admin-openrc
```

Ces commandes demandent le compte **administrateur**.

### Étape 1 : les services du catalogue

**À quoi ça sert :** savoir quels services le cloud propose. Le **catalogue** est l’annuaire que Keystone donne à chaque client : « Nova est à telle adresse, Neutron à telle autre… ».

```bash
openstack catalog list -c Name -c Type
```

**Ce que tu vois :**

```text
+-----------+---------------+
| Name      | Type          |
+-----------+---------------+
| glance    | image         |
| placement | placement     |
| neutron   | network       |
| keystone  | identity      |
| nova      | compute       |
| cinder    | block-storage |
| swift     | object-store  |
| cinderv3  | volumev3      |
| s3        | s3            |
+-----------+---------------+
```

**Comment le lire :**

| Nom | Type | Rôle |
|---|---|---|
| `keystone` | `identity` | Identité : comptes, projets, jetons, catalogue |
| `nova` | `compute` | Les VM |
| `placement` | `placement` | L’inventaire des ressources (CPU, RAM, disque) de chaque hôte |
| `neutron` | `network` | Les réseaux, routeurs, IP flottantes, groupes de sécurité |
| `glance` | `image` | Les images de disque |
| `cinder`, `cinderv3` | `block-storage`, `volumev3` | Les volumes ; deux entrées pour le même service, sous deux noms de type |
| `swift`, `s3` | `object-store`, `s3` | Le stockage objet, fourni par la passerelle de Ceph |

Sans la colonne `-c`, la commande affiche aussi les **adresses** de chaque service (`public`, `internal`, `admin`).

**Si tu vois autre chose :** un service en plus (`heat`, `octavia`…) = une fonctionnalité activée avec `sunbeam enable`. Un service présent au catalogue mais qui ne répond pas = souvent un **reste** d’une fonctionnalité désactivée (guide `3-sunbeam-cli/`, démo 5).

### Étape 2 : les services de calcul

**À quoi ça sert :** vérifier que les processus de Nova tournent et donnent signe de vie.

```bash
openstack compute service list
```

**Ce que tu vois :**

```text
+--------------------------------------+----------------+---------+----------+---------+-------+----------------------------+
| ID                                   | Binary         | Host    | Zone     | Status  | State | Updated At                 |
+--------------------------------------+----------------+---------+----------+---------+-------+----------------------------+
| 802fd3be-346d-4de7-b21e-d0fe88ed27f1 | nova-scheduler | nova-0  | internal | enabled | up    | 2026-10-17T08:07:58.000000 |
| 0359de79-5080-43b9-93dc-33ce1aaff78f | nova-conductor | nova-0  | internal | enabled | up    | 2026-10-17T08:07:56.000000 |
| 0a1596de-6cbd-4336-ad22-c772b5eca254 | nova-compute   | sunbeam | nova     | enabled | up    | 2026-10-17T08:07:59.000000 |
+--------------------------------------+----------------+---------+----------+---------+-------+----------------------------+
```

**Comment le lire :**

| Colonne | Signification |
|---|---|
| `Binary` | Le processus : `nova-scheduler` **choisit** l’hôte d’une nouvelle VM ; `nova-conductor` **coordonne** et accède à la base ; `nova-compute` **crée** les VM sur l’hôte |
| `Host` | Où il tourne : `nova-0` est un **pod** Kubernetes ; `sunbeam` est la **VM** Lab-Sunbeam, qui joue le rôle d’hyperviseur |
| `Zone` | La zone de disponibilité : `nova` pour les hyperviseurs ; `internal` pour les services de contrôle |
| `Status` | Décision de l’administrateur : `enabled` = autorisé à recevoir du travail ; `disabled` = mis de côté volontairement (maintenance) |
| `State` | Constat : `up` = le service a donné signe de vie récemment ; `down` = plus de nouvelles |
| `Updated At` | L’heure (UTC) du **dernier signal de vie**. Elle avance toutes les 10 secondes environ |

### Étape 3 : les agents réseau

```bash
openstack network agent list
```

**Ce que tu vois :**

```text
+--------------------------------------+------------------------------+---------+-------------------+-------+-------+----------------------------+
| ID                                   | Agent Type                   | Host    | Availability Zone | Alive | State | Binary                     |
+--------------------------------------+------------------------------+---------+-------------------+-------+-------+----------------------------+
| sunbeam                              | OVN Controller Gateway agent | sunbeam |                   | :-)   | UP    | ovn-controller             |
| 44c07b35-c668-53ee-80f1-07b39e92b686 | OVN Metadata agent           | sunbeam |                   | :-)   | UP    | neutron-ovn-metadata-agent |
+--------------------------------------+------------------------------+---------+-------------------+-------+-------+----------------------------+
```

**Comment le lire :**

| Agent | Rôle |
|---|---|
| `OVN Controller Gateway agent` | Le commutateur virtuel de l’hôte. `Gateway` = cet hôte sert aussi de **passerelle** vers le réseau externe : c’est par lui que passent les IP flottantes |
| `OVN Metadata agent` | Répond aux VM qui demandent leur configuration au démarrage (nom, clé SSH) à l’adresse `169.254.169.254` |

`Alive :-)` et `State UP` = l’agent répond. `XXX` dans `Alive` = il ne répond plus.

### Étape 4 : les services de stockage

```bash
openstack volume service list
openstack volume backend pool list
```

**Ce que tu vois :**

```text
+------------------+----------------------------+------+---------+-------+----------------------------+
| Binary           | Host                       | Zone | Status  | State | Updated At                 |
+------------------+----------------------------+------+---------+-------+----------------------------+
| cinder-scheduler | cinder-0                   | nova | enabled | up    | 2026-10-17T08:08:18.000000 |
| cinder-volume    | sunbeam@cinder-volume-ceph | nova | enabled | up    | 2026-10-17T08:08:17.000000 |
+------------------+----------------------------+------+---------+-------+----------------------------+
+-----------------------------------------------------+
| Name                                                |
+-----------------------------------------------------+
| cinder-volume@cinder-volume-ceph#cinder-volume-ceph |
+-----------------------------------------------------+
```

**Comment le lire :**

| Ligne | Signification |
|---|---|
| `cinder-scheduler` sur `cinder-0` | Choisit **où** créer un volume |
| `cinder-volume` sur `sunbeam@cinder-volume-ceph` | Crée réellement les volumes. Le nom se lit `hôte@backend` : sur l’hôte `sunbeam`, avec le stockage nommé `cinder-volume-ceph` |
| Pool `…#cinder-volume-ceph` | Un **pool** est un espace où Cinder peut créer des volumes : ici, le pool Ceph du même nom. S’il n’y a aucun pool, aucun volume ne peut être créé |

**Si tu vois autre chose dans les étapes 2 à 4 :**

| Ce que tu vois | Signification | Que faire |
|---|---|---|
| `State down`, `Updated At` figé | Le service ne donne plus signe de vie depuis cette heure-là | Comparer l’heure avec un redémarrage ; chercher la cause dans Juju (démo 6) |
| `Status disabled` | Mis de côté volontairement | `openstack compute service set --enable HÔTE nova-compute` si c’est un oubli |
| `Alive XXX` | L’agent réseau ne répond plus | Les VM de cet hôte perdent le réseau : `juju status -m admin/openstack-machines` |
| Aucun pool | Cinder n’a plus de stockage | Démo 6 |

Le 16 octobre, la ligne `cinder-volume` était `down` avec `Updated At 2026-10-16T12:49:19`, l’heure du redémarrage du lab. La démo 6 raconte cette panne.

### Étape 5 : l’hyperviseur

```bash
openstack hypervisor list --long
```

**Ce que tu vois :**

```text
+--------------------------------------+---------------------+-----------------+-----------+-------+
| ID                                   | Hypervisor Hostname | Hypervisor Type | Host IP   | State |
+--------------------------------------+---------------------+-----------------+-----------+-------+
| cc165330-eaa5-44bc-968c-e364028e8b1a | sunbeam             | QEMU            | 10.0.2.15 | up    |
+--------------------------------------+---------------------+-----------------+-----------+-------+
```

**Comment le lire :** un seul hyperviseur, `sunbeam`. `QEMU` = le logiciel d’émulation, accéléré par KVM. `Host IP 10.0.2.15` = l’adresse de la carte 1 (NAT) de la VM. Retiens l’`ID` `cc165330-…` : on le retrouve dans Placement à l’étape suivante.

⚠ `openstack hypervisor show sunbeam` n’affiche plus le nombre de CPU, la RAM ou le nombre de VM : avec les versions récentes de Nova, ces chiffres sont dans **Placement**.

### Étape 6 : la capacité réelle (Placement)

**À quoi ça sert :** savoir combien de CPU, de RAM et de disque le cloud peut encore attribuer. C’est **Placement** que Nova interroge avant de créer une VM.

```bash
openstack resource provider list -c uuid -c name
openstack resource provider inventory list "$(openstack resource provider list -f value -c uuid --name sunbeam)"
```

**La commande, mot par mot :** un **fournisseur de ressources** (*resource provider*) est un objet qui possède des ressources, ici l’hôte `sunbeam`. La partie entre `$( … )` retrouve son identifiant à partir de son nom, puis `inventory list` affiche son inventaire.

**Ce que tu vois :**

```text
| cc165330-eaa5-44bc-968c-e364028e8b1a | sunbeam              |
| cb637437-77cd-4e89-b49f-be6077cd1b2a | sunbeam_0000:00:02.0 |

+----------------+------------------+----------+----------+----------+-----------+-------+------+
| resource_class | allocation_ratio | min_unit | max_unit | reserved | step_size | total | used |
+----------------+------------------+----------+----------+----------+-----------+-------+------+
| VCPU           |              4.0 |        1 |       12 |        0 |         1 |    12 |    0 |
| MEMORY_MB      |              1.0 |        1 |    23141 |      512 |         1 | 23141 |    0 |
| DISK_GB        |              1.0 |        1 |      160 |        0 |         1 |   160 |    0 |
+----------------+------------------+----------+----------+----------+-----------+-------+------+
```

**Comment le lire :**

- l’hôte `sunbeam` a le **même identifiant** que l’hyperviseur ; le second fournisseur (`…_0000:00:02.0`) est un périphérique PCI de la VM, sans importance ici ;
- dans l’inventaire, une ligne par type de ressource :

| Colonne | VCPU | MEMORY_MB | Signification |
|---|---|---|---|
| `total` | 12 | 23 141 | Ce que l’hôte possède |
| `reserved` | 0 | 512 | Gardé pour l’hôte lui-même |
| `allocation_ratio` | 4.0 | 1.0 | **Surallocation** : on peut attribuer 4 fois plus de vCPU qu’il n’en existe, mais pas plus de RAM |
| `max_unit` | 12 | 23 141 | La plus grosse demande possible **pour une seule VM** |
| `used` | 0 | 0 | Ce qui est attribué aux VM existantes |

**Capacité attribuable** = (`total` − `reserved`) × `allocation_ratio` : 48 vCPU, 22 629 Mo de RAM, 160 Go de disque.

### Étape 7 : une VM de cette taille peut-elle démarrer ?

```bash
openstack allocation candidate list --resource VCPU=1 --resource MEMORY_MB=512 -c "resource provider" -c "inventory used/capacity"
```

**La commande, mot par mot :** « donne-moi la liste des hôtes (**candidats**) qui peuvent fournir 1 vCPU et 512 Mo ». C’est exactement la question que Nova pose avant de créer une VM `m1.tiny`.

**Ce que tu vois :**

```text
+--------------------------------------+-------------------------------------------+
| resource provider                    | inventory used/capacity                   |
+--------------------------------------+-------------------------------------------+
| cc165330-eaa5-44bc-968c-e364028e8b1a | DISK_GB=0/160,MEMORY_MB=0/22629,VCPU=0/48 |
+--------------------------------------+-------------------------------------------+
```

**Comment le lire :** **une ligne** = un hôte capable d’accueillir la demande, ici `sunbeam`. `utilisé/capacité` : rien n’est utilisé, 48 vCPU et 22 629 Mo sont attribuables, conformément au calcul de l’étape 6.

**Si tu vois autre chose :** **aucune ligne** = aucune VM de cette taille ne pourra démarrer ; elle passera en `ERROR` (démo 5).

### Étape 8 : la consommation par projet

```bash
openstack usage list
```

**Ce que tu vois :**

```text
Usage from 2026-09-19 to 2026-10-18:
+---------+---------+--------------+-----------+---------------+
| Project | Servers | RAM MB-Hours | CPU Hours | Disk GB-Hours |
+---------+---------+--------------+-----------+---------------+
| demo    | None    | 1792.0       | 1.88      | 17.24         |
+---------+---------+--------------+-----------+---------------+
```

**Comment le lire :** la consommation **cumulée** des 30 derniers jours, par projet. `RAM MB-Hours 1792` = par exemple 512 Mo pendant 3,5 heures ; `CPU Hours 1.88` = vCPU × heures ; `Servers None` = aucune VM en cours. C’est la base d’une **refacturation** interne.

### Ce qu’il faut retenir de la démo 1

| Question | Commande | Réponse sur le lab |
|---|---|---|
| Quels services ? | `catalog list` | 7 services (Keystone, Nova, Placement, Neutron, Glance, Cinder, stockage objet) |
| Le calcul tourne-t-il ? | `compute service list` | 3 processus `up` |
| Le réseau tourne-t-il ? | `network agent list` | 2 agents `:-)` |
| Le stockage tourne-t-il ? | `volume service list`, `volume backend pool list` | 2 services `up`, 1 pool Ceph |
| Quelle capacité ? | `resource provider inventory list` | 48 vCPU, 22 Go de RAM, 160 Go de disque |
| Une VM peut-elle démarrer ? | `allocation candidate list` | Oui, sur `sunbeam` |

---

## 3. Démo 2 : ce que fait vraiment une commande (15 min) ✅

**Objectif :** voir ce qui se passe « sous » une commande `openstack` : à qui elle parle, dans quel ordre, combien de temps cela prend, et comment retrouver la requête dans les journaux du service.

```bash
source ~/demo-openrc
```

### Étape 1 : les requêtes HTTP avec `--debug`

**À quoi ça sert :** une commande `openstack` n’est qu’une suite de **requêtes HTTP** vers les API. `--debug` les affiche toutes.

```bash
openstack --debug network list 2>&1 | grep -E "^REQ: curl|^RESP: \[|X-Openstack-Request-Id" | cut -c1-150
```

**La commande, mot par mot :**

| Morceau | Rôle |
|---|---|
| `--debug` | Afficher les détails de chaque échange, sur la **sortie d’erreur** |
| `2>&1` | Renvoyer la sortie d’erreur vers la sortie normale, pour pouvoir la filtrer |
| `grep -E "^REQ: curl\|^RESP: \[\|…"` | Ne garder que les requêtes (`REQ`), les codes de réponse (`RESP`) et les identifiants de requête |
| `cut -c1-150` | Couper les lignes à 150 caractères |

**Ce que tu vois :**

```text
REQ: curl -g -i -X GET http://cloud.lab.test/openstack-keystone/v3 -H "Accept: application/json" -H "User-Agent: openstacksdk/4.4.0 …
RESP: [200] Content-Length: 268 Content-Type: application/json … Server: Apache/2.4.58 (Ubuntu) …
REQ: curl -g -i -X GET http://cloud.lab.test:80/openstack-neutron/v2.0/networks -H "Accept: application/json" …
RESP: [200] Content-Length: 1222 Content-Type: application/json … X-Openstack-Request-Id: req-d01462ca-6224-4b3b-b05…
```

**Comment le lire :**

| Ligne | Signification |
|---|---|
| 1ʳᵉ `REQ` : `GET …/openstack-keystone/v3` | Le client interroge Keystone, **la seule adresse qu’il connaît** (`OS_AUTH_URL`) |
| 1ʳᵉ `RESP: [200]` | Keystone répond : la requête a réussi |
| *(non affiché par ce filtre)* | Le client demande un **jeton** (`POST …/auth/tokens`) ; la réponse contient le jeton et le **catalogue** |
| 2ᵉ `REQ` : `GET …/openstack-neutron/v2.0/networks` | Le client a trouvé l’adresse de Neutron **dans le catalogue**, puis demande la liste des réseaux |
| 2ᵉ `RESP: [200]` + `X-Openstack-Request-Id: req-…` | Neutron répond, avec l’**identifiant unique** de cette requête |

Chaque `REQ` est une commande `curl` **rejouable** telle quelle. L’identifiant `req-…` permet de retrouver cette requête précise dans les journaux de Neutron (étape 3).

⚠ La sortie complète de `--debug` contient le **jeton** (`X-Auth-Token`), qui vaut un mot de passe pendant une heure : ne jamais la copier telle quelle dans un ticket.

### Étape 2 : le temps passé avec `--timing`

```bash
openstack --timing network list -f value -c Name
```

**Ce que tu vois :**

```text
demo-network
external-network

"URL","Seconds"
"GET http://cloud.lab.test/openstack-keystone/v3",0.028143
"POST http://cloud.lab.test/openstack-keystone/v3/auth/tokens",0.729393
"GET http://cloud.lab.test:80/openstack-neutron/v2.0/networks",1.318137
"Total",2.075673
```

**Comment le lire :** d’abord le résultat (les deux réseaux visibles par `demo`), puis la durée de chaque requête : découverte de Keystone (0,03 s), **obtention du jeton** (0,73 s), liste des réseaux (1,32 s). Total : 2 secondes.

**Ce qu’il faut retenir :** environ un tiers du temps passe à **obtenir un jeton**, et chaque commande `openstack` en redemande un. Un script qui lance cent commandes paie cent fois ce coût : pour un traitement en masse, utiliser un SDK (Python `openstacksdk`), qui garde son jeton.

### Étape 3 : retrouver la requête dans le journal du service

**À quoi ça sert :** relier une commande du client à la ligne correspondante dans le journal du serveur. C’est ce que demande un support : « donnez-moi l’identifiant de requête ».

```bash
REQ=$(openstack --debug network list 2>&1 | grep -o "X-Openstack-Request-Id: req-[0-9a-f-]*" | tail -1 | cut -d' ' -f2)
echo "$REQ"
sudo k8s kubectl -n openstack logs neutron-0 -c neutron-server --since=2m | grep "$REQ" | grep "neutron.wsgi" | sed -E 's/.*\] //' | cut -c1-160
```

**La commande, mot par mot :**

| Ligne | Rôle |
|---|---|
| `REQ=$(…)` | Relance la commande avec `--debug`, extrait le dernier identifiant `req-…` et le garde dans la variable `REQ` |
| `kubectl -n openstack logs neutron-0 -c neutron-server --since=2m` | Lit les journaux du conteneur `neutron-server` du pod `neutron-0`, sur les 2 dernières minutes |
| `grep "$REQ" \| grep "neutron.wsgi"` | Garde la ligne de **cette** requête HTTP |
| `sed … \| cut …` | Retire le début technique de la ligne et la raccourcit |

**Ce que tu vois :**

```text
req-c3b2375a-39f3-4e18-98e4-dc83669d2ca6
10.1.0.196,10.1.0.141 "GET /openstack-neutron/v2.0/networks HTTP/1.1" status: 200  len: 1398 time: 1.8276970
```

**Comment le lire :** l’identifiant, puis la ligne du serveur : les adresses du client vues par Neutron (`10.1.0.x` : des adresses de pods Kubernetes, car la requête passe par le répartiteur d’entrée du cloud), la requête, le code `200`, la taille de la réponse et la **durée côté serveur** (1,8 s).

L’identifiant apparaît aussi dans des lignes d’audit (`oslo.messaging.notification.audit`) : c’est pourquoi on filtre sur `neutron.wsgi`.

**Ce qu’il faut retenir :** le client ne connaît que Keystone ; il découvre les autres services dans le catalogue ; l’identifiant de requête relie le client aux journaux du service. Le traceur du dossier `2-trace/` montre la même chose en direct.

---

## 4. Démo 3 : lire les refus (10 min) ✅

**Objectif :** reconnaître chaque type de refus pour savoir **où chercher**. Un message d’erreur OpenStack contient presque toujours la réponse.

```bash
source ~/demo-openrc
```

### `401` : qui es-tu ?

```bash
OS_PASSWORD=faux openstack token issue
```

**La commande, mot par mot :** `OS_PASSWORD=faux` remplace le mot de passe **pour cette commande seulement** ; `token issue` demande un jeton.

**Ce que tu vois :**

```text
The request you have made requires authentication. (HTTP 401) (Request-ID: req-dc14027c-ad17-4157-94b9-4006c5233a7f)
```

**Comment le lire :** `401` = Keystone **ne t’a pas reconnu** : nom, mot de passe, domaine ou projet incorrect. Le problème est dans **tes variables** (`env | grep OS_`), pas dans le cloud.

### `403` : tu n’as pas le droit

```bash
openstack user list
```

**Ce que tu vois :**

```text
ForbiddenException: 403: Client Error for url: http://cloud.lab.test/openstack-keystone/v3/users, You are not authorized to perform the requested action: identity:list_users.
```

**Comment le lire :** `403` = Keystone **sait qui tu es**, mais la politique interdit l’action. Le message donne l’adresse appelée (`…/v3/users`) et surtout le **nom de la règle refusée** : `identity:list_users`. C’est le nom à chercher dans la politique du service ; ici, seul un administrateur peut lister les comptes.

### `No … found` : je ne le trouve pas

```bash
openstack server show inexistant
```

**Ce que tu vois :**

```text
No Server found for inexistant
```

**Comment le lire :** aucun objet de ce nom **dans ta portée**. Soit il n’existe pas, soit il appartient à un **autre projet**. Piège classique : même l’administrateur ne trouve pas **par son nom** une VM du projet `demo`, car il cherche d’abord dans son propre projet. Utiliser l’identifiant, ou `openstack server list --all-projects --name NOM`.

### Version d’API refusée

```bash
openstack --os-compute-api-version 2.200 server list
```

**Ce que tu vois :**

```text
A default microversion for service compute of 2.200 was requested, but the cloud only supports a minimum of 2.1 and a maximum of 2.96.
```

**Comment le lire :** le serveur donne lui-même la **plage** acceptée (voir § 6.3).

### Tableau récapitulatif des codes

| Code | Sens | Exemple observé sur le lab | Où chercher |
|---|---|---|---|
| `400` | Requête invalide | `console url show` : `Unavailable console type novnc` | La commande : option ou valeur |
| `401` | Identité refusée | Mauvais mot de passe | Les variables `OS_*` |
| `403` | Action interdite | `identity:list_users` | Le rôle de l’utilisateur ; la règle nommée |
| `404` / `No … found` | Objet absent de ta portée | `No Server found for …` | Le projet ; utiliser l’identifiant |
| `409` | Conflit, souvent un quota dépassé | (voir `labs-iam/03-…`) | `openstack quota show --usage` |
| `500` | Erreur dans le service | Le champ `fault` d’une VM en `ERROR` (démo 5) | Les journaux du service |
| `503` | Service indisponible | Lab qui démarre | Attendre ; `juju status` |

---

## 5. Démo 4 : tout savoir d’une VM (20 min) ✅

**Objectif :** suivre une VM de sa création à son branchement réseau, avec la vue du propriétaire puis celle de l’administrateur.

### Étape 1 : créer la VM (compte `demo`)

```bash
source ~/demo-openrc
openstack server create lab-diag --image ubuntu --flavor m1.tiny --network demo-network --wait -c status -c addresses
```

**La commande, mot par mot :**

| Morceau | Rôle |
|---|---|
| `server create lab-diag` | Créer une VM nommée `lab-diag` |
| `--image ubuntu` | Son disque est une copie de l’image `ubuntu` |
| `--flavor m1.tiny` | Sa taille : 1 vCPU, 512 Mo de RAM, 4 Go de disque |
| `--network demo-network` | Le réseau auquel la brancher |
| `--wait` | Attendre qu’elle soit démarrée avant de rendre la main |
| `-c status -c addresses` | N’afficher que l’état et l’adresse |

✅ Attendu : `status ACTIVE` et une adresse `demo-network=10.20.0.x` (le sous-réseau `demo-subnet` est `10.20.0.0/24`).

### Étape 2 : l’historique des opérations

```bash
openstack server event list lab-diag
openstack server event show lab-diag "$(openstack server event list lab-diag -f value -c 'Request ID' | tail -1)"
```

**À quoi ça sert :** `event list` liste les opérations faites sur la VM (création, arrêt, redimensionnement…) ; `event show` détaille les **étapes** de l’une d’elles. La partie entre `$( … )` retrouve l’identifiant de la dernière opération.

**Ce que tu vois** (abrégé) :

```text
| req-… | … | create | 2026-10-16T15:17:42 |
events: event='compute__do_build_and_run_instance', result='Success', start_time='…15:17:50', finish_time='…15:18:00'
```

**Comment le lire :** une opération `create` à 15:17:42 ; son étape sur l’hôte (`compute__do_build_and_run_instance` = construire et démarrer la VM) a réussi (`Success`) et a pris **10 secondes**. Pour une VM en échec, cette commande dit **quelle étape** a échoué (démo 5).

### Étape 3 : ce que dit la VM au démarrage

```bash
sleep 40
openstack console log show lab-diag --lines 6
openstack console url show --spice lab-diag
```

**À quoi ça sert :** `console log show` affiche les dernières lignes de la **console série** de la VM, comme si on regardait son écran au démarrage ; `--lines 6` = les 6 dernières. On y voit si le système a démarré, s’il a obtenu son adresse, s’il a reçu sa clé SSH. `sleep 40` laisse le temps au système de démarrer.

`console url show --spice` donne une adresse à ouvrir dans un navigateur pour avoir la **console graphique** :

```text
url: http://cloud.lab.test/openstack-nova-spiceproxy/spice_auto.html?path=…&token=…
```

⚠ Le lab propose une console **SPICE**, pas noVNC : sans `--spice`, la commande échoue en `400 Unavailable console type novnc`.

Garder l’identifiant de la VM pour la suite :

```bash
SID=$(openstack server show lab-diag -f value -c id)
```

### Étape 4 : la vue de l’administrateur

```bash
source ~/admin-openrc
openstack server show "$SID" -c name -c OS-EXT-SRV-ATTR:host -c OS-EXT-SRV-ATTR:instance_name -c project_id
```

On utilise l’identifiant `$SID` : par son nom, l’administrateur ne trouverait pas la VM (démo 3).

**Ce que tu vois :**

```text
| OS-EXT-SRV-ATTR:host          | sunbeam           |
| OS-EXT-SRV-ATTR:instance_name | instance-00000006 |
```

**Comment le lire :** les champs `OS-EXT-SRV-ATTR` ne sont visibles que par l’administrateur. `host sunbeam` = l’hyperviseur qui fait tourner la VM ; `instance-00000006` = son nom **dans libvirt**, sur l’hôte : `sudo openstack-hypervisor.virsh list` le montre.

### Étape 5 : le branchement réseau

```bash
openstack port show "$(openstack port list --device-id "$SID" -f value -c ID)" -c status -c binding_host_id -c binding_vif_type -c device_owner
```

**La commande, mot par mot :** un **port** est la prise réseau virtuelle de la VM. `port list --device-id "$SID"` trouve le port branché sur la VM ; `port show` en affiche quatre champs.

**Ce que tu vois :**

```text
| binding_host_id  | sunbeam          |
| binding_vif_type | ovs              |
| device_owner     | compute:nova     |
| status           | ACTIVE           |
```

**Comment le lire :**

| Champ | Valeur | Signification |
|---|---|---|
| `device_owner` | `compute:nova` | Le port appartient à une VM |
| `binding_host_id` | `sunbeam` | Il est rattaché à l’hôte de la VM |
| `binding_vif_type` | `ovs` | Branché sur le commutateur virtuel Open vSwitch |
| `status` | `ACTIVE` | Le branchement est terminé |

**Si tu vois autre chose :** `status DOWN` ou `binding_vif_type binding_failed` = le réseau de la VM n’est pas branché ; vérifier les agents réseau (démo 1, étape 3).

### Étape 6 : les compteurs vus par l’hyperviseur

```bash
openstack server show "$SID" --diagnostics -c state -c uptime -c driver -c hypervisor -c nic_details
```

**Ce que tu vois** (abrégé) :

```text
| driver     | libvirt |
| hypervisor | kvm     |
| state      | running |
nic_details: rx_packets 180, tx_packets 247, rx_errors 0, rx_drop 0
```

**Comment le lire :** la VM tourne (`running`) sous KVM ; sa carte réseau a reçu (`rx`) 180 paquets et en a émis (`tx`) 247, sans erreur ni perte. Ce sont les compteurs de l’**hyperviseur** : on les obtient sans entrer dans la VM. Une VM qui ne reçoit rien (`rx_packets` bloqué) a un problème de réseau en amont.

### Nettoyer

```bash
source ~/demo-openrc
openstack server delete lab-diag --wait
```

---

## 6. Démo 5 : pourquoi une VM passe en `ERROR` (15 min) ✅

**Objectif :** mener l’enquête sur une VM qui ne démarre pas, avec la méthode **événement → faute → capacité → journal**. On provoque la panne en demandant une VM plus grosse que l’hôte.

### Étape 1 : provoquer la panne

```bash
source ~/admin-openrc
openstack flavor create lab-geant --vcpus 2 --ram 65536 --disk 10 --public -c name -c ram
source ~/demo-openrc
openstack server create lab-trop-gros --image ubuntu --flavor lab-geant --network demo-network --wait
```

**La commande, mot par mot :** `flavor create` crée un **gabarit** (une taille de VM) de 2 vCPU et **64 Go** de RAM ; seul l’administrateur peut le faire ; `--public` le rend utilisable par tous les projets. L’utilisateur `demo` lance ensuite une VM de cette taille.

**Ce que tu vois :**

```text
Error creating server: lab-trop-gros
```

### Étape 2 : ce que voit le propriétaire

```bash
openstack server show lab-trop-gros -c status -c fault
openstack server event show lab-trop-gros "$(openstack server event list lab-trop-gros -f value -c 'Request ID' | tail -1)"
```

**Ce que tu vois :**

```text
| status | ERROR |
events: event='conductor_schedule_and_build_instances', result='Error'
```

**Comment le lire :** le champ `fault` (la cause) est **vide** pour un utilisateur ordinaire. L’événement dit seulement **quelle étape** a échoué : `conductor_schedule_and_build_instances`, la **planification**, c’est-à-dire le choix d’un hôte. La VM n’a donc jamais atteint d’hyperviseur.

### Étape 3 : ce que voit l’administrateur

```bash
source ~/admin-openrc
EID=$(openstack server list --all-projects --name lab-trop-gros -f value -c ID)
openstack server show "$EID" -c fault -f yaml | head -8
```

**Ce que tu vois :**

```text
fault:
  code: 500
  details: "Traceback … in schedule_and_build_instances … in _schedule_instances … select_destinations …"
```

**Comment le lire :** `code 500` = erreur côté service ; la trace montre l’échec dans `select_destinations` : **le Scheduler n’a trouvé aucune destination**. Il reste à savoir pourquoi.

### Étape 4 : la cause, dans Placement

```bash
openstack allocation candidate list --resource MEMORY_MB=65536 --resource VCPU=2
openstack allocation candidate list --resource MEMORY_MB=512 --resource VCPU=1 -c "resource provider" -c "inventory used/capacity"
```

**Ce que tu vois :** **aucune ligne** pour 64 Go ; une ligne (`sunbeam`) pour 512 Mo.

**Comment le lire :** aucun hôte ne peut fournir 64 Go, puisque le plus gros `max_unit` de RAM est 23 141 Mo (démo 1, étape 6). La seconde commande prouve que Placement fonctionne : c’est bien la **taille** qui pose problème.

### Étape 5 : la confirmation dans le journal du Scheduler

```bash
REQ=$(openstack server event list "$EID" -f value -c "Request ID" | tail -1)
sudo k8s kubectl -n openstack logs nova-0 -c nova-scheduler --since=15m | grep "$REQ" | sed -E 's/.*\] //' | cut -c1-160
```

**Ce que tu vois :**

```text
Got no allocation candidates from the Placement API. This could be due to insufficient resources …
```

**Comment le lire :** même méthode que la démo 2 : l’identifiant de l’opération mène à la ligne du journal, qui confirme le diagnostic : ressources insuffisantes.

**Ce qu’il faut retenir :**

| Étape | Commande | Ce qu’elle apprend |
|---|---|---|
| Événement | `server event show` | **Quelle étape** a échoué |
| Faute | `server show -c fault` (admin) | **Quelle erreur** |
| Capacité | `allocation candidate list` | **Pourquoi** : pas d’hôte assez grand |
| Journal | `kubectl logs … \| grep req-…` | La **preuve** côté service |

### Nettoyer

```bash
source ~/demo-openrc
openstack server delete lab-trop-gros --wait
source ~/admin-openrc
openstack flavor delete lab-geant
```

---

## 7. Démo 6 : une panne réelle du lab, le volume qui ne se crée pas (20 min) ✅

**Contexte :** observée telle quelle le 16 octobre, après la réimportation de la VM Sunbeam. Un utilisateur crée un volume, qui passe en erreur.

### Étape 1 : le symptôme

```bash
source ~/demo-openrc
openstack volume create lab-vol --size 1 -c status
sleep 25
openstack volume show lab-vol -c status
```

**La commande, mot par mot :** `volume create lab-vol --size 1` = créer un disque de 1 Go ; `sleep 25` = attendre 25 secondes ; `volume show -c status` = relire son état.

**Ce que tu voyais :**

```text
| status | creating |
| status | error    |
```

**Comment le lire :** la création est **asynchrone** : la commande rend la main en `creating`, puis le volume passe en `error`. Aucun champ du volume n’explique pourquoi.

### Étape 2 : le message utilisateur

```bash
openstack --os-volume-api-version 3.3 volume message list -c "User Message" -c "Created At"
```

**La commande, mot par mot :** `volume message list` liste les messages que Cinder adresse **à l’utilisateur** quand une opération échoue. Elle exige la microversion 3.3 de l’API des volumes, d’où `--os-volume-api-version 3.3`.

**Ce que tu voyais :**

```text
| schedule allocate volume:Could not find any available weighted backend. | 2026-10-16T15:26:17 |
```

**Comment le lire :** à l’étape `schedule allocate volume` (choix du stockage), le planificateur de Cinder n’a trouvé **aucun stockage disponible** (`backend`).

### Étape 3 : les services de stockage

```bash
source ~/admin-openrc
openstack volume service list
openstack volume backend pool list
```

**Ce que tu voyais :**

```text
| cinder-scheduler | cinder-0                   | nova | enabled | up   | 2026-10-16T15:26:53 |
| cinder-volume    | sunbeam@cinder-volume-ceph | nova | enabled | down | 2026-10-16T12:49:19 |
```

et une liste de pools **vide**.

**Comment le lire :** `cinder-volume` est `down`, et son dernier signal de vie date de 12:49:19, l’heure du redémarrage du lab. Sans lui, aucun pool n’est annoncé, et le planificateur n’a nulle part où créer le volume.

### Étape 4 : la cause, dans Juju

On passe de l’autre côté : OpenStack montre le **symptôme**, Juju montre la **cause** (guide `4-juju-cli/`, démo 4).

```bash
juju status -m admin/openstack-machines cinder-volume microceph --format short | grep -E "cinder-volume/|microceph/"
```

**Ce que tu voyais :**

```text
- cinder-volume/0: 10.0.2.15 (agent:idle, workload:waiting)     ← Not all relations are ready
- microceph/0:     10.0.2.15 (agent:idle, workload:blocked)     ← Error in charm: timed out
```

**Comment le lire :** au démarrage, le charm MicroCeph a dépassé son délai ; il est resté `blocked` et ne fournit plus à cinder-volume les informations de connexion à Ceph. cinder-volume attend (`waiting`) et ne démarre pas. Ceph lui-même fonctionne (`sudo ceph -s` : `1 osds: 1 up`).

**La chaîne complète :** charm MicroCeph bloqué → cinder-volume en attente → service `down` → aucun pool → `Could not find any available weighted backend` → volume en `error`.

```bash
source ~/demo-openrc
openstack volume delete lab-vol
```

### Étape 5 : résoudre (fait sur le lab le 17 octobre)

Les deux charms ont mémorisé l’échec du démarrage, et leur vérification périodique ne refait pas l’étape ratée. Redémarrer l’agent Juju de la machine (`sudo systemctl restart jujud-machine-0`) **n’a pas suffi** : MicroCeph était toujours `blocked` 14 minutes après. Ce qui a marché : rejouer le hook `config-changed` de chaque charm, **MicroCeph d’abord**, puis cinder-volume.

```bash
juju exec -m admin/openstack-machines --unit microceph/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
juju exec -m admin/openstack-machines --unit cinder-volume/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
snap services cinder-volume
```

**La commande, mot par mot :** `juju exec --unit X --` lance une commande dans le contexte du charm ; `JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch` fait croire au charm que sa configuration vient de changer : il refait toutes ses vérifications. `snap services cinder-volume` montre si le service tourne sur la machine.

**Ce que tu vois :**

```text
microceph/0 … workload:active          (après un dernier « timed out » de 16 s, le hook aboutit)
cinder-volume/0 … workload:active      (« Completed guarded section fully: 'Bootstrapping' »)
cinder-volume.cinder-volume  enabled  active
```

### Étape 6 : vérifier côté OpenStack

```bash
source ~/admin-openrc
openstack volume service list -c Binary -c State
openstack volume backend pool list
source ~/demo-openrc
openstack volume create lab-vol-test --size 1 -c status
sleep 10
openstack volume show lab-vol-test -c status
sudo rbd ls -p cinder-volume-ceph
openstack volume delete lab-vol-test
```

**Ce que tu vois :**

```text
| cinder-volume | up |
| cinder-volume@cinder-volume-ceph#cinder-volume-ceph |
| status | available |
volume-50b9d24a-aafe-416a-8675-968ac73027df
```

**Comment le lire :** le service est `up`, le pool est annoncé, le volume est `available` (prêt à être attaché). `rbd ls -p cinder-volume-ceph` liste les **images Ceph** du pool : on y retrouve le volume, sous le nom `volume-<son ID>`. Un volume OpenStack **est** une image RBD dans Ceph.

**Ce qu’il faut retenir :** le symptôme est dans OpenStack, la cause dans l’exploitation ; le client `openstack` mène jusqu’au service en panne, Juju jusqu’à sa cause.

⚠ Lancer un hook à la main est une opération d’exploitation. Elle est à réserver au cas où l’état d’un charm est figé alors que le service sous-jacent est sain (ici, `ceph -s` était correct depuis le début).

---

## 8. Autres commandes utiles

### 8.1 Un projet : quotas et limites ✅

```bash
source ~/demo-openrc
openstack quota show --usage "$(openstack token issue -f value -c project_id)" -f value | grep -E "^(instances|cores|ram|volumes|gigabytes) "
```

**À quoi ça sert :** savoir combien de ressources le projet peut encore consommer.

**La commande, mot par mot :** `quota show --usage` affiche les quotas **et** leur consommation. Elle attend le projet : la partie `$( … )` donne l’identifiant du projet courant, lu dans le jeton. `-f value | grep` ne garde que quelques lignes.

**Ce que tu vois :**

```text
cores -1 0 0
instances -1 0 0
ram -1 0 0
volumes 10 0 0
gigabytes 1000 0 0
```

**Comment le lire :** quatre colonnes : ressource, **limite**, **utilisé**, **réservé** (en cours de création). `-1` = **illimité** : sur le lab, le projet `demo` n’a aucune limite de calcul ; seuls les volumes sont bornés (10 volumes, 1 000 Go).

⚠ Un utilisateur ordinaire ne peut pas désigner son projet **par son nom** : `403 … identity:list_projects`. D’où l’identifiant tiré de `token issue`.

⚠ L’ancienne forme `-c instances -c cores` échoue (`No recognized column names`) : la sortie est désormais un tableau `Resource | Limit | In Use | Reserved`.

### 8.2 Images et gabarits ✅

```bash
openstack image show ubuntu -c name -c size -c disk_format -c min_ram -c visibility -c status
openstack flavor list --sort-column RAM --sort-descending -c Name -c RAM -c VCPUs -c Disk
```

**Ce que tu vois :**

```text
| disk_format | qcow2     |
| min_ram     | 0         |
| name        | ubuntu    |
| size        | 625612288 |
| status      | active    |
| visibility  | public    |

| m1.large      | 8192 |   90 |     4 |
| m1.large-sev  | 8192 |   90 |     4 |
| m1.medium     | 4096 |   60 |     2 |
| m1.small      | 2048 |   30 |     1 |
| m1.tiny       |  512 |    4 |     1 |
…
```

**Comment le lire :** l’image `ubuntu` est au format `qcow2`, pèse 625 Mo, est utilisable par tous les projets (`public`) et prête (`active`). Les gabarits sont triés du plus gros au plus petit : RAM en Mo, disque en Go. Les variantes `-sev` sont les mêmes tailles réservées aux hôtes qui gèrent le chiffrement mémoire AMD SEV.

### 8.3 Exporter un inventaire ✅

```bash
source ~/admin-openrc
openstack server list --all-projects --long -f csv -c ID -c Name -c Status -c Host -c Networks > ~/inventaire-vm.csv
openstack image list -f json > ~/inventaire-images.json
```

`--all-projects` = les VM de tous les projets (administrateur seulement) ; `-f csv` s’ouvre dans un tableur ; `-f json` se lit dans un script.

### 8.4 Les microversions

Chaque service fait évoluer son API par **microversions**. Le client utilise par défaut une version ancienne et sûre : une option récente peut donc sembler « absente ».

```bash
openstack versions show -c "Service Type" -c Version -c Status -c "Max Microversion"
```

**Ce que tu vois** (extrait) :

```text
| placement     | 1.0     | CURRENT   | 1.39             |
| identity      | 3.14    | CURRENT   | None             |
| compute       | 2.1     | CURRENT   | 2.96             |
| block-storage | 3.0     | CURRENT   | 3.71             |
```

**Comment le lire :** pour chaque service, la version d’API et la **microversion maximale** acceptée : Nova jusqu’à 2.96, Cinder jusqu’à 3.71, Placement jusqu’à 1.39. `None` = le service n’utilise pas de microversions. Exemple réel : `volume message list` exige `--os-volume-api-version 3.3` (démo 6).

---

## 9. Pièges observés sur le lab

| Piège | Ce que tu vois | Explication | Réflexe |
|---|---|---|---|
| Objet d’un autre projet cherché par nom | `No Server found for lab-diag` (admin) | L’administrateur cherche d’abord dans son projet | Identifiant, ou `--all-projects --name` |
| Projet désigné par son nom | `403 … identity:list_projects` | Un utilisateur ne peut pas lister les projets | `openstack token issue -f value -c project_id` |
| Nouveau format de `quota show --usage` | `No recognized column names` | La sortie est devenue un tableau de lignes | `-f value \| grep` |
| Console par défaut | `400 Unavailable console type novnc` | Le lab fournit SPICE | `console url show --spice` |
| Commande d’une API récente | `--os-volume-api-version 3.3 or greater is required` | Microversion trop ancienne par défaut | Ajouter la microversion |
| Champs absents de `hypervisor show` | Pas de `vcpus`, `memory_mb` | Déplacés dans Placement | `resource provider inventory list` |
| `fault` vide | Seul `status ERROR` visible | Le détail est réservé à l’administrateur | `server event show`, ou `server show ID -c fault` en admin |
| `--debug` partagé | Le jeton à l’écran | Le jeton vaut un mot de passe pendant une heure | Filtrer avant de partager |
| Volume en `error` sans explication | Aucun champ ne dit pourquoi | Le message est ailleurs | `volume message list` (démo 6) |

---

## 10. Récapitulatif des tests

| Commande | Exécutée | Remarque |
|---|---|---|
| `versions show`, `catalog list`, `module list`, `command list` | ✅ | |
| `compute service list`, `network agent list`, `volume service list`, `volume backend pool list` | ✅ | `cinder-volume` `down` le 16 octobre, `up` le 17 |
| `hypervisor list --long`, `hypervisor show` | ✅ | Champs de capacité absents (microversion) |
| `resource provider list`, `inventory list`, `allocation candidate list` | ✅ | |
| `quota show --usage`, `limits show --absolute`, `usage list` | ✅ | |
| `image show`, `flavor list --sort-column` | ✅ | |
| `-f table/json/yaml/csv/value`, `-c` | ✅ | |
| `--debug`, `--timing`, `--os-compute-api-version`, `--os-volume-api-version` | ✅ | |
| Erreurs `400`, `401`, `403`, `No … found` | ✅ | |
| `server create/show/delete`, `server event list/show`, `console log show`, `console url show --spice` | ✅ | |
| `port list --device-id`, `port show`, `server show --diagnostics`, `server show -c fault` | ✅ | |
| `flavor create/delete`, `volume create/show/delete`, `volume message list` | ✅ | |

État du lab à la fin des tests (17 octobre) : aucune VM, aucun volume, aucune IP flottante, aucun gabarit de test. La panne de stockage de la démo 6 est **résolue**. Pour rejouer la démo 6 en formation, il faut une machine où le problème est présent, par exemple juste après la réimportation d’une OVA sur un poste lent.
