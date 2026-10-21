# La CLI Juju sur un cloud Sunbeam, expliquée pas à pas

Ce guide montre comment **observer et dépanner** un cloud Sunbeam avec la commande `juju`. Il est construit autour de **sept démos** jouables sur le lab. Pour chaque commande, tu trouveras toujours :

| Rubrique | Ce qu’elle contient |
|---|---|
| 🎯 **Objectif** | **Pourquoi** on lance la commande : s’informer, contrôler, diagnostiquer, corriger ou vérifier (voir § 1) |
| **À quoi ça sert** | La question à laquelle la commande répond, et quand la lancer |
| **La commande, mot par mot** | Le rôle de chaque mot et de chaque option |
| **Ce que tu vois** | La sortie **réelle**, relevée sur le lab |
| **Comment le lire** | Colonne par colonne, valeur par valeur |
| **Si tu vois autre chose** | Ce que signifie un résultat différent, et quoi faire |

Les commandes marquées ✅ ont été exécutées sur le lab : Juju 3.6.29, contrôleur `sunbeam-controller`, déploiement `star-heron`. Les sorties datent du 16 et du 17 octobre ; elles sont parfois abrégées (`…`). Les concepts de base (contrôleur, modèle, charm…) sont aussi dans la fiche `demo-juju/Juju-Concepts-et-Commandes-Sunbeam.md`.

**Où taper les commandes :** dans **Lab-Sunbeam**, avec le compte `vagrant`. Depuis Windows :

```powershell
ssh vagrant@192.168.56.10
```

---

## 1. À quoi sert Juju sur Sunbeam

### L’idée

`sunbeam` décide **quoi** déployer. **Juju** le réalise : il installe chaque composant, le relie aux autres, lui applique sa configuration, puis **surveille** son état en permanence. Pour l’exploitant, Juju est donc la **vue d’administration** du cloud.

```text
 sunbeam  ──►  Terraform  ──►  Juju (contrôleur sunbeam-controller)
                                 │
                                 ├── modèle « openstack »                  (Kubernetes)
                                 │     keystone, nova, neutron, glance, mysql, rabbitmq…   25 applications
                                 │
                                 └── modèle « admin/openstack-machines »   (la machine elle-même)
                                       k8s, microceph, openstack-hypervisor, cinder-volume…
```

### Les mots à connaître

| Mot | Ce que c’est | Exemple sur le lab |
|---|---|---|
| **Contrôleur** | Le serveur Juju qui pilote tout | `sunbeam-controller` |
| **Modèle** | Un espace de travail, qui regroupe des applications | `openstack`, `admin/openstack-machines` |
| **Charm** | Le programme qui sait installer, configurer et surveiller un logiciel | `keystone-k8s`, `microceph` |
| **Application** | Un logiciel déployé à partir d’un charm | `keystone` |
| **Unité** | Une instance de l’application ; elle se note `application/numéro` | `keystone/0` |
| **Hook** | Une étape du charm, déclenchée par un événement : `start`, `config-changed`, `update-status`… | — |
| **Relation** | Un lien entre deux applications, par lequel elles échangent des informations | `keystone` ↔ `keystone-mysql-router` |
| **Action** | Une opération d’administration fournie par le charm | `mysql` : `get-cluster-status` |

### Les deux états d’une unité

Juju affiche toujours **deux** états par unité. C’est la clé pour lire toutes les sorties de ce guide :

| État | Il décrit | Valeurs |
|---|---|---|
| **Workload** | Le **service** (Keystone, Ceph…) tel que le charm le voit | `active` (tout va bien), `waiting` (attend un autre service), `maintenance` (s’installe ou se reconfigure), `blocked` (a besoin d’une intervention humaine), `error`, `unknown` |
| **Agent** | L’**agent Juju** de l’unité, qui exécute le charm | `idle` (au repos), `executing` (exécute un hook), `error` (un hook a échoué), `lost` (ne répond plus) |

L’état normal est **`active` / `idle`**.

### Les cinq objectifs d’une commande Juju

Une commande Juju se lance toujours pour l’un de ces **cinq objectifs**. Savoir dans lequel on se trouve évite d’enchaîner des commandes au hasard : on sait ce qu’on cherche, donc on sait quand on l’a trouvé.

| Objectif | Question posée | Commandes | Ce qu’elles apportent |
|---|---|---|---|
| **S’informer** | Qu’y a-t-il, qui suis-je, à quoi ai-je accès ? | `whoami`, `controllers`, `models`, `show-model`, `status`, `offers`, `actions`, `operations`, `secrets` | Connaître le cloud **avant** d’agir : les bons noms, les bons modèles, les bons droits, et la trace de ce qui a été fait (audit) |
| **Contrôler** | Tout va-t-il bien ? | `status --format summary`, `status --format short \| grep -v "workload:active"`, `run mysql/0 get-cluster-status` | Un **verdict** rapide : si rien ne s’affiche, tout est `active` ; sinon, la liste des unités à regarder |
| **Diagnostiquer** | Depuis quand ? Qu’est-ce qui a changé ? Pourquoi ? | `show-status-log`, `config`, `debug-log`, `ssh`, `exec`, `show-unit` | **Dater** la panne, trouver le **réglage modifié**, lire l’**erreur**, regarder **dans** le service |
| **Corriger** | Comment revenir à l’état voulu ? | `config … --reset`, `resolved`, `exec … config-changed` | Réparer **par Juju**, qui garde la configuration cohérente ; une correction faite à la main dans un conteneur serait écrasée |
| **Vérifier** | La correction a-t-elle pris ? | Le même test que celui qui révélait le problème, et un test **du service lui-même** (`ceph -s`, une API, une VM) | La preuve : le symptôme a disparu. ⚠ `active` dans Juju ne suffit pas : c’est l’état que le charm **déclare** |

Chaque étape des démos commence par une ligne 🎯 **Objectif** qui indique lequel des cinq elle sert. Le fichier `DEMOS-PANNES.md` du même dossier applique cette méthode à de vraies pannes, provoquées puis corrigées.

