# Dépanner les services OpenStack d’un cloud Sunbeam, pas à pas

> **Statut :** fiche assemblée à partir de commandes **déjà jouées sur le lab** entre le 16 et le 18 octobre 2026 (guides `3-sunbeam-cli/`, `4-juju-cli/DEMOS-PANNES.md`, `6-securite/`, guides apprenant). Les sorties citées sont celles observées. Ce document n’a pas été rejoué d’un bloc : là où une commande n’a pas été vue sur le lab, c’est signalé **(non joué)**.

Toutes les commandes se lancent dans **Lab-Sunbeam** (`ssh vagrant@192.168.56.10`), après :

```bash
sunbeam utils juju-login
source ~/admin-openrc
```

`juju-login` renouvelle ta session Juju (sans elle : `please enter password for sunbeam` ou `cannot get discharge`) ; `admin-openrc` charge les identifiants administrateur pour la commande `openstack`.

---

## 1. Comprendre avant de chercher : comment le cloud est construit

Une panne se cherche **couche par couche**, de haut en bas. Chaque couche dépend de celle du dessous :

```text
 Utilisateur : openstack …, Horizon
      │  HTTP
 Traefik (répartiteur)                cloud.lab.test (.201), internal.lab.test (.202)
      │
 Services OpenStack, dans des pods Kubernetes (modèle Juju « openstack »)
   keystone, glance, nova (api, conductor, scheduler), placement, neutron, cinder, horizon
      │                         │
 mysql-router ──► mysql        rabbitmq (messagerie entre services)
      │
 Services de la machine, en snaps (modèle Juju « admin/openstack-machines »)
   nova-compute + libvirt (snap openstack-hypervisor), ovn-controller,
   cinder-volume (snap cinder-volume), microceph (stockage Ceph)
      │
 Lab-Services : DNS du lab (192.168.56.20)
```

Deux idées en découlent :

1. **Un symptôme en haut a souvent sa cause en bas.** Exemple vu le 18 octobre : `nova`, `neutron` et `placement` en `blocked`, alors que la vraie cause était `mysql` encore en démarrage.
2. **Deux mondes, deux outils.** Les services en **pods** se lisent avec `juju` et `kubectl` ; les services **de la machine** avec `snap` et `journalctl`.

### Ce que dit le code d’erreur

Le code HTTP renvoyé par la commande `openstack` oriente tout de suite :

| Code | Signification | Où chercher d’abord |
|---|---|---|
| `401` | **Identité** : jeton absent, expiré, mot de passe faux, compte ou domaine désactivé | Keystone (§ 4), le compte |
| `403` | **Autorisation** : identifié, mais pas le droit (règle de politique) | Les rôles du compte (`role assignment list --effective`) |
| `404` | La ressource n’existe pas… ou l’adresse appelée est fausse | Le nom, le projet, le catalogue (`endpoint list`) |
| `409` | Conflit : nom déjà pris, **quota dépassé** | `quota show --usage` |
| `500` | Erreur **interne** du service | Les journaux du service ; souvent sa base de données |
| `502` | Le service a reçu une mauvaise réponse **d’un autre** service | Le service appelé (ex. Nova → Glance → Ceph) |
| `503` | Service indisponible : il ne répond pas, ou il ne joint pas Keystone | Le pod du service, puis Keystone, puis le DNS (Lab-Services) |

---

## 2. La méthode, en six étapes

| Étape | Question | Outil |
|---|---|---|
| 1. Reproduire | Quel est le symptôme exact, quel code ? | La commande `openstack`, avec `--debug` si besoin |
| 2. Situer | Quelle couche, quel service ? | Le tableau ci-dessus ; `openstack … service list`, `network agent list` |
| 3. Ce que Juju sait | Le charm a-t-il vu un problème ? | `juju status`, `juju show-status-log` |
| 4. Dans le service | Le processus tourne-t-il, son test de santé passe-t-il ? | `pebble checks` (pods), `snap services` (machine) |
| 5. Les journaux | Quelle erreur exacte ? | `kubectl logs` (pods), `journalctl` (machine), `juju debug-log` (charm) |
| 6. Corriger, puis vérifier | Corriger **par le charm**, puis rejouer l’étape 1 | `juju resolved`, relance de `config-changed`, `juju run` |