**Règle d’or :** Juju sert à **observer et dépanner**. Pour changer l’architecture (ajouter un service, un nœud, changer de version), passer par `sunbeam`. Une modification faite avec `juju` peut être **écrasée** par la prochaine commande `sunbeam`.

---

## 2. Syntaxe générale

```text
juju <commande> [-m [propriétaire/]modèle] [cible] [options]
```

Exemple : `juju status -m openstack keystone --format short`

| Morceau | Ici | Rôle |
|---|---|---|
| `juju` | | La commande |
| `<commande>` | `status` | L’action : afficher l’état |
| `-m modèle` | `-m openstack` | Le modèle visé. Sans `-m`, Juju utilise le modèle courant ; sur le lab il n’y en a pas, donc **toujours préciser `-m`** |
| `[cible]` | `keystone` | Une application (`keystone`), une unité (`keystone/0`) ou une machine (`0`) |
| `[options]` | `--format short` | Le format de sortie |

| Option ou forme | Effet |
|---|---|
| `-m openstack` | Le modèle des services OpenStack |
| `-m admin/openstack-machines` | Le modèle de la machine. Le préfixe `admin/` est **obligatoire** (voir démo 1) |
| `--format tabular` | Tableau lisible (par défaut) |
| `--format short` | Une ligne par unité : pratique avec `grep` |
| `--format summary` | Des compteurs |
| `--format yaml` / `json` | Pour les scripts |
| `juju help <commande>` | L’aide d’une commande |

---

## 3. Démo 1 : se repérer dans Juju (5 min) ✅

**But de la démo :** savoir qui on est, sur quel contrôleur, et quels modèles existent. C’est le préalable à toute autre commande.

### Étape 0 : renouveler la session

🎯 **Objectif : préalable.** Sans session valide, aucune commande Juju ne répond ; on élimine d’emblée cette fausse panne.

```bash
sunbeam utils juju-login
```

**À quoi ça sert :** après un redémarrage du lab, la session Juju a souvent expiré. Sans cette commande, Juju répond `Failed to login to Juju Controller`. **Ce que tu vois :** `Juju re-login complete.`

### Étape 1 : qui suis-je ?

🎯 **Objectif : s’informer.** Vérifier avec quel compte et sur quel contrôleur on travaille, avant toute action : on évite d’agir sur le mauvais cloud ou de se heurter à des droits insuffisants.

```bash
juju whoami
```

**Ce que tu vois :**

```text
Controller:  sunbeam-controller
Model:       <no-current-model>
User:        sunbeam
```

**Comment le lire :**

| Ligne | Valeur | Signification |
|---|---|---|
| `Controller` | `sunbeam-controller` | Le contrôleur Juju du cloud |
| `Model` | `<no-current-model>` | Aucun modèle par défaut : il faut donner `-m` à chaque commande |
| `User` | `sunbeam` | L’utilisateur Juju avec lequel `sunbeam utils juju-login` t’a connecté |

### Étape 2 : les contrôleurs

🎯 **Objectif : s’informer.** Repérer, parmi les contrôleurs connus de cette machine, celui qui pilote le cloud.

```bash
juju controllers
```

**Ce que tu vois :**

```text
Controller           Model  User     Access     Cloud/Region         Models  Nodes    HA  Version
localhost-localhost  -      admin    superuser  localhost/localhost       2      1  none  3.6.29
sunbeam-controller*  -      sunbeam  superuser                            3      1     -  3.6.29
```

**Comment le lire :**

| Colonne | Signification |
|---|---|
| `Controller` | Le nom ; l’**astérisque** marque le contrôleur courant |
| `User` / `Access` | Ton compte sur ce contrôleur, et ses droits (`superuser` = tous) |
| `Models` | Le nombre de modèles qu’il gère |
| `Nodes` / `HA` | Le nombre de nœuds du contrôleur ; `HA` = haute disponibilité (`none` : un seul nœud) |
| `Version` | La version de Juju |

`localhost-localhost` est un contrôleur LXD local, **sans rapport** avec OpenStack. Celui du cloud est `sunbeam-controller`.

### Étape 3 : les modèles

🎯 **Objectif : s’informer.** Connaître les espaces de travail et leur **nom exact**, celui qu’il faudra donner à `-m` dans toutes les commandes suivantes.

```bash
juju models
```

**Ce que tu vois :**

```text
Controller: sunbeam-controller

Model                     Cloud/Region              Type        Status     Machines  Cores  Units  Access  Last connection
admin/controller          star-heron-k8s/localhost  kubernetes  available         0      -  1      admin   just now
openstack                 star-heron-k8s/localhost  kubernetes  available         0      -  25     admin   19 minutes ago
admin/openstack-machines  star-heron/default        manual      available         1      8  7      admin   11 minutes ago
```

**Comment le lire :**

| Colonne | Signification |
|---|---|
| `Model` | Le nom. Le préfixe `admin/` signifie que le modèle **appartient à l’utilisateur Juju `admin`**, et non à toi (`sunbeam`) |
| `Cloud/Region` | Où le modèle déploie : `star-heron-k8s` = le Kubernetes du cloud ; `star-heron` = les machines |
| `Type` | `kubernetes` : les unités sont des **pods** ; `manual` : les unités tournent sur une machine ajoutée à la main |
| `Status` | `available` = le modèle fonctionne |
| `Machines` / `Cores` | Les machines du modèle : 1 machine de 8 cœurs pour `openstack-machines` |
| `Units` | Le nombre d’unités : 25 services OpenStack, 7 composants sur la machine |

| Modèle | Contenu |
|---|---|
| `openstack` | Les 25 services du plan de contrôle : Keystone, Nova, Neutron, Glance, Cinder, Horizon, MySQL, RabbitMQ, OVN, Traefik… |
| `admin/openstack-machines` | La VM `sunbeam` : Kubernetes, MicroCeph, l’hyperviseur, cinder-volume |
| `admin/controller` | Le contrôleur Juju lui-même |

**Si tu vois autre chose :** `juju status -m openstack-machines` répond `model sunbeam:sunbeam/openstack-machines not found`. Sans préfixe, Juju cherche un modèle de l’utilisateur courant (`sunbeam`) ; il faut écrire **`-m admin/openstack-machines`**.