⚠ **« active » ne veut pas dire « fonctionne ».** Juju affiche l’état que le charm déclare. Une panne qui ne touche pas ce que le charm surveille reste invisible dans `juju status` (guide `DEMOS-PANNES.md`, parties 2 et 3). D’où l’étape 1 : **toujours** partir du symptôme réel, et finir en le rejouant.

---

## 3. La boîte à outils commune

### 3.1 Ce que voit Juju

```bash
juju status -m openstack --format short | grep -v "workload:active"
juju status -m admin/openstack-machines --format short | grep -v "workload:active"
```

**Pourquoi :** ne garder que les unités qui ne vont pas. Attendu sur un cloud sain : **aucune ligne** pour les deux. Le modèle des machines s’écrit `admin/openstack-machines` (il appartient à l’utilisateur Juju `admin`) : sans le préfixe, `model … not found`.

| État de l’unité | Ce que ça veut dire | Que faire |
|---|---|---|
| `active` | Le charm est satisfait | Rien (mais voir l’avertissement ci-dessus) |
| `maintenance` | Le charm travaille (installation, démarrage) | Attendre |
| `waiting` | Il attend une autre application (relation pas prête) | Chercher **l’autre** application |
| `blocked` | Il ne peut pas continuer sans intervention, le message dit pourquoi | Lire le message ; souvent une conséquence d’un problème plus bas |
| `error` | Un **hook** (une étape du charm) a planté | Lire l’erreur, corriger la cause, puis `juju resolved` |
| agent `lost` | Juju ne joint plus l’agent de l’unité | Le pod ou la machine ; souvent transitoire au démarrage |

Pour une unité précise (remplacer `nova/0`) :

```bash
juju show-status-log -m openstack nova/0
juju debug-log -m openstack --replay --no-tail --include nova/0 | tail -30
```

**Pourquoi :** `show-status-log` donne **l’historique** des états (quand, et quel message) ; `debug-log` donne les journaux **du charm**, avec la trace Python d’un `hook failed`. Les lignes de `debug-log` ne portent que l’heure, pas la date.

### 3.2 Dans un pod Kubernetes

Chaque service du modèle `openstack` est un pod (`nova-0`, `neutron-0`…), qui contient un conteneur `charm` et un ou plusieurs conteneurs de service. Trouver leurs noms :

```bash
sudo k8s kubectl -n openstack get pod nova-0 -o jsonpath='{.spec.containers[*].name}'; echo
```

Relevé sur le lab :

| Pod | Conteneurs de service |
|---|---|
| `keystone-0` | `keystone` |
| `glance-0` | `glance-api` |
| `nova-0` | `nova-api`, `nova-conductor`, `nova-scheduler`, `nova-spiceproxy` |
| `placement-0` | `placement-api` |
| `neutron-0` | `neutron-server` |
| `horizon-0` | `horizon` |
| autres (`cinder-0`…) | à lire avec la commande ci-dessus |

Le nom du conteneur figure aussi dans les messages de Juju : `(container:neutron-server) healthcheck failed`.

Quatre commandes, de la plus rapide à la plus détaillée (exemple : `neutron-0`, conteneur `neutron-server`) :

```bash
sudo k8s kubectl -n openstack get pod neutron-0
sudo k8s kubectl -n openstack exec neutron-0 -c neutron-server -- /charm/bin/pebble services
sudo k8s kubectl -n openstack exec neutron-0 -c neutron-server -- /charm/bin/pebble checks
sudo k8s kubectl -n openstack logs neutron-0 -c neutron-server --tail=30
```