### Étape 4 : le détail d’un modèle

🎯 **Objectif : s’informer (audit).** Savoir à qui appartient un modèle, de quel type il est, et combien de secrets il garde : utile pour un contrôle de sécurité.

```bash
juju show-model openstack | grep -E "owner|type|num-secrets"
```

**La commande, mot par mot :** `show-model openstack` affiche toute la fiche du modèle ; `grep -E "a|b|c"` ne garde que les lignes qui contiennent l’un de ces mots.

**Ce que tu vois :**

```text
  model-type: caas
  owner: sunbeam
  type: kubernetes
      num-secrets: 54
```

**Comment le lire :** `caas` (*containers as a service*) = modèle Kubernetes ; `owner: sunbeam` = ce modèle t’appartient, d’où l’absence de préfixe ; `num-secrets: 54` = Juju garde **54 secrets** pour ce modèle (mots de passe des bases, clés de Keystone, certificats). La démo 7 montre comment les consulter sans les révéler.

---

## 4. Démo 2 : un état de santé en 30 secondes (5 min) ✅

**But de la démo :** répondre à la question « est-ce que tout va bien ? », et si non, trouver **où** est le problème.

### Étape 1 : les compteurs

🎯 **Objectif : contrôler.** Un verdict global en une commande : toutes les unités sont-elles `active` ?

```bash
juju status -m openstack --format summary
```

**Ce que tu vois :**

```text
                 # Machines:  (0)

                    # Units:  (25)
                     active:   25

             # Applications:  (25)
```

**Comment le lire :** 25 unités, et **25** en `active`. Si une unité allait mal, une ligne comme `blocked: 1` apparaîtrait. `Machines: (0)` est normal : dans un modèle Kubernetes, les unités sont des pods, pas des machines.

### Étape 2 : seulement ce qui ne va pas

🎯 **Objectif : contrôler.** Si le verdict n’est pas bon, isoler **les seules unités** en anomalie, au lieu de lire 25 lignes.

```bash
juju status -m openstack --format short | grep -v "workload:active"
juju status -m admin/openstack-machines --format short | grep -v "workload:active"
```

**La commande, mot par mot :** `--format short` = une ligne par unité, sous la forme `- unité: adresse (agent:…, workload:…)` ; `grep -v` = **retirer** les lignes qui contiennent le motif. Il ne reste donc que les unités qui ne sont **pas** `active`.

Une ligne au format `short`, pour comprendre ce qu’on filtre :

```text
- glance/0:  (agent:idle, workload:active)
```

**Ce que tu vois** le 17 octobre : **rien**. Les deux commandes ne renvoient aucune ligne : toutes les unités sont actives.

**Ce que tu voyais** le 16 octobre, avant la réparation :

```text
- cinder-volume/0: 10.0.2.15 (agent:idle, workload:waiting)
- microceph/0: 10.0.2.15 (agent:idle, workload:blocked)
```

**Comment le lire :** l’agent est au repos (`idle`) mais le service n’est pas prêt : MicroCeph a besoin d’une intervention (`blocked`), et cinder-volume attend MicroCeph (`waiting`). Le premier est la **cause**, le second la **conséquence**. La démo 4 cherche la cause.

### Étape 3 : le tableau d’une application

🎯 **Objectif : diagnostiquer.** Sur une application suspecte, lire le détail : version, message du charm, unité leader, adresse.

```bash
juju status -m openstack keystone
```

**La commande, mot par mot :** `keystone` après le modèle = n’afficher que cette application. On peut en donner plusieurs : `juju status -m openstack nova neutron`.

**Ce que tu vois :**

```text
Model      Controller          Cloud/Region              Version  SLA          Timestamp
openstack  sunbeam-controller  star-heron-k8s/localhost  3.6.29   unsupported  08:04:47Z

SAAS           Status  Store  URL
cinder-volume  active  local  admin/openstack-machines.cinder-volume
microceph      active  local  admin/openstack-machines.microceph

App       Version  Status  Scale  Charm         Channel        Rev  Address        Exposed  Message
keystone           active      1  keystone-k8s  2024.1/stable  440  10.152.183.97  no

Unit         Workload  Agent  Address     Ports  Message
keystone/0*  active    idle   10.1.0.191

Offer                 Application  Charm         Rev  Connected  Endpoint              Interface             Role
keystone-credentials  keystone     keystone-k8s  440  2/2        identity-credentials  keystone-credentials  provider
keystone-endpoints    keystone     keystone-k8s  440  1/1        identity-service      keystone              provider
…
```

**Comment le lire**, bloc par bloc :

| Bloc | Colonne | Signification |
|---|---|---|
| En-tête | `Timestamp` | L’heure de la mesure (UTC) |
| `SAAS` | | Les services **d’un autre modèle** que ce modèle utilise : ici Ceph et cinder-volume, qui tournent sur la machine |
| `App` | `Status` | L’état de l’application |
| | `Scale` | Le nombre d’unités : `1`, pas de redondance |
| | `Charm` / `Channel` / `Rev` | Le charm, sa branche (`2024.1/stable`) et sa révision (`440`) |
| | `Address` | L’adresse du service dans Kubernetes |
| | `Message` | Le message du charm : vide quand tout va bien, explicatif sinon |
| `Unit` | `keystone/0*` | L’unité ; l’**astérisque** désigne le **leader**, l’unité qui prend les décisions pour l’application |
| | `Workload` / `Agent` | Les deux états (voir § 1) : `active` / `idle` |
| | `Address` | L’adresse du **pod** |
| `Offer` | | Ce que ce modèle **met à disposition** d’autres modèles ; `Connected 2/2` = 2 consommateurs sur 2 connectés |

**Si tu vois autre chose :**

| Ce que tu vois | Signification | Que faire |
|---|---|---|
| `Message` rempli | Le charm explique ce qui ne va pas | Le lire en premier |
| `waiting` | Attend un autre service, souvent nommé dans le message | Regarder l’état du service attendu |
| `blocked` | Besoin d’une intervention | Démo 4 |
| Agent `error`, message `hook failed: "…"` | Une étape du charm a échoué | Démo 3 |
| Agent `lost` | L’agent ne répond plus (pod ou machine arrêté) | Vérifier le pod ou la machine |

⚠ Les jokers ne fonctionnent pas : `juju status keystone*` n’affiche aucune application.

### Étape 4 : la machine et le lien entre les modèles

🎯 **Objectif : s’informer.** Voir ce qui tourne sur la machine, et comment ses composants sont fournis au modèle `openstack` : c’est ce qui explique qu’une panne de Ceph apparaisse dans les deux modèles.

```bash
juju status -m admin/openstack-machines
```

**Ce que tu vois** (abrégé) :

```text
App                   Version  Status  Scale  Charm                 Channel         Rev  Exposed  Message
cinder-volume                  active      1  cinder-volume         2024.1/stable   180  no
k8s                   1.32.13  active      1  k8s                   1.32/stable    1921  no       Ready
microceph                      active      1  microceph             squid/stable    331  no
openstack-hypervisor           active      1  openstack-hypervisor  2024.1/stable   458  no
sunbeam-machine                active      1  sunbeam-machine       2024.1/stable   221  no
…
Unit                     Workload  Agent  Machine  Public address  Ports     Message
cinder-volume/0*         active    idle   0        10.0.2.15
  cinder-volume-ceph/0*  active    idle            10.0.2.15
k8s/0*                   active    idle   0        10.0.2.15       6443/tcp  Ready
microceph/0*             active    idle   0        10.0.2.15
…
Machine  State    Address    Inst id               Base          AZ  Message
0        started  10.0.2.15  manual:192.168.56.10  ubuntu@24.04      Manually provisioned machine

Offer               Application    Charm          Rev  Connected  Endpoint         Interface        Role
cinder-volume       cinder-volume  cinder-volume  180  1/1        storage-backend  cinder-backend   provider
microceph           microceph      microceph      331  1/1        ceph             ceph-client      provider
```

**Comment le lire :**

- **`App`** : les composants installés directement sur la VM : Kubernetes 1.32 (`k8s`), Ceph (`microceph`, branche `squid`), l’hyperviseur, le service de volumes ;
- **`Unit`** : toutes sur la machine `0`. Une unité **en retrait** (`  cinder-volume-ceph/0*`) est un **subordonné** : un charm qui s’ajoute à un autre sur la même machine, ici le pilote Ceph de cinder-volume ;
- **`Public address 10.0.2.15`** : c’est l’adresse de la **carte 1 (NAT)** de la VM, que Juju choisit par défaut ; elle n’est pas utilisée pour joindre les services ;
- **`Machine`** : la machine `0`, `started` ; `Inst id manual:192.168.56.10` = elle a été ajoutée à la main par son adresse de gestion ; `Base ubuntu@24.04` = son système ;
- **`Offer`** : MicroCeph et cinder-volume sont **offerts** au modèle `openstack`. C’est pour cela qu’ils apparaissent dans la section `SAAS` de l’étape 3, et qu’un problème de Ceph se voit **dans les deux modèles**.

### Étape 5 : les offres en détail

🎯 **Objectif : contrôler.** Vérifier que les liens entre les deux modèles sont bien établis (`joined`).

```bash
juju offers -m admin/openstack-machines
```

**Ce que tu vois :**

```text
Offer               User     Relation ID  Status  Endpoint         Interface       Role      Ingress subnets
cinder-volume       sunbeam  8            joined  storage-backend  cinder-backend  provider
microceph           sunbeam  9            joined  ceph             ceph-client     provider
microceph-ceph-nfs  -
microceph-ceph-rgw  -
```

**Comment le lire :** `User sunbeam` = consommé par le modèle de l’utilisateur `sunbeam`, donc `openstack` ; `Status joined` = le lien est établi ; `Interface` = le « protocole » de la relation (`ceph-client`) ; `Role provider` = ce modèle **fournit** le service. Les deux offres suivies de `-` existent mais **ne sont pas utilisées** (NFS et passerelle S3 de Ceph).

---

## 5. Démo 3 : reconstituer un incident réel (15 min) ✅

**Contexte :** après chaque redémarrage du lab, des unités `*-mysql-router` passaient en erreur, et Keystone répondait `HTTP 500` à toute connexion, donc plus rien ne marchait. On rejoue l’enquête avec la méthode **quand → quoi → pourquoi → corriger**.

### Étape 1 : quand, et quoi ? L’historique de l’unité

🎯 **Objectif : diagnostiquer (quand ?).** Dater le début de la panne, pour la relier à un événement : redémarrage, mise à jour, changement de configuration.

```bash
juju show-status-log -m openstack keystone-mysql-router/0
```

**À quoi ça sert :** voir l’**historique des états** d’une unité, avec l’heure de chaque changement. C’est le « journal de bord » de l’unité.

**Ce que tu vois** (extrait, 15 et 16 octobre) :

```text
15 Oct 2026 18:27:49Z  juju-unit  error        hook failed: "update-status"
15 Oct 2026 18:31:23Z  workload   maintenance  MySQL Router starting
16 Oct 2026 12:39:34Z  juju-unit  error        hook failed: "start"
16 Oct 2026 12:40:34Z  juju-unit  error        hook failed: "start"
16 Oct 2026 12:41:58Z  juju-unit  error        hook failed: "start"
```

**Comment le lire :**

| Colonne | Signification |
|---|---|
| Date | Heure UTC du changement (en France, ajouter 2 h en été) |
| `juju-unit` / `workload` | Quel état a changé : celui de l’**agent** (`juju-unit`) ou celui du **service** (`workload`) |
| `error`, `maintenance`… | Le nouvel état |
| Message | `hook failed: "start"` = l’étape `start` du charm a échoué |

Ici : le 16 octobre à 12 h 39 (le redémarrage du lab), le hook `start` échoue **trois fois** en trois minutes.

### Étape 2 : pourquoi ? Les journaux du charm

🎯 **Objectif : diagnostiquer (pourquoi ?).** Lire l’erreur précise qui a fait échouer le charm.

```bash
juju debug-log -m openstack --replay --no-tail --level ERROR --include keystone-mysql-router/0 | tail -4
```

**La commande, mot par mot :**