| Commande | Ce qu’on regarde | Attendu |
|---|---|---|
| `get pod` | `READY` : conteneurs prêts / total (ce n’est **pas** un nombre d’instances) ; `RESTARTS` : redémarrages | Tous prêts (`2/2` pour `glance-0`), peu de redémarrages récents |
| `pebble services` | Le **processus** du service tourne-t-il ? Pebble est le gestionnaire de processus du conteneur, comme `systemctl` sur une machine | `active` |
| `pebble checks` | Ses **tests de santé** | Les deux tests `up` (voir ci-dessous) |
| `logs` | Ce que le service écrit : erreurs de base de données, de RabbitMQ, de Keystone | Pas de `ERROR` récent |

**Lire `pebble checks`.** Exemple réel, Placement en panne (guide `DEMOS-PANNES.md`, partie 5) :

```text
Check   Level  Startup  Status  Successes  Failures  Change
online  ready  enabled  down    24         44/3      48 (non-2xx status code 403; <!DOCTYPE H... run "pebble tasks 48" for more)
up      alive  enabled  up      70         0/3       46
```

| Colonne | Signification |
|---|---|
| `Check` | `online` : le service **répond-il** à une requête HTTP ? `up` : le **processus** est-il vivant ? |
| `Level` | `ready` : « prêt à recevoir du trafic » ; `alive` : « en vie » |
| `Status` | `up` (test réussi) ou `down` |
| `Failures` | `44/3` : 44 échecs consécutifs, pour un seuil de 3 |
| `Change` | La **cause directe** du dernier échec : ici, le service répond `403` au lieu de `200` |

**Comment ça s’enchaîne :** si le test `alive` échoue, Kubernetes **redémarre** le conteneur (`RESTARTS` augmente). Si seul le test `ready` échoue, comme ci-dessus, le conteneur reste en place mais ne reçoit plus de trafic : les clients reçoivent `503`, et Juju affiche `blocked … healthcheck failed: online`. C’est exactement le message de `neutron/0` au démarrage du 18 octobre.

### 3.3 Sur la machine (snaps)

```bash
snap services openstack-hypervisor
snap services cinder-volume
snap services microceph
sudo journalctl -u snap.openstack-hypervisor.nova-compute --since "-15min" --no-pager | tail -20
```

**Pourquoi :** `snap services` dit si chaque service est démarré (`active`) et lancé au démarrage (`enabled`) ; `journalctl` donne ses journaux. Pour savoir **qui** a arrêté un service et quand, `snap changes` (guide `DEMOS-PANNES.md`, partie 3).

### 3.4 Ce que voit OpenStack

```bash
openstack compute service list -c Binary -c Host -c State -c "Updated At"
openstack network agent list -c Binary -c Alive
openstack volume service list -c Binary -c Host -c State -c "Updated At"
```

**Pourquoi :** chaque service « travailleur » envoie un **signe de vie** régulier ; ces listes montrent le dernier reçu.

✅ **Attendu** (lab sain, 18 octobre) :

```text
nova-scheduler up
nova-conductor up
nova-compute up
True ovn-controller
True neutron-ovn-metadata-agent
cinder-scheduler up
cinder-volume up
```

Un service `down` avec un `Updated At` **figé** : il ne donne plus de nouvelles depuis cette heure-là. C’est l’heure à laquelle chercher dans ses journaux.

---

## 4. Keystone : l’identité

**Rôle :** délivre et valide les jetons. **Tout** passe par lui : s’il tombe, tout le cloud répond `401`, `500` ou `503`.

```bash
openstack token issue -c expires -f value
juju status -m openstack keystone keystone-mysql-router --format short
```

✅ **Attendu :** une date d’expiration (une heure plus tard), et les deux unités `active`.