| Option | Effet |
|---|---|
| `debug-log` | Les journaux des agents et des charms du modèle |
| `--replay` | Relire depuis le début de l’historique conservé (sinon : seulement à partir de maintenant) |
| `--no-tail` | S’arrêter à la fin, au lieu d’attendre les lignes suivantes |
| `--level ERROR` | Ne garder que les erreurs (autres niveaux : `WARNING`, `INFO`, `DEBUG`) |
| `--include keystone-mysql-router/0` | Ne garder qu’une unité |
| `\| tail -4` | Ne montrer que les 4 dernières lignes |

**Ce que tu vois :**

```text
unit-keystone-mysql-router-0: … cannot open api: cannot resolve "controller-service.controller-sunbeam-controller.svc.cluster.local":
  lookup … on 10.152.183.236:53: dial udp 10.152.183.236:53: connect: operation not permitted
unit-keystone-mysql-router-0: … cannot open api: unable to connect to API: dial tcp 192.168.56.200:17070: connect: operation not permitted
```

**Comment le lire :**

| Morceau | Signification |
|---|---|
| `unit-keystone-mysql-router-0` | L’unité qui écrit |
| `cannot open api` | L’agent n’arrive pas à joindre le contrôleur Juju |
| `cannot resolve "controller-service…"` + `10.152.183.236:53` | Il n’arrive pas à **résoudre le nom** du contrôleur : `10.152.183.236` est le DNS interne de Kubernetes, port 53 |
| `dial tcp 192.168.56.200:17070` | Il n’arrive pas non plus à **joindre** le contrôleur par son adresse (`.200`, port 17070 de Juju) |
| `operation not permitted` | Le système refuse d’ouvrir la connexion : le réseau des pods n’est pas encore en place |

**Diagnostic :** au démarrage du lab, l’unité a démarré **avant** que le réseau des pods soit prêt. Son hook `start` a échoué, et Juju **ne relance pas** un hook en erreur de lui-même.

### Étape 3 : corriger

🎯 **Objectif : corriger, puis vérifier.** Relancer l’étape qui a échoué, une fois la cause disparue, et constater le retour à `active`.

```bash
juju resolved -m openstack keystone-mysql-router/0
```

**La commande, mot par mot :** `resolved` = « j’ai traité la cause, relance le hook qui a échoué ».

**Ce que tu vois :** rien à l’écran ; dans `juju status`, l’agent passe en `executing`, puis l’unité revient en `active` / `idle`.

**La chaîne de conséquences, à retenir :** routeur MySQL en erreur → Keystone n’atteint plus sa base → `HTTP 500` à chaque authentification → plus aucune commande `openstack` ni Horizon. Pour trouver toutes les unités concernées d’un coup :

```bash
juju status -m openstack --format short | grep "agent:error"
```

⚠ Toujours lire la cause **avant** `resolved` : si la cause est toujours là, le hook échoue de nouveau.

---

## 6. Démo 4 : enquêter sur MicroCeph `blocked` (10 min) ✅

**Contexte :** le 16 octobre, `sunbeam cluster list` affichait `Storage: blocked` et `juju status` montrait MicroCeph `blocked`. Ceph était-il vraiment en panne ?

### Étape 1 : le message du charm

🎯 **Objectif : diagnostiquer (quoi ?).** Lire ce que le charm dit de lui-même : c’est le premier indice.

```bash
juju status -m admin/openstack-machines microceph
```

**Ce que tu voyais :**

```text
microceph/0*  blocked  idle  0  10.0.2.15  (workload) Error in charm (see logs): timed out
```

**Comment le lire :** le service est `blocked`, l’agent est au repos (`idle`). Le message dit que le **charm** a eu une erreur (`Error in charm`), un délai dépassé (`timed out`), et renvoie aux journaux.

### Étape 2 : quand ?

🎯 **Objectif : diagnostiquer (quand ?).** Dater le blocage pour le relier au démarrage de la machine.

```bash
juju show-status-log -m admin/openstack-machines microceph/0 | tail -6
```

**Ce que tu vois** (17 octobre) :

```text
17 Oct 2026 06:27:38Z  juju-unit  executing  running action juju-exec
17 Oct 2026 06:28:10Z  workload   blocked    (workload) Error in charm (see logs): timed out
17 Oct 2026 06:28:27Z  juju-unit  idle
17 Oct 2026 08:03:20Z  workload   active
```

**Comment le lire :** le blocage apparaît quelques minutes après le démarrage du lab ; la dernière ligne montre le retour à `active` après la réparation (étape 5).

### Étape 3 : pourquoi ?

🎯 **Objectif : diagnostiquer (pourquoi ?).** Trouver dans les journaux l’erreur exacte et l’endroit du charm où elle s’est produite.

```bash
juju debug-log -m admin/openstack-machines --replay --no-tail --include microceph/0 | grep -B2 -A3 -m1 "Traceback"
```

**La commande, mot par mot :** on relit les journaux de l’unité, puis `grep` cherche la première (`-m1`) trace d’erreur Python (`Traceback`), avec 2 lignes avant (`-B2`) et 3 après (`-A3`).

**Ce que tu vois :**

```text
… ERROR unit.microceph/0.juju-log Exception raised in section 'Bootstrapping': timed out
… File ".../src/microceph.py", line 57, in is_ready
```

**Comment le lire :** pendant sa phase `Bootstrapping`, le charm a appelé sa vérification `is_ready` (« MicroCeph est-il prêt ? ») ; MicroCeph, lent à répondre pendant le démarrage de la machine, a dépassé le délai. Le charm s’est arrêté en `blocked`, **et n’a jamais réessayé**.

### Étape 4 : et Ceph lui-même ?

🎯 **Objectif : vérifier.** Tester le **service** lui-même, indépendamment de ce que déclare le charm : c’est ce test qui dit s’il y a une vraie panne.

```bash
juju ssh -m admin/openstack-machines 0 "sudo microceph status | head -5; sudo ceph -s | grep -E 'osd:|pgs:'"
```