| Symptôme | Cause probable | Vérification | Correction |
|---|---|---|---|
| `HTTP 500` sur toute authentification | `keystone-mysql-router` en `error` : Keystone ne joint plus sa base | `juju status … keystone-mysql-router` | § 5 (`juju resolved`) |
| `503 … The Keystone service is temporarily unavailable`, donné par Nova, Neutron, Cinder | Ces services ne joignent pas Keystone : souvent le **DNS** du lab (Lab-Services éteinte ou figée) | `getent hosts internal.lab.test` ; ping `192.168.56.20` | § 11 |
| `401` pour un seul compte | Mot de passe, compte ou domaine désactivé | `openstack user show <u> --domain <d> -c enabled` ; `openstack domain show <d> -c enabled` | Réactiver |
| `401` sur un jeton qui marchait | Jeton expiré ou révoqué | `openstack token issue` | Redemander un jeton |
| `CERTIFICATE_VERIFY_FAILED` | Le cloud est en HTTPS et le client ne connaît pas la CA | `grep OS_CACERT ~/admin-openrc` | `sunbeam openrc > ~/admin-openrc` (`6-securite/01-chiffrement-tls.md`) |

Journaux de Keystone : le refus `403` y nomme la règle (`ForbiddenAction … identity:list_users`) ; un échec `401` y donne l’adresse d’origine, mais **pas** le compte visé (`6-securite/06-audit-tracabilite.md`, § 6.3).

```bash
sudo k8s kubectl -n openstack logs keystone-0 -c keystone --since=10m | grep -E "ERROR|WARNING" | tail -5
```

---

## 5. MySQL et les routeurs : la base de données

**Rôle :** chaque service (Keystone, Nova, Neutron…) range ses données dans `mysql`, en passant par **son** routeur (`nova-mysql-router`, `keystone-mysql-router`…). Sans base, les services ne démarrent pas ou répondent `500`.

```bash
juju status -m openstack mysql
juju status -m openstack --format short | grep mysql-router
```

✅ **Attendu :** `mysql/0` `active` avec le message `Primary`, et tous les routeurs `active`.

### Le cas typique : juste après le démarrage de Lab-Sunbeam

Constaté le 18 octobre, dans les 10 minutes qui suivent le démarrage :

| Unité | État | Explication |
|---|---|---|
| `mysql/0` | `maintenance` « Starting mysqld » | **La cause** : la base démarre |
| `*-mysql-router/0` | `error` « hook failed: "start" » | Le routeur a tenté de joindre la base trop tôt ; son hook a planté une fois |
| `nova`, `neutron`, `placement` | `blocked` « healthcheck failed: online » | Les services ne joignent pas leur base, leur test de santé échoue |

**Pourquoi corriger dans cet ordre :** les services dépendent des routeurs, qui dépendent de `mysql`. Réparer en haut avant en bas ne sert à rien.

1. Attendre `mysql/0 … active … Primary` (relancer `juju status -m openstack mysql` toutes les 30 s).
2. Relancer les unités en `error`. Une unité en `error` ne réessaie **jamais** seule : `juju resolved` relance le hook qui a échoué.

   ```bash
   for u in $(juju status -m openstack --format short | grep "workload:error" | sed "s/^- \([^:]*\):.*/\1/"); do echo "$u"; juju resolved -m openstack "$u"; done
   ```

3. Attendre : les `blocked` repassent `active` d’eux-mêmes, 1 à 3 minutes plus tard (Pebble refait son test). `neutron` est souvent le dernier.

✅ **Attendu :** `juju status -m openstack --format short | grep -v "workload:active"` ne renvoie plus rien.

⛔ **Si une unité repasse en `error` juste après `juju resolved`**, la base n’était pas la cause : lire son `debug-log` (§ 3.1). **Si `mysql/0` reste en `maintenance` plus de 20 minutes** : `juju debug-log -m openstack --replay --no-tail --include mysql/0 | tail -30`.

---

## 6. Glance : les images

**Rôle :** stocke les images des VM, dans **Ceph** sur ce lab.

```bash
openstack image list
juju status -m openstack glance --format short
```