**La commande, mot par mot :** `juju ssh … 0` = ouvrir une session sur la machine `0` du modèle et y lancer la commande entre guillemets ; `microceph status` = l’état des services Ceph ; `ceph -s` = la santé du cluster Ceph, dont on garde les disques (`osd`) et les groupes de données (`pgs`).

**Ce que tu vois :**

```text
MicroCeph deployment summary:
- sunbeam (192.168.56.10)
  Services: mds, mgr, mon, rgw, osd
    osd: 1 osds: 1 up, 1 in
    pgs:     289 active+clean
```

**Comment le lire :** tous les services Ceph tournent ; le disque (`osd`) est `up` (démarré) et `in` (utilisé) ; les 289 groupes de données sont `active+clean` (accessibles et complets). **Ceph est sain.**

**Ce qu’il faut retenir :** **l’état d’un charm n’est pas l’état du service.** Toujours confirmer avec un test du service lui-même (`ceph -s`, un appel d’API, une VM).

### Étape 5 : débloquer le charm

🎯 **Objectif : corriger.** Faire refaire au charm ses vérifications, pour qu’il constate que le service est sain.

`juju resolved` ne sert pas ici (l’agent n’est pas en erreur). Il faut faire **rejouer** au charm son hook de configuration :

```bash
juju exec -m admin/openstack-machines --unit microceph/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
```

**La commande, mot par mot :** `juju exec --unit microceph/0 --` = exécuter une commande dans le contexte du charm ; `JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch` = lancer le charm comme si Juju lui envoyait l’événement `config-changed`.

Le charm refait ses vérifications, trouve Ceph prêt et repasse en `active` (dernière ligne de l’étape 2). Faire de même ensuite pour `cinder-volume/0`, qui attendait MicroCeph. Procédure complète : guide `5-openstack-cli/`, démo 6.

---

## 7. Démo 5 : modifier un réglage, le voir appliqué, revenir en arrière (10 min) ✅

**But de la démo :** comprendre comment Juju applique une configuration, et ce que cela coûte.

### Étape 1 : lire la valeur actuelle

🎯 **Objectif : s’informer, puis diagnostiquer.** Connaître la valeur d’un réglage et surtout son **origine** : `default` (jamais touché) ou `user` (modifié). Devant un comportement inattendu, ce sont les `user` qu’on regarde en premier.

```bash
juju config -m openstack keystone log-level
```

**La commande, mot par mot :** `config` = lire ou modifier la configuration d’une application ; `keystone` = l’application ; `log-level` = l’option. Sans nom d’option, la commande affiche **toutes** les options.

**Ce que tu vois :** `WARNING` : Keystone n’écrit dans ses journaux que les avertissements et les erreurs.

Pour voir toutes les options avec leur **origine** :

```bash
juju config -m openstack keystone --format json | python3 -c "import sys,json; [print(k, '=', v.get('value'), '(', v.get('source'), ')') for k,v in sorted(json.load(sys.stdin)['settings'].items())]"
```

```text
catalog-cache-expiration = 60 ( default )
debug = False ( default )
identity-backend = sql ( default )
log-level = WARNING ( default )
region = RegionOne ( default )
saml-x509-keypair =  ( user )
…
```

**Comment le lire :** `default` = valeur d’origine du charm ; `user` = valeur **modifiée** par quelqu’un (ici par Sunbeam au déploiement). Devant un service au comportement inattendu, chercher les `user` est le premier contrôle à faire.

### Étape 2 : regarder le fichier dans le conteneur

🎯 **Objectif : vérifier.** Voir la valeur que le service **utilise réellement**, dans son propre fichier de configuration.

```bash
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- grep -E "^level" /etc/keystone/logging.conf | sed -n 2p
```

**La commande, mot par mot :** `k8s kubectl` = le client Kubernetes du lab ; `-n openstack` = l’espace de noms ; `exec keystone-0 -c keystone --` = lancer une commande dans le conteneur `keystone` du pod `keystone-0` ; `grep … | sed -n 2p` = afficher la 2ᵉ ligne qui commence par `level`.

**Ce que tu vois :** `level=WARNING`.

### Étape 3 : modifier

🎯 **Objectif : corriger (modifier un réglage).** Changer une valeur par Juju, qui la reporte lui-même dans le bon fichier du service.

```bash
juju config -m openstack keystone log-level=INFO
watch -n 3 "juju status -m openstack keystone --format short"
```

**Ce que tu vois :** `juju config` rend la main **immédiatement**, sans message. Dans `watch`, l’agent passe en `executing` puis revient en `idle`. L’historique (`juju show-status-log -m openstack keystone/0`) montre :

```text
14:58:21Z  juju-unit  executing  running config-changed hook
14:58:42Z  workload   active
14:58:44Z  juju-unit  idle
```

**Comment le lire :** Juju a déclenché le hook `config-changed` ; le charm a réécrit le fichier et redémarré Keystone, en **20 secondes**. Relancer la commande de l’étape 2 : `level=INFO`.

### Étape 4 : revenir à la valeur d’origine

🎯 **Objectif : corriger, puis vérifier.** Annuler la modification proprement avec `--reset`, et contrôler que le service est revenu à sa valeur d’origine.

```bash
juju config -m openstack keystone --reset log-level
juju config -m openstack keystone log-level
```

**Ce que tu vois :** `WARNING`, et l’étape 2 redonne `level=WARNING`.

**Ce qu’il faut retenir :**

1. la commande rend la main tout de suite ; c’est le charm qui applique ensuite le changement ;
2. le réglage n’est pas dans `keystone.conf` mais dans `logging.conf` : **le charm sait où écrire**, l’exploitant n’a pas à le savoir ;
3. lors d’un second essai, Keystone est passé `blocked (container:keystone) healthcheck failed` pendant 8 secondes, le temps de redémarrer. On le voit encore dans son historique :

   ```text
   16 Oct 2026 15:04:07Z  workload   blocked    (container:keystone) healthcheck failed: online
   ```

   Un changement de configuration **interrompt brièvement** le service, ici l’authentification de tout le cloud : à faire en fenêtre de maintenance ;
4. une modification faite avec `juju config` peut être écrasée par la prochaine commande `sunbeam`.

---

## 8. Démo 6 : utiliser une action (5 min) ✅