| Symptôme | Cause | Vérification |
|---|---|---|
| Envoi d’image refusé (`413`, « too large »), `juju status` tout `active` | Un réglage de Glance (`image_size_cap`), que le charm ne surveille pas | `sudo k8s kubectl -n openstack logs glance-0 -c glance-api --since=1h \| grep -i "too large"` ; guide `DEMOS-PANNES.md`, partie 2 |
| Création de VM en `ERROR`, `HTTP 502` Glance dans les journaux de Nova | Ceph ne répond pas : Glance ne peut pas lire l’image | § 10 |

---

## 7. Nova et Placement : les VM

**Rôle :** Nova crée les VM. Il est découpé en morceaux :

| Morceau | Où | Rôle |
|---|---|---|
| `nova-api` | pod `nova-0` | Reçoit les demandes (`openstack server …`) |
| `nova-scheduler` | pod `nova-0` | Choisit l’hyperviseur, en demandant à **Placement** les capacités libres |
| `nova-conductor` | pod `nova-0` | Fait le lien avec la base |
| `nova-compute` | snap `openstack-hypervisor`, sur la machine | Lance réellement la VM avec libvirt et KVM |
| Placement | pod `placement-0` | Tient l’inventaire (vCPU, RAM, disque) de chaque hyperviseur |

```bash
openstack compute service list -c Binary -c State -c "Updated At"
openstack hypervisor list
juju status -m openstack nova placement --format short
```

✅ **Attendu :** les trois services `up`, un hyperviseur, les unités `active`.

### Une VM en `ERROR` : la démarche

```bash
openstack server show <vm> -c status -c fault
openstack server event list <vm>
```

**Pourquoi :** le champ `fault` donne le message d’erreur que Nova a gardé ; `event list` donne les actions et leur identifiant de requête, à rechercher ensuite dans les journaux (`6-securite/06-audit-tracabilite.md`, § 6.4).

| Message dans `fault` ou symptôme | Cause probable | Où regarder |
|---|---|---|
| `No valid host was found` | Le scheduler n’a trouvé aucun hyperviseur : `nova-compute` `down`, ou plus de place | `compute service list` ; Placement |
| `HTTP 502` Glance | Ceph | § 10 |
| `Quota exceeded for instances` | Quota du projet | `openstack quota show --usage <projet>` |
| VM `ACTIVE` mais ni ping ni SSH, `Kernel panic` dans la console | EPT actif sur le lab (KVM imbriqué) | `openstack console log show <vm>` ; `cat /sys/module/kvm_intel/parameters/ept` doit répondre `N` (guide apprenant, 10.3) |
| Plus aucune VM ne se crée, `placement` `blocked … healthcheck failed` | Placement ne répond plus | Guide `DEMOS-PANNES.md`, partie 5 |

### `nova-compute` `down`

```bash
snap services openstack-hypervisor
sudo journalctl -u snap.openstack-hypervisor.nova-compute --since "-15min" --no-pager | grep -E "ERROR|WARNING" | tail -5
```

Exemple constaté le 18 octobre, juste après la désactivation du TLS : `DiscoveryFailure: Could not find versioned identity endpoints` ; `nova-compute` cherchait Keystone à une adresse qui venait de changer. Il s’est rétabli seul quand le snap l’a relancé (quelques minutes). Si ce n’est pas le cas, vérifier l’adresse de Keystone qu’il utilise (non joué sous cette forme : on a lu toute la section `identity`) : `sudo snap get openstack-hypervisor identity.auth-url`.

⚠ Ne pas lancer `sudo snap get openstack-hypervisor identity` sans nom de clé : la réponse contient **le mot de passe** du compte de service.

---

## 8. Neutron et OVN : le réseau

**Rôle :** Neutron reçoit les demandes (réseaux, routeurs, IP flottantes, groupes de sécurité) et les traduit pour **OVN**, qui réalise le réseau virtuel : `ovn-central` (la base de description du réseau), `ovn-relay`, et `ovn-controller` sur la machine (qui applique les règles au trafic des VM).

```bash
openstack network agent list -c Binary -c Alive
juju status -m openstack neutron ovn-central ovn-relay --format short
```