**But de la démo :** utiliser une opération d’administration prévue par le charm, plutôt qu’une commande tapée à la main dans le conteneur.

### Étape 1 : les actions disponibles

🎯 **Objectif : s’informer.** Savoir quelles opérations d’administration le charm propose : sauvegarde, bascule, contrôle avant mise à jour…

```bash
juju actions -m openstack mysql
```

**Ce que tu vois** (extrait) :

```text
Action               Description
create-backup        Create a database backup using xtrabackup. …
get-cluster-status   Get cluster status information
get-password         Fetch the system user's password, … SHOULD NOT be used by applications.
list-backups         List available backup_ids in the S3 bucket …
pre-upgrade-check    Run necessary pre-upgrade checks and preparations before executing a charm refresh.
promote-to-primary   Promotes the unit or cluster to become the primary …
restore              Restore a database backup using xtrabackup. …
```

**Comment le lire :** chaque ligne est une opération que le charm sait faire, avec sa description. On y trouve la sauvegarde et la restauration, la bascule, et le contrôle avant mise à jour.

### Étape 2 : lancer une action

🎯 **Objectif : contrôler.** Ici, demander à MySQL l’état de son cluster : un contrôle de santé que seul le charm sait faire proprement.

```bash
juju run -m openstack mysql/0 get-cluster-status
```

**La commande, mot par mot :** `run` = lancer une action ; `mysql/0` = sur quelle **unité** ; `get-cluster-status` = laquelle.

**Ce que tu vois :**

```text
status:
  clusterrole: primary
  defaultreplicaset:
    primary: mysql-0.mysql-endpoints.openstack.svc.cluster.local.:3306
    status: ok_no_tolerance
    statustext: cluster is not tolerant to any failures.
    topology:
      mysql-0: {memberrole: primary, mode: r/w, status: online}
```

**Comment le lire :**

| Ligne | Signification |
|---|---|
| `clusterrole: primary` | Ce cluster MySQL est le principal |
| `primary: mysql-0…:3306` | L’instance qui reçoit les écritures |
| `status: ok_no_tolerance` | Fonctionne, mais **ne tolère aucune panne** |
| `topology` | Les membres : une seule instance, `online`, en lecture-écriture (`r/w`) |

C’est **attendu** sur le lab : `database: single` dans le manifeste (guide `3-sunbeam-cli/`, démo 1). En production à 3 nœuds, on attend `ok`.

### Étape 3 : la trace des opérations

🎯 **Objectif : s’informer (audit).** Savoir quelles actions ont été lancées, quand, et sur quelle unité.

```bash
juju operations -m openstack | tail -4
```

**Ce que tu vois :**

```text
67  completed  2026-10-16T14:22:21  2026-10-16T14:22:24  68  get-admin-account run on unit-keystone-0
69  completed  2026-10-16T14:22:25  2026-10-16T14:22:29  70  list-ca-certs run on unit-keystone-0
71  completed  2026-10-16T14:57:14  2026-10-16T14:57:21  72  get-cluster-status run on unit-mysql-0
73  completed  2026-10-16T14:57:23  2026-10-16T14:57:23  74  juju-exec run on unit-keystone-0
```

**Comment le lire :** numéro de l’opération, état (`completed`), heures de début et de fin, numéro de la tâche, puis **quelle action sur quelle unité**. Toute action laisse une trace : c’est un avantage pour l’audit.

Les lignes 67 et 69 n’ont été lancées par **personne** à la main : c’est **Sunbeam** qui les a déclenchées pendant un `sunbeam launch`, pour récupérer le compte administrateur et le certificat. Sunbeam lui-même pilote le cloud par des actions Juju.

⚠ Certaines actions **révèlent des secrets** : `keystone get-admin-account`, `mysql get-password`, `rabbitmq get-operator-info`. Jamais sur un écran projeté.

---

## 9. Démo 7 : du charm au service (10 min) ✅

**But de la démo :** comprendre ce qu’est concrètement une unité, et où sont rangés les mots de passe.

### Étape 1 : entrer dans les unités

🎯 **Objectif : diagnostiquer.** Regarder **dans** le conteneur du service ou sur la machine, quand l’état Juju ne suffit plus.

```bash
juju ssh -m openstack --container keystone keystone/0 "hostname; grep -c . /etc/keystone/keystone.conf"
juju exec -m openstack --unit keystone/0 -- hostname
juju ssh -m admin/openstack-machines 0 hostname
```

**Ce que tu vois :**

```text
keystone-0
67
keystone-0
sunbeam
```

**Comment le lire :**

| Commande | Où elle s’exécute | Résultat |
|---|---|---|
| `juju ssh --container keystone keystone/0` | Dans le conteneur **du service** Keystone | Le pod s’appelle `keystone-0` ; son `keystone.conf` a 67 lignes non vides |
| `juju exec --unit keystone/0 --` | Dans le conteneur **du charm**, sans session interactive | Même pod `keystone-0` |
| `juju ssh -m admin/openstack-machines 0` | Sur la **machine** `0` | La VM `sunbeam` |

Une unité Kubernetes est donc **un pod à plusieurs conteneurs** : `charm` (l’agent Juju et le charm) et `keystone` (le service). Une unité d’un modèle `manual` est un programme sur la machine.

⚠ Ce qu’on modifie à la main dans un conteneur **disparaît** au prochain redémarrage du pod ou à la prochaine reconfiguration du charm.

### Étape 2 : les secrets

🎯 **Objectif : s’informer (audit de sécurité).** Savoir quels mots de passe et certificats existent, qui les possède et qui peut les lire, **sans** les afficher.

```bash
juju secrets -m openstack | head -5
```

**Ce que tu vois :**

```text
ID                    Name  Owner                       Rotation  Revision  Last updated
d573a5sb73mo0atieoeg  -     certificate-authority       never            1  2026-10-09
t5s9vmuubo165oe9cj00  -     cinder-mysql-router         never            1  2026-10-09
saik9ud8dcbbf67e8qa0  -     cinder-volume-mysql-router  never            1  2026-10-09
b2o9gbjqlvnqblg0k630  -     glance-mysql-router         never            1  2026-10-09
```