✅ **Attendu :** `ovn-controller` et `neutron-ovn-metadata-agent` à `True` ; les unités `active`.

| Symptôme | Cause probable | Vérification |
|---|---|---|
| `neutron` `blocked … (container:neutron-server) healthcheck failed: online` | `neutron-server` ne répond pas : au démarrage, base pas prête (§ 5) | `pebble checks` puis `logs` du conteneur `neutron-server` (§ 3.2) |
| Commandes réseau en `503` | Le pod Neutron ne répond pas, ou ne joint pas Keystone | `get pod neutron-0`, puis § 4 |
| Agent `ovn-controller` à `False` | Le réseau n’est plus appliqué sur la machine : VM injoignables | `juju status -m admin/openstack-machines --format short` ; journaux de la machine (non joué) |
| VM sans ping depuis l’extérieur, mais `ACTIVE` | Groupe de sécurité, IP flottante, ou la VM elle-même | `openstack server show <vm> -c addresses -c security_groups` ; console de la VM |
| VM : ping Internet OK, mais `apt` et HTTPS bloqués | MTU de `provider0` à 1500 sur Lab-Services | `ip link show provider0` doit afficher `mtu 1442` (guide apprenant, 10.4) |

**Lire un `neutron` `blocked` qui ne revient pas**, dans cet ordre :

1. `pebble checks` : le test `online` est-il `down`, avec combien d’échecs ?
2. `pebble services` : le processus `neutron-server` est-il `active` ? S’il ne l’est pas, Pebble n’a pas réussi à le lancer.
3. `logs --tail=30` : chercher une erreur de connexion à la base (`OperationalError`, `Can't connect to MySQL`), à RabbitMQ, ou à Keystone (`503`).
4. Selon l’erreur : § 5 (base), § 9 (RabbitMQ), § 4 (Keystone).

---

## 9. RabbitMQ : la messagerie

**Rôle :** les morceaux d’un service se parlent par messages (par exemple `nova-api` → `nova-conductor` → `nova-compute`). Si RabbitMQ ne répond plus, les demandes sont acceptées mais **restent bloquées** : VM en `BUILD` sans fin, volumes en `creating`.

```bash
juju status -m openstack rabbitmq --format short
```

✅ **Attendu :** `active`.

Symptôme typique : une action qui ne finit jamais, sans erreur. Chercher `AMQP` ou `rabbit` dans les journaux du service concerné (non joué sur le lab) :

```bash
sudo k8s kubectl -n openstack logs nova-0 -c nova-conductor --since=15m | grep -i -E "amqp|rabbit" | tail -5
```

---

## 10. Cinder et Ceph : les volumes et le stockage

**Rôle :** Cinder gère les volumes. Son API et son scheduler tournent dans un pod ; **`cinder-volume`**, qui crée réellement les volumes, est un snap sur la machine, et s’appuie sur **Ceph** (snap `microceph`). Ceph stocke aussi les images de Glance.

```bash
openstack volume service list -c Binary -c Host -c State -c "Updated At"
sudo ceph -s | grep -E "health:|osd:|pgs:"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
```

✅ **Attendu :** `cinder-volume … up` ; Ceph `1 osds: 1 up` et `289 active+clean` (le `HEALTH_WARN` « pools have no replicas configured » est normal sur un nœud unique) ; `microceph/0` et `cinder-volume/0` `active`.

| Symptôme | Cause | Correction |
|---|---|---|
| Volume en `error` ; `cinder-volume … down`, `Updated At` figé | Le service `cinder-volume` est arrêté, ou n’a plus accès au stockage | Ci-dessous |
| `cinder-volume` `down` alors que tout est `active` dans Juju | Le snap a été arrêté à la main : le charm ne le voit pas | `snap services cinder-volume` ; `snap changes` ; guide `DEMOS-PANNES.md`, partie 3 |
| `microceph/0 … blocked` « Error in charm: timed out », puis `cinder-volume/0 … waiting` « Not all relations are ready » | Les deux charms ont dépassé un délai au démarrage et sont restés figés | Relancer leur configuration, **MicroCeph d’abord** (ci-dessous) |
| Ceph `0 osds up` | Le disque de l’OSD n’est plus rattaché | Guide apprenant, 10.2 |

**Relancer la configuration des charms**, dans l’ordre des dépendances (Cinder dépend de Ceph) :

```bash
juju exec -m admin/openstack-machines --unit microceph/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
juju exec -m admin/openstack-machines --unit cinder-volume/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
juju status -m admin/openstack-machines --format short | grep -E "microceph/|cinder-volume/"
```

**La commande, mot par mot :** `juju exec --unit … --` lance une commande dans l’unité ; `JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch` rejoue l’étape « configuration modifiée » du charm, qui remet le service dans l’état voulu. On préfère passer par le charm plutôt que `snap start` : c’est lui qui sait dans quel état tout doit être.

**Vérifier avec un vrai volume :**

```bash
source ~/demo-openrc
openstack volume create lab-vol-test --size 1 -c status
openstack volume show lab-vol-test -c status
openstack volume delete lab-vol-test
source ~/admin-openrc
```

✅ **Attendu :** `available` en moins d’une minute. Un volume demandé **pendant** la panne peut rester en `creating` : le supprimer et recommencer.

---

## 11. Horizon, Traefik et le DNS : l’accès

**Rôle :** Traefik reçoit tout le trafic HTTP du cloud et le répartit vers les pods ; Horizon est l’interface web ; le DNS du lab (Lab-Services) donne les adresses de `cloud.lab.test`, `internal.lab.test`, `sso.lab.test`.

```bash
sunbeam dashboard url
curl -s -o /dev/null -w "%{http_code}\n" http://cloud.lab.test/openstack-horizon/auth/login/
getent hosts internal.lab.test
juju status -m openstack horizon traefik traefik-public --format short
```

✅ **Attendu :** l’adresse d’Horizon, `200`, une adresse pour `internal.lab.test`, les unités `active`.

| Symptôme | Cause probable | Vérification |
|---|---|---|
| Horizon `503` juste après le démarrage | Services pas encore prêts | Attendre 10 à 15 min, puis § 5 |
| `503 … Keystone service is temporarily unavailable` partout | Lab-Services éteinte ou figée : plus de DNS | `ping -c 2 192.168.56.20` ; `getent hosts sso.lab.test` |
| Lab-Services répond au ping mais pas en SSH | Noyau figé (constaté le 18 octobre : `rcu_preempt detected expedited stalls` en boucle sur sa console) | VirtualBox : **Éteindre**, puis Démarrer (*Réinitialiser* n’a pas suffi) |
| `traefik-public` en `maintenance` « updating ingress configurations » | Traefik recharge sa configuration (régulier, quelques secondes) | Rien |

---

## 12. Fiche réflexe

| Symptôme | Aller à |
|---|---|
| Écran rouge juste après le démarrage (`mysql` en `maintenance`, routeurs en `error`, services `blocked`) | § 5 |
| `HTTP 500` sur toute commande | § 4 puis § 5 |
| `503 … Keystone service is temporarily unavailable` | § 11 (DNS, Lab-Services), puis § 4 |
| `401` / `403` | § 1 (codes), § 4 |
| VM en `ERROR` | § 7 (`server show -c fault`) |
| VM en `BUILD` sans fin, volume en `creating` sans fin | § 9, puis § 10 |
| VM `ACTIVE` injoignable | § 8, puis EPT (§ 7) |
| Volume en `error` | § 10 |
| `juju status` tout `active`, mais une action échoue | § 2 (avertissement) : partir du symptôme, lire les journaux du service |
| Une unité reste en `error` après `juju resolved` | `juju debug-log --include <unité>` (§ 3.1) |

Pour s’entraîner sur des pannes réelles, provoquées puis réparées : guide `DEMOS-PANNES.md` (Glance, cinder-volume, Placement).