**Comment le lire :** `ID` = l’identifiant du secret ; `Owner` = l’application qui l’a créé ; `Rotation` = renouvellement automatique (`never`, ou `daily`/`monthly` pour les clés de Keystone) ; `Revision` = nombre de versions ; `Last updated` = le 9 octobre, jour de l’installation.

```bash
juju show-secret -m openstack "$(juju secrets -m openstack --format json | python3 -c "import sys,json; print(next(k for k,v in json.load(sys.stdin).items() if v.get('owner')=='mysql'))")"
```

**La commande, mot par mot :** la partie entre `$( … )` retrouve l’identifiant du premier secret appartenant à `mysql` ; `show-secret` en affiche la fiche.

**Ce que tu vois :**

```text
25nr8pif4f7j4j2es14g:
  revision: 1
  owner: mysql
  label: database.128.user.secret
  access:
  - target: application-nova-api-mysql-router
    role: view
```

**Comment le lire :** ce secret est un **mot de passe de base de données** créé par `mysql` (`label: database…user.secret`), et seul le routeur MySQL de l’API Nova peut le **lire** (`role: view`). Les mots de passe ne sont pas copiés dans des fichiers : ils sont partagés par Juju, **à travers les relations**, au seul service qui en a besoin.

Sans `--reveal`, `show-secret` ne montre que ces métadonnées : c’est ce qu’il faut pour un **audit**. `--reveal` affiche le contenu : à éviter en formation.

---

## 10. Autres commandes utiles

| Commande | Objectif | À quoi ça sert | Remarque |
|---|---|---|---|
| `juju status -m openstack --relations keystone` | S’informer | Ajouter la liste des relations de l’application, pour savoir de quels autres services elle dépend | |
| `juju show-application -m openstack keystone` | S’informer | La fiche de l’application : charm, relations, adresses | |
| `juju show-unit -m openstack keystone/0` | Diagnostiquer | Les données échangées par relation : base `keystone` via le routeur MySQL (port 6446), RabbitMQ… Utile quand un service n’arrive pas à joindre un autre | ⚠ Contient des **références de secrets** |
| `juju debug-log -m openstack --include keystone/0` | Diagnostiquer | Suivre les journaux en direct pendant qu’on reproduit un problème (Ctrl+C pour arrêter) | Sans `--replay` : seulement les nouvelles lignes |
| `watch -n 10 juju status -m openstack` | Contrôler | Suivre l’état en continu pendant une intervention, pour voir le moment où tout redevient `active` | `juju status --watch` ne marche que dans un vrai terminal |
| `sudo k8s kubectl -n openstack logs keystone-0 -c keystone` | Diagnostiquer | Journaux **du service** (requêtes API), et non du charm : là où l’on voit les erreurs des utilisateurs | Juju ne montre que les journaux du charm |

**Ce qu’on ne fait pas avec Juju sur ce cloud** : `deploy`, `remove-application`, `integrate`, `refresh`, `scale-application`. Ces opérations changent l’architecture : elles passent par `sunbeam`, et n’ont volontairement pas été exécutées.

---

## 11. Pièges observés sur le lab

| Piège | Ce que tu vois | Explication | Réflexe |
|---|---|---|---|
| Session expirée | `Failed to login to Juju Controller` | Après un redémarrage, la session a expiré | `sunbeam utils juju-login` |
| Modèle de la machine | `model sunbeam:sunbeam/openstack-machines not found` | Le modèle appartient à `admin`, pas à `sunbeam` | `-m admin/openstack-machines` |
| Jokers | `juju status keystone*` n’affiche rien | Juju n’accepte que des noms exacts | Nommer les applications |
| `--lines` et `--no-tail` | `ERROR setting --no-tail and --lines not valid` | Les deux options sont incompatibles | `--replay --no-tail … \| tail -N` |
| `status --watch` dans un script | `unable to run Viddy … term not set` | Il faut un vrai terminal | `watch -n 10 juju status …` |
| Hook en erreur au démarrage | `agent:error`, `hook failed: "start"` | Le réseau des pods n’était pas prêt | Lire `debug-log`, puis `juju resolved` (démo 3) |
| Charm `blocked … timed out` | MicroCeph ou cinder-volume bloqué, service sain | Vérification trop lente au démarrage | Rejouer `config-changed` (démo 4) |
| Reconfiguration | `blocked … healthcheck failed` quelques secondes | Le service redémarre | Normal ; fenêtre de maintenance |
| Réglage modifié à la main | Revient à l’ancienne valeur après un `sunbeam` | Sunbeam réapplique ses plans | Préférer `sunbeam` ; documenter |
| Actions et `show-unit` | Secrets ou références de secrets à l’écran | | Ne pas projeter, relire avant de partager |

---

## 12. Récapitulatif des tests

| Commande | Exécutée | Remarque |
|---|---|---|
| `whoami`, `controllers`, `models`, `show-model` | ✅ | |
| `status` (`tabular`, `short`, `summary`, filtres, `--relations`) | ✅ | Pas de jokers ; `--watch` seulement dans un terminal |
| `offers`, section `SAAS` | ✅ | |
| `show-application`, `show-unit` | ✅ | `show-unit` montre des références de secrets |
| `config` (lecture, modification, `--reset`) | ✅ | Effet vérifié dans `logging.conf` ; brève indisponibilité de Keystone |
| `show-status-log`, `debug-log` | ✅ | `--lines` incompatible avec `--no-tail` |
| `actions`, `run mysql/0 get-cluster-status`, `operations` | ✅ | |
| `ssh --container`, `exec --unit`, `ssh` sur la machine 0 | ✅ | |
| `secrets`, `show-secret` (sans `--reveal`) | ✅ | |
| `resolved`, `exec … config-changed` | ✅ | Exécutées lors des incidents réels du lab |
| `deploy`, `remove-application`, `integrate`, `refresh`, `scale-application` | ⛔ volontairement non exécutées | Réservées à `sunbeam` |

État du lab à la fin des tests (17 octobre) : toutes les unités des deux modèles en `active` / `idle`, `log-level` de Keystone revenu à `WARNING`, aucune ressource créée.
