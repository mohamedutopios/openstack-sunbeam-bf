# La CLI Sunbeam, expliquée pas à pas

Ce guide présente la commande `sunbeam`, l’outil qui **installe et exploite** un cloud OpenStack Sunbeam. Il est construit autour de **cinq démos** jouables sur le lab. Pour chaque commande, tu trouveras toujours :

| Rubrique | Ce qu’elle contient |
|---|---|
| **À quoi ça sert** | La question à laquelle la commande répond, et quand la lancer |
| **La commande, mot par mot** | Le rôle de chaque mot et de chaque option |
| **Ce que tu vois** | La sortie **réelle**, relevée sur le lab |
| **Comment le lire** | Colonne par colonne, valeur par valeur |
| **Si tu vois autre chose** | Ce que signifie un résultat différent, et quoi faire |

Toutes les commandes marquées ✅ ont été exécutées sur le lab : snap `openstack` 2024.1 (révision 1101), déploiement `star-heron`, un seul nœud nommé `sunbeam`. Celles marquées ⚠ **non exécutée** modifient l’architecture ou demandent une seconde machine : leur syntaxe vient de l’aide de la CLI.

**Où taper les commandes :** dans **Lab-Sunbeam**, avec le compte `vagrant`. Depuis Windows :

```powershell
ssh vagrant@192.168.56.10
```

---

## 1. Comment fonctionne Sunbeam

### L’idée

`sunbeam` ne crée pas lui-même les VM, les réseaux ou les services. Il **décide** de ce qui doit être déployé, puis il fait **exécuter** ce déploiement par d’autres outils :

```text
 Toi
  │  sunbeam enable orchestration
  ▼
 sunbeam (la commande)                     « je veux Heat »
  │
  ├── clusterd ──────── garde la mémoire du cluster : nœuds, rôles, manifestes, fonctionnalités activées
  │
  ├── Terraform ─────── traduit la demande en « état voulu » (plans) : quelles applications, quelle configuration
  │      │
  │      ▼
  └── Juju ──────────── déploie et relie les applications (charms), puis surveille leur état
         │
         ├── modèle « openstack »                ─► pods Kubernetes : keystone, nova, neutron, glance, horizon…
         └── modèle « admin/openstack-machines » ─► la machine elle-même : Kubernetes, MicroCeph, hyperviseur
```

### Les mots à connaître

| Mot | Ce que c’est | Exemple sur le lab |
|---|---|---|
| **Nœud** | Une machine du cluster | `sunbeam`, la VM Lab-Sunbeam |
| **Rôle** | Ce qu’un nœud fait pour le cloud : `control` (services OpenStack), `compute` (VM), `storage` (Ceph), `network` (passerelle réseau dédiée) | `sunbeam` a les rôles control, compute, storage |
| **Déploiement** | Un cloud connu de la commande `sunbeam` ; une même machine peut en connaître plusieurs | `star-heron` |
| **clusterd** | Le service qui mémorise l’état du cluster (une petite base de données) | — |
| **Plan** | Une couche du cloud décrite pour Terraform | `openstack-plan`, `microceph-plan`… |
| **Manifeste** | Un fichier YAML qui fixe les réglages du cloud : adresses, réseaux, versions | Celui du 9 octobre, au bootstrap |
| **Fonctionnalité** (*feature*) | Un service optionnel qu’on active ou désactive | `orchestration` (Heat), `vault`, `tls`… |

### Quel outil pour quoi

| Je veux… | J’utilise |
|---|---|
| Installer le cloud, ajouter un nœud, activer un service, mettre à jour, récupérer les accès | `sunbeam` |
| Voir l’état des services, lire leurs journaux, débloquer une unité | `juju` (guide `4-juju-cli/`) |
| Créer des projets, des VM, des réseaux, interroger le cloud | `openstack` (guide `5-openstack-cli/`) |

**Règle :** on **change** l’architecture avec `sunbeam`. Une modification faite directement avec Juju ou Kubernetes peut être écrasée par la prochaine commande `sunbeam`.

---

## 2. Syntaxe générale

```text
sunbeam [-v | -q] <groupe> [<sous-commande>] [options]
```

Exemple : `sunbeam cluster list -f yaml`

| Morceau | Ici | Rôle |
|---|---|---|
| `sunbeam` | | La commande |
| `<groupe>` | `cluster` | La famille de commandes : nœuds du cluster |
| `<sous-commande>` | `list` | L’action : lister |
| `[options]` | `-f yaml` | Une option : la sortie en YAML au lieu d’un tableau |

| Option | Effet |
|---|---|
| `-h` | Aide du niveau où on se trouve : `sunbeam -h`, `sunbeam cluster -h`, `sunbeam enable tls -h` |
| `-v` | Mode bavard : détaille les étapes et les erreurs. À ajouter quand une commande échoue sans explication |
| `-q` | Mode silencieux |
| `-f table` / `-f yaml` | Tableau lisible par un humain / YAML lisible par un script |
| `-m FICHIER` | Appliquer un manifeste |
| `--no-hints` | Ne pas poser les questions d’aide interactives |

### Les familles de commandes

| Groupe | Sert à | Utilisé dans |
|---|---|---|
| `utils juju-login` | Renouveler la session Juju | Démo 1, étape 0 |
| `deployment` | Voir les déploiements connus | Démo 1, étape 1 |
| `cluster` | Lister les nœuds ; en ajouter, en retirer ; mettre à jour | Démo 1, étape 2 ; § 8.2 |
| `manifest` | Lire la configuration appliquée ; la générer en entier | Démo 1, étape 3 ; démo 4 |
| `list-features`, `enable`, `disable` | Fonctionnalités optionnelles | Démo 1, étape 4 ; démo 5 |
| `plans` | Voir les couches Terraform et leurs verrous | Démo 1, étape 5 ; § 8.2 |
| `openrc`, `cloud-config`, `dashboard url` | Récupérer les accès | Démo 2 |
| `launch` | Lancer une VM de test | Démo 3 |
| `proxy`, `storage`, `identity`, `prepare-node-script`, `list-feature-gates` | Configuration d’entreprise | § 8 |
| `bootstrap` | Installer le premier nœud d’un nouveau cloud | § 8.2 |

⚠ `sunbeam inspect`, cité dans d’anciennes documentations, **n’existe pas** dans cette version.

---

## 3. Démo 1 : faire le tour d’un cloud Sunbeam (15 min) ✅

**Objectif :** savoir de quoi est fait le cloud, s’il est en bonne santé, et comment il a été configuré. C’est ce qu’on fait en arrivant sur un cloud inconnu, ou le matin avant une formation.

**La logique de l’ordre :** on va du plus général au plus détaillé, chaque étape s’appuyant sur la précédente.

| Étape | Question | Commande |
|---|---|---|
| 0 | Ma session fonctionne-t-elle ? | `sunbeam utils juju-login` |
| 1 | Sur **quel cloud** suis-je ? | `sunbeam deployment list` |
| 2 | De **quelles machines** est-il fait, vont-elles bien ? | `sunbeam cluster list` |
| 3 | Avec **quels réglages** a-t-il été installé ? | `sunbeam manifest show latest` |
| 4 | Quels **services en plus** du socle ? | `sunbeam list-features` |
| 5 | Une **opération** est-elle en cours ou bloquée ? | `sunbeam plans list` |

### Étape 0 : renouveler la session Juju

**À quoi ça sert :** `sunbeam` interroge Juju. Après un redémarrage du lab, la session de connexion à Juju a souvent expiré, et les commandes échouent avec un message trompeur.

```bash
sunbeam utils juju-login
```

**La commande, mot par mot :** `utils` = utilitaires ; `juju-login` = se reconnecter au contrôleur Juju avec le compte Linux courant.

**Ce que tu vois :**

```text
Juju re-login complete.
```

**Si tu vois autre chose :** si tu oublies cette étape, la commande suivante peut répondre `Error: Failed to login to Juju Controller`. Ce n’est **pas une panne** : relance `sunbeam utils juju-login`, puis la commande.

### Étape 1 : le déploiement

**À quoi ça sert :** savoir quel cloud la commande `sunbeam` pilote. Une même machine d’administration peut gérer plusieurs clouds ; `sunbeam` travaille toujours sur le déploiement **courant**. C’est donc la première question : toutes les étapes suivantes portent sur ce déploiement-là. Se tromper de cloud, c’est diagnostiquer, ou modifier, le mauvais.

```bash
sunbeam deployment list
```

**La commande, mot par mot :** `deployment` = le groupe des déploiements ; `list` = lister.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━┓
┃ Deployment  ┃ Endpoint ┃ Type  ┃
┡━━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━┩
│ star-heron* │ local    │ local │
└─────────────┴──────────┴───────┘
```

**Comment le lire :**

| Colonne | Valeur | Signification |
|---|---|---|
| `Deployment` | `star-heron` | Le nom du cloud, tiré au hasard au bootstrap |
| `*` | | Le déploiement **courant**, celui que visent toutes les commandes `sunbeam` |
| `Endpoint` | `local` | Le cloud est géré depuis cette machine |
| `Type` | `local` | Machines installées à la main. L’autre type, `maas`, désigne des serveurs physiques gérés par MAAS |

**Si tu vois autre chose :** plusieurs lignes = plusieurs clouds connus ; `sunbeam deployment switch NOM` change le courant.

⚠ `sunbeam deployment show star-heron` (avec le **nom**, pas `local`) donne le détail, mais **affiche des secrets** : certificats, clé privée et fragments de mot de passe du contrôleur Juju. À ne pas projeter.

### Étape 2 : les nœuds et leurs rôles

**À quoi ça sert :** une fois le bon cloud identifié, savoir combien de machines le composent, ce que chacune fait, et si chaque rôle fonctionne.

```bash
sunbeam cluster list
```

**La commande, mot par mot :** `cluster` = le groupe des nœuds du déploiement courant ; `list` = lister. Ajoute `-f yaml` pour une sortie exploitable par un script.

**Ce que tu vois** (relevé le 17 octobre) :

```text
                          openstack-machines
┏━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┓
┃ Node    ┃ Cluster ┃ Machine ┃ Compute ┃ Control ┃ Network ┃ Storage ┃
┡━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━┩
│ sunbeam │ ONLINE  │ running │ active  │ active  │         │ active  │
└─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┘
```

⚠ L’ordre des colonnes `Cluster` et `Machine` **change d’une exécution à l’autre** : le même jour, une autre exécution a affiché `Machine` avant `Cluster`. Lire les titres, pas les positions ; pour un script, utiliser `-f yaml`, dont l’ordre est fixe.

**Comment le lire :**

| Colonne | Valeur | Signification |
|---|---|---|
| Titre `openstack-machines` | | Le modèle Juju qui décrit les machines |
| `Node` | `sunbeam` | Le nom du nœud ; **une ligne par machine** du cluster |
| `Cluster` | `ONLINE` | Le nœud est membre du cluster Sunbeam (clusterd) et répond |
| `Machine` | `running` | La machine est connue de Juju et son agent tourne |
| `Compute` | `active` | Le rôle **calcul** fonctionne : l’hyperviseur peut héberger des VM |
| `Control` | `active` | Le rôle **contrôle** fonctionne : Kubernetes, qui porte les services OpenStack |
| `Network` | *(vide)* | Ce nœud **n’a pas** le rôle réseau dédié ; c’est normal sur un nœud unique |
| `Storage` | `active` | Le rôle **stockage** (MicroCeph) fonctionne |

Ici, tout va bien : un nœud unique qui porte les rôles contrôle, calcul et stockage.

**Si tu vois autre chose :**

| Valeur | Signification | Que faire |
|---|---|---|
| `active` partout (sauf colonnes vides) | Tout va bien | Rien |
| `blocked` | Le charm du rôle a besoin d’une intervention | `juju status -m admin/openstack-machines` pour lire le message (guide `4-juju-cli/`, démo 4) |
| `waiting`, `maintenance` | Le rôle démarre ou se configure | Attendre quelques minutes, puis relancer |
| `Cluster` différent de `ONLINE` | Le nœud ne répond plus au cluster | Vérifier que la machine est démarrée et joignable |
| Colonne vide | Le nœud n’a pas ce rôle | Normal si c’est voulu |

Exemple réel : le 16 octobre, la colonne `Storage` affichait `blocked`. Le charm MicroCeph était resté bloqué après un démarrage lent, alors que Ceph fonctionnait. L’enquête est dans le guide `4-juju-cli/` (démo 4), la réparation dans le guide `5-openstack-cli/` (démo 6).

### Étape 3 : la configuration appliquée

**À quoi ça sert :** une fois les machines connues, retrouver les réglages avec lesquels le cloud a été installé (réseau de gestion, adresses des API) sans fouiller les fichiers. Ces adresses servent ensuite partout : fichier `hosts` de Windows, accès des équipes (démo 2).

```bash
sunbeam manifest list
sunbeam manifest show latest
```

**La commande, mot par mot :** `manifest` = les manifestes appliqués ; `list` = leur historique ; `show latest` = afficher le plus récent (`latest`), ou un précis en donnant son identifiant.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━┓
┃ ID                               ┃ Applied Date        ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━┩
│ 95edf2b4fd75770fb6aefbad44c0e839 │ 2026-10-09 10:19:15 │
└──────────────────────────────────┴─────────────────────┘
```

```text
core:
  config:
    bootstrap:
      management_cidr: 192.168.56.0/24
    database: single
    endpoints:
      ingress-internal:
        hostname: internal.lab.test
        ip: 192.168.56.202
      ingress-public:
        hostname: cloud.lab.test
        ip: 192.168.56.201
      ingress-rgw:
        hostname: rgw.lab.test
        ip: 192.168.56.203
    k8s-addons:
      loadbalancer: 192.168.56.200-192.168.56.220
    region: RegionOne
```

**Comment le lire :**

| Ligne | Valeur | Signification |
|---|---|---|
| `manifest list` | une ligne, le 9 octobre | Un seul manifeste appliqué : celui du bootstrap. Chaque modification par manifeste ajouterait une ligne |
| `management_cidr` | `192.168.56.0/24` | Le **réseau de gestion** : la carte 2 de la VM (`mgmt0`) |
| `database` | `single` | Une seule instance MySQL, sans haute disponibilité |
| `ingress-public` | `cloud.lab.test` = `.201` | Adresse des API **publiques** et d’Horizon : celle que tapent les utilisateurs |
| `ingress-internal` | `internal.lab.test` = `.202` | Adresse des API **internes** : celle que les services utilisent entre eux |
| `ingress-rgw` | `rgw.lab.test` = `.203` | Stockage objet (passerelle S3 de Ceph) |
| `loadbalancer` | `.200` à `.220` | Plage d’adresses que Kubernetes attribue aux services exposés |
| `region` | `RegionOne` | Le nom de la région OpenStack |

Ce sont exactement les adresses que le script `Configurer-Lab-Sunbeam.ps1` inscrit dans le fichier `hosts` de Windows.

**Si tu vois autre chose :** une adresse différente ici et dans le fichier `hosts` de Windows explique qu’Horizon ne réponde pas depuis Windows.

### Étape 4 : les fonctionnalités activées

**À quoi ça sert :** savoir quels services optionnels sont installés en plus du socle (Keystone, Nova, Neutron, Glance, Cinder, Horizon, Placement).

```bash
sunbeam list-features
```

**La commande, mot par mot :** `list-features` = lister les fonctionnalités et leur état. `-f yaml` donne une liste `nom: true/false`.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━┓
┃ Feature                ┃ Enabled ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━┩
│ vault                  │         │
│ baremetal              │         │
│ caas                   │         │
│ dns                    │         │
│ images-sync            │         │
│ instance-recovery      │         │
│ ldap                   │         │
│ loadbalancer           │         │
│ maintenance            │         │
│ observability.embedded │         │
│ observability.external │         │
│ resource-optimization  │         │
│ orchestration          │         │
│ pro                    │         │
│ secrets                │         │
│ shared-filesystem      │         │
│ telemetry              │         │
│ tls.ca                 │         │
│ tls.self-signed        │         │
│ tls.vault              │         │
│ validation             │         │
└────────────────────────┴─────────┘
```

**Comment le lire :**

- la colonne `Enabled` contient un `X` quand la fonctionnalité est activée ; **ici, aucune ne l’est** : le lab n’a que le socle ;
- un nom avec un point est une **variante** : `tls.ca`, `tls.self-signed` et `tls.vault` sont trois façons d’activer TLS, dont une seule à la fois.

| Fonctionnalité | Service ajouté | À quoi il sert |
|---|---|---|
| `orchestration` | Heat | Créer une infrastructure entière à partir d’un modèle (démo 5) |
| `loadbalancer` | Octavia | Répartiteurs de charge |
| `secrets` | Barbican | Coffre-fort de clés et de certificats pour les utilisateurs du cloud |
| `vault` | Vault | Coffre-fort de secrets pour l’infrastructure ; sert notamment à `tls.vault` |
| `tls.*` | — | Chiffrer les API (HTTPS) |
| `ldap` | Keystone | Brancher un annuaire LDAP ou Active Directory |
| `dns` | Designate | Noms DNS pour les VM |
| `telemetry`, `observability.*` | Ceilometer, Gnocchi / Prometheus, Grafana | Métrologie, supervision |
| `instance-recovery` | Masakari | Relancer les VM d’un hôte en panne |
| `caas` | Magnum | Clusters Kubernetes à la demande |
| `validation` | Tempest | Tests de conformité du cloud |

**Si tu vois autre chose :** un `X` sur une ligne = ce service est installé, ses API sont dans le catalogue (`openstack catalog list`).

### Étape 5 : les plans Terraform

**À quoi ça sert :** voir comment Sunbeam découpe le cloud en couches, et vérifier qu’aucune opération n’est en cours ou bloquée.

```bash
sunbeam plans list
```

**La commande, mot par mot :** `plans` = les plans Terraform ; `list` = les lister avec leur état de verrou.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┓
┃ Plan                 ┃ Locked ┃
┡━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━┩
│ k8s-plan             │        │
│ sunbeam-machine-plan │        │
│ hypervisor-plan      │        │
│ demo-setup           │        │
│ openstack-plan       │        │
│ microceph-plan       │        │
│ cinder-volume-plan   │        │
└──────────────────────┴────────┘
```

**Comment le lire :**

| Plan | Couche qu’il décrit |
|---|---|
| `k8s-plan` | Kubernetes, qui héberge les services OpenStack |
| `sunbeam-machine-plan` | La préparation de chaque machine |
| `hypervisor-plan` | L’hyperviseur (Nova compute, OVN, libvirt) |
| `openstack-plan` | Les services OpenStack eux-mêmes (Keystone, Nova, Neutron…) |
| `microceph-plan` | Le stockage Ceph |
| `cinder-volume-plan` | Le service de volumes branché sur Ceph |
| `demo-setup` | Ce que `sunbeam configure` a créé : l’utilisateur et le projet `demo`, `demo-network`, `demo-router` |

La colonne `Locked` vide signifie qu’**aucune opération n’est en cours**.

**Si tu vois autre chose :** un plan verrouillé alors que rien ne tourne (opération interrompue, coupure) **bloque toute commande `sunbeam` suivante** sur cette couche. La commande `sunbeam plans unlock NOM` le libère (⚠ non exécutée), à n’utiliser qu’après avoir vérifié qu’aucune commande `sunbeam` ne tourne ailleurs.

### Ce qu’il faut retenir de la démo 1

| Question | Réponse sur le lab | Commande |
|---|---|---|
| Quel cloud est piloté ? | `star-heron`, installé à la main | `deployment list` |
| Combien de machines, quels rôles ? | 1 nœud : contrôle, calcul, stockage, tous `active` | `cluster list` |
| Quels réglages ? | Gestion `192.168.56.0/24`, API `.201`/`.202`/`.203`, base sans haute disponibilité | `manifest show latest` |
| Quels services en plus du socle ? | Aucun | `list-features` |
| Une opération est-elle bloquée ? | Non, aucun verrou | `plans list` |

---

## 4. Démo 2 : récupérer les accès au cloud (10 min) ✅

**Objectif :** obtenir de quoi utiliser le cloud en ligne de commande, et l’adresse de l’interface web.

### Avant de commencer : quels comptes `sunbeam` connaît-il ?

`sunbeam` ne crée pas de comptes à la demande, et ne sait générer des accès que pour **deux comptes**, qui existent déjà :

| Compte | Domaine / projet | Créé par | Quand |
|---|---|---|---|
| `admin` | `admin_domain` / `admin` | `sunbeam cluster bootstrap` | À l’installation du cloud |
| `demo` | `users` / `demo`, rôle `member` | `sunbeam configure` (plan `demo-setup`, démo 1, étape 5) | Juste après l’installation, avec `demo-network` et `demo-router` |

`sunbeam` a mémorisé ces deux comptes et leurs mots de passe au moment où il les a créés : c’est pour cela qu’il peut produire leurs accès. Sur le lab, ils existent depuis le 9 octobre. On le vérifie, avec le compte administrateur :

```bash
source ~/admin-openrc
openstack user list --domain users
openstack role assignment list --user demo --user-domain users --names
```

**Ce que tu vois :**

```text
| 18e2624580f345e895073662440271da | demo |

| member | demo@users |       | demo@users |        |        | False     |
```

**Comment le lire :** le domaine `users` contient un seul compte, `demo` ; ce compte a le rôle `member` (utilisateur ordinaire) sur le projet `demo` du même domaine (la notation `nom@domaine`).

**Si tu vois autre chose :** si `demo` n’existe pas, c’est que `sunbeam configure` n’a pas été lancé, ou que le compte a été supprimé ; `sunbeam cloud-config` (sans `-a`) ne peut alors rien produire d’utilisable.

**Pour une vraie équipe**, avec ses propres comptes, `sunbeam` ne suffit pas :

1. créer le domaine, le projet, les comptes et leurs rôles avec la commande `openstack` (`labs-iam/`) ;
2. écrire le fichier d’accès de l’équipe en partant de ceux de cette démo, en remplaçant le nom du compte, son domaine, son projet et son mot de passe.

Sur le lab, les deux fichiers d’accès existent déjà : `~/admin-openrc` et `~/demo-openrc`. Les autres guides les utilisent. Cette démo montre comment **les régénérer** avec `sunbeam`, par exemple après un changement de mot de passe, et sous une autre forme (`clouds.yaml`). On écrit dans de **nouveaux** fichiers pour ne pas écraser ceux du lab.

### Étape 1 : les variables de l’administrateur

**À quoi ça sert :** obtenir le « fichier openrc », c’est-à-dire les variables qui permettent à la commande `openstack` de se connecter en tant qu’administrateur.

```bash
sunbeam openrc > ~/admin-openrc.nouveau
grep -v OS_PASSWORD ~/admin-openrc.nouveau
```

**La commande, mot par mot :** `openrc` affiche les variables à l’écran ; `> ~/admin-openrc.nouveau` les enregistre dans un fichier. `grep -v OS_PASSWORD` affiche le fichier **sans** la ligne du mot de passe : à préférer à `cat` devant un public.

**Ce que tu vois** (la ligne `OS_PASSWORD` existe dans le fichier, masquée ici) :

```text
# openrc for access to OpenStack
export OS_USERNAME=admin
export OS_PASSWORD=********
export OS_AUTH_URL=http://cloud.lab.test/openstack-keystone/v3
export OS_USER_DOMAIN_NAME=admin_domain
export OS_PROJECT_DOMAIN_NAME=admin_domain
export OS_PROJECT_NAME=admin
export OS_AUTH_VERSION=3
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=RegionOne
```

**Comment le lire :**

| Variable | Valeur | Signification |
|---|---|---|
| `OS_USERNAME` / `OS_PASSWORD` | `admin` / … | Le compte |
| `OS_AUTH_URL` | `http://cloud.lab.test/openstack-keystone/v3` | L’adresse de Keystone : **la seule** que le client doit connaître, il trouve les autres dans le catalogue |
| `OS_USER_DOMAIN_NAME` | `admin_domain` | Le domaine où est rangé le compte `admin` |
| `OS_PROJECT_NAME` / `OS_PROJECT_DOMAIN_NAME` | `admin` / `admin_domain` | Le projet sur lequel on travaille |
| `OS_IDENTITY_API_VERSION` | `3` | La version de l’API d’identité |
| `OS_REGION_NAME` | `RegionOne` | La région |

Utilisation : `source ~/admin-openrc.nouveau`, puis toutes les commandes `openstack` de la session agissent en tant qu’`admin`.

### Étape 2 : un fichier `clouds.yaml` pour plusieurs comptes

**À quoi ça sert :** au lieu d’un fichier openrc par compte, un seul fichier `clouds.yaml` contient plusieurs **profils**, qu’on choisit avec `--os-cloud`. Ici : un profil pour `demo`, un pour `admin`.

D’abord, **regarder** ce que la commande produirait, sans rien écrire (le mot de passe est masqué par `sed`) :

```bash
sunbeam cloud-config --no-hints | sed -E "s/(password: ).*/\1********/"
```

**Ce que tu vois :**

```yaml
clouds:
  sunbeam:
    auth:
      auth_url: http://cloud.lab.test/openstack-keystone/v3
      password: ********
      project_domain_name: users
      project_name: demo
      user_domain_name: users
      username: demo
    region_name: RegionOne
```

**Comment le lire :**

| Ligne | Valeur | D’où elle vient |
|---|---|---|
| `clouds:` | | Le début de la liste des profils du fichier |
| `sunbeam:` | | Le **nom du profil**. Personne ne l’a choisi : c’est le nom par défaut que `sunbeam` donne quand on ne précise pas `-c`. Il n’a rien à voir avec le nœud `sunbeam` ; c’est ce nom qu’on tapera dans `--os-cloud sunbeam` |
| `username: demo`, `password` | | Le compte de démonstration. Sans `-a`, la commande produit **toujours** le profil de `demo`, créé par `sunbeam configure` (voir « Avant de commencer ») |
| `user_domain_name: users` | | Le domaine où est rangé le compte `demo` |
| `project_name: demo`, `project_domain_name: users` | | Le projet sur lequel `demo` travaille, et son domaine |
| `auth_url` | | L’adresse de Keystone, la même que dans l’openrc |
| `region_name` | `RegionOne` | La région |

C’est **le même contenu qu’un openrc**, rangé sous un nom de profil.

Ensuite, **écrire** les deux profils dans un fichier :

```bash
sunbeam cloud-config -u -f ~/clouds-equipe.yaml --no-hints
sunbeam cloud-config -a -c sunbeam-admin -u -f ~/clouds-equipe.yaml --no-hints
```

**La commande, mot par mot :**

| Option | Rôle |
|---|---|
| `cloud-config` | Générer une configuration au format `clouds.yaml` |
| `-u` | **Écrire** dans le fichier (*update*). Sans `-u`, la commande affiche seulement le YAML à l’écran |
| `-f FICHIER` | Le fichier visé. Par défaut : `~/.config/openstack/clouds.yaml` |
| `-a` | Profil de l’**administrateur** (`admin`). Sans `-a`, profil de `demo` |
| `-c NOM` | Nom du profil. Sans `-c` : `sunbeam` |
| `--no-hints` | Pas de question interactive |

La première ligne crée le profil `sunbeam` (compte `demo`) ; la seconde **ajoute** le profil `sunbeam-admin` (compte `admin`) dans le même fichier. On donne un nom différent avec `-c` pour que les deux profils ne portent pas le même nom.

**Ce que tu vois :** chaque commande répond `Writing cloud information to /home/vagrant/clouds-equipe.yaml ... done`. Le fichier obtenu (`sed -E "s/(password: ).*/\1********/" ~/clouds-equipe.yaml` pour l’afficher sans les mots de passe) :

```yaml
clouds:
  sunbeam:
    auth:
      auth_url: http://cloud.lab.test/openstack-keystone/v3
      password: ********
      project_domain_name: users
      project_name: demo
      user_domain_name: users
      username: demo
    region_name: RegionOne
  sunbeam-admin:
    auth:
      auth_url: http://cloud.lab.test/openstack-keystone/v3
      password: ********
      project_domain_name: admin_domain
      project_name: admin
      user_domain_name: admin_domain
      username: admin
    region_name: RegionOne
```

**Comment le lire :** deux profils sous `clouds:`. `sunbeam` = le compte `demo`, dans le domaine `users` ; `sunbeam-admin` = le compte `admin`, dans `admin_domain`. Même adresse de Keystone et même région pour les deux.

🔎 **Vérifier que les profils fonctionnent :**

```bash
OS_CLIENT_CONFIG_FILE=~/clouds-equipe.yaml openstack --os-cloud sunbeam server list
OS_CLIENT_CONFIG_FILE=~/clouds-equipe.yaml openstack --os-cloud sunbeam-admin hypervisor list
```

`OS_CLIENT_CONFIG_FILE` indique quel fichier lire ; `--os-cloud` choisit le profil. ✅ Attendu : la liste (vide) des VM du projet `demo`, puis l’hyperviseur `sunbeam`. Avec le profil `sunbeam` (demo), la seconde commande serait refusée (`403`) : seul l’administrateur voit les hyperviseurs.

**Si tu vois autre chose :**

| Symptôme | Cause | Que faire |
|---|---|---|
| `Cloud sunbeam was not found` | Le fichier n’a pas été écrit (oubli de `-u`) ou le chemin est faux | Relancer avec `-u`, vérifier `ls -l ~/clouds-equipe.yaml` |
| `401` avec le profil `sunbeam` | Le compte `demo` a été supprimé ou son mot de passe changé depuis `sunbeam configure` | Vérifier le compte (« Avant de commencer ») |
| Le profil semble ignoré, ou le mauvais compte répond | Des variables `OS_*` sont déjà chargées (`source ~/admin-openrc`) et se mélangent au profil | Tester dans une session neuve, sans `source` préalable |
| Message « Generated … » mais fichier introuvable | Chemin dans `/tmp` : le snap a son propre `/tmp`, invisible pour toi | Toujours écrire dans `~/` |

⚠ Ces fichiers contiennent des **mots de passe**. Sur le lab, ils sont créés avec les droits `rw-rw----` : les restreindre (`chmod 600 FICHIER`) avant de les transmettre.

### Étape 3 : l’adresse de l’interface web

**À quoi ça sert :** connaître l’adresse d’Horizon, pour la donner aux utilisateurs.

```bash
sunbeam dashboard url
```

**Ce que tu vois :**

```text
http://cloud.lab.test:80/openstack-horizon
```

⚠ L’ancienne forme `sunbeam dashboard-url` fonctionne encore, mais affiche d’abord `Warning: This command is deprecated, please use sunbeam dashboard url instead.` Dans un script, `URL=$(sunbeam dashboard-url)` récupère alors une adresse inutilisable : utiliser `sunbeam dashboard url`.

**Comment le lire :** Horizon est servi par l’adresse publique `cloud.lab.test` (`.201`), en **HTTP** (port 80) : le TLS n’est pas activé sur ce lab (`tls.*` non cochés en démo 1).

### Nettoyer

```bash
rm -f ~/admin-openrc.nouveau ~/clouds-equipe.yaml
```

---

## 5. Démo 3 : une VM de test en une commande (10 min) ✅

**Objectif :** la démo 1 a montré que les rôles sont `active`, la démo 2 a fourni les accès. Reste à **prouver** que le cloud rend le service attendu : en une seule commande, créer une VM joignable depuis le PC, ce qui fait travailler ensemble le calcul, l’image, le réseau et l’IP flottante.

```bash
sunbeam launch --name lab-launch
```

**La commande, mot par mot :** `launch` = lancer une instance dans le projet de démonstration ; `--name lab-launch` = son nom (sinon un nom aléatoire) ; `--key NOM` (non utilisé ici) = choisir une clé SSH existante.

**Ce que fait la commande, dans l’ordre :**

1. elle se connecte en tant qu’utilisateur `demo`, dans le projet `demo` ;
2. elle crée une clé SSH nommée `sunbeam` si elle n’existe pas, et garde la clé privée dans `~/snap/openstack/<révision>/sunbeam` ;
3. elle lance une VM : image `ubuntu`, gabarit `m1.tiny` (1 vCPU, 512 Mo), réseau `demo-network`, groupe de sécurité `default` (SSH et ping autorisés) ;
4. elle lui associe une **IP flottante** du réseau externe `192.168.57.0/24`.

**Ce que tu vois** (1 min 25 s sur le lab) :

```text
Launching an OpenStack instance ...
Access the instance by running the following command:
`ssh -i /home/vagrant/snap/openstack/1101/sunbeam ubuntu@192.168.57.199`
```

**Comment le lire :** la dernière ligne est **la commande à taper** pour se connecter : `-i …/sunbeam` = la clé privée créée au point 2 ci-dessus ; `ubuntu` = le compte des images Ubuntu ; `192.168.57.199` = l’IP flottante, joignable depuis le PC.

🔎 **Vérifier depuis Windows** (PowerShell) :

```powershell
ping 192.168.57.199
```

✅ Attendu : des réponses (`TTL=63`). La VM met une à deux minutes à démarrer complètement ; le SSH répond ensuite.

**Si tu vois autre chose :**

| Symptôme | Cause probable |
|---|---|
| La commande échoue, la VM est en `ERROR` | Problème de calcul ou d’image : guide `5-openstack-cli/`, démo 5 |
| Pas de réponse au ping depuis Windows | Carte 3 de la VM sur le mauvais réseau Host-only, ou VM pas encore démarrée |
| Ping OK, SSH refusé | VM pas finie de démarrer, ou mauvaise clé : attendre, puis réessayer |

🔎 **Nettoyer** (la VM, son IP flottante et la clé appartiennent au projet `demo`) :

```bash
source ~/demo-openrc
FIP=$(openstack server show lab-launch -f json -c addresses | python3 -c "import sys,json; a=json.load(sys.stdin)['addresses']; print([i for v in a.values() for i in v if i.startswith('192.168.57.')][0])")
openstack server delete lab-launch --wait
openstack floating ip delete "$FIP"
openstack keypair delete sunbeam
rm -f ~/snap/openstack/*/sunbeam
```

| Ligne | Rôle |
|---|---|
| `FIP=…` | Retrouve l’IP flottante de la VM (adresse en `192.168.57.`) et la garde dans la variable `FIP` |
| `server delete … --wait` | Supprime la VM et attend la fin |
| `floating ip delete` | Rend l’IP flottante : **supprimer la VM ne la libère pas** |
| `keypair delete sunbeam` puis `rm` | Supprime la clé dans OpenStack, puis la clé privée sur le disque |

⚠ `sunbeam launch` sert à **vérifier** un cloud, pas à créer des VM de travail : il utilise toujours le projet de démonstration.

---

## 6. Démo 4 : documenter la configuration (5 min) ✅

**Objectif :** avant toute intervention (activer un service, mettre à jour), **photographier** la configuration complète du cloud. Le fichier sert à documenter, à comparer avant et après, ou à reconstruire un cloud identique. C’est le préalable logique de la démo 5.

**Différence avec la démo 1 :** `sunbeam manifest show latest` montre le manifeste **appliqué** au bootstrap, réduit aux réglages choisis (une vingtaine de lignes). `sunbeam manifest generate` écrit la configuration **complète**, valeurs par défaut comprises, et un modèle pour chaque fonctionnalité.

```bash
sunbeam manifest generate -f ~/manifest-lab.yaml
```

**La commande, mot par mot :** `manifest generate` = écrire le manifeste complet de la configuration déployée ; `-f` = le fichier (par défaut `~/.config/openstack/manifest.yaml`).

**Ce que tu vois :**

```text
Generated manifest is at /home/vagrant/manifest-lab.yaml
```

Explorer le fichier :

```bash
wc -l ~/manifest-lab.yaml
grep -n -E "^[a-z]+:|^  [a-z-]+:$" ~/manifest-lab.yaml | head -25
grep -n -A4 "^  orchestration:" ~/manifest-lab.yaml
```

| Commande | Ce qu’elle montre |
|---|---|
| `wc -l` | La taille : **612 lignes** sur le lab |
| Premier `grep` | Le plan du fichier : les grandes sections et sous-sections |
| Second `grep` | La section d’une fonctionnalité, ici Heat |

**Ce que tu vois** (extraits) :

```text
core:
  config:
features:
  vault:
  baremetal:
  caas:
  …
  orchestration:
  …
483:  orchestration:
484-    # config: null
485-    # software:
486-    #   juju:
```

**Comment le lire :**

- **`core`** : le socle (réseaux, adresses, base de données, versions des charms) ;
- **`features`** : une section par fonctionnalité ; ici, ce sont des **modèles commentés** (lignes en `#`) : on les décommente pour préparer un manifeste à appliquer avec `-m` ;
- **activer une fonctionnalité ne change pas ce fichier** : constaté sur le lab en activant Heat (démo 5), la section `orchestration` reste un modèle commenté. L’état « activé ou non » est gardé par clusterd et se lit avec `sunbeam list-features`. Pour tracer une activation, il faut donc noter la sortie de `list-features` avant et après, en plus du manifeste.

**Si tu vois autre chose :** `Generated manifest is at /tmp/…` mais le fichier n’existe pas : le snap écrit dans **son** `/tmp`, invisible pour toi. Écris toujours dans `~/`.

⚠ Le fichier contient des **mots de passe** (4 occurrences sur le lab). Le supprimer après la démo :

```bash
rm -f ~/manifest-lab.yaml
```

---

## 7. Démo 5 : activer Heat, l’utiliser, le retirer (30 min) ✅

**Objectif :** montrer le cycle complet d’une fonctionnalité optionnelle : ce que l’activation installe, à quoi sert le service, et ce que la désactivation laisse derrière elle.

Durées mesurées : **activation 9 min 50 s**, désactivation 4 min 08 s. Lance l’activation au début d’une pause ou pendant une explication.

**Avant de commencer :** la démo 1 doit être entièrement `active` (on n’ajoute pas un service à un cloud malade), et la démo 4 fournit la photographie « avant ».

### Étape 1 : vérifier l’état de départ

```bash
sunbeam list-features | grep orchestration
```

**Ce que tu vois :** `│ orchestration │         │` : colonne `Enabled` vide, Heat n’est pas installé.

### Étape 2 : activer

**À quoi ça sert :** installer le service d’orchestration Heat, qui crée une infrastructure entière (réseaux, VM, volumes) à partir d’un fichier modèle.

```bash
sunbeam enable orchestration
```

**La commande, mot par mot :** `enable` = activer ; `orchestration` = le nom de la fonctionnalité (Heat).

**Ce que tu vois** (au bout de 9 min 50 s) :

```text
OpenStack orchestration application enabled.
```

**Suivre l’avancement**, dans une seconde session SSH :

```bash
watch -n 10 "juju status -m openstack --color=false | grep -i heat"
```

`watch -n 10` relance la commande toutes les 10 secondes ; `grep -i heat` ne garde que les lignes de Heat. On voit successivement :

| État affiché | Signification |
|---|---|
| `heat … maintenance … installing charm software` | Le charm de Heat s’installe |
| `heat-mysql-router … waiting … Waiting for mysql app` | Le routeur vers la base de données attend MySQL |
| `heat … active`, `heat-mysql-router … active` | Heat est prêt |

### Étape 3 : 🔎 vérifier que Heat est en service

```bash
sunbeam list-features | grep orchestration
source ~/admin-openrc
openstack service list | grep -i -E "heat|orchestration"
openstack orchestration service list -c Binary -c Status
```

**Ce que tu vois :**

```text
│ orchestration │    X    │
| 73a4e4d6… | heat     | orchestration  |
| 963068b2… | heat-cfn | cloudformation |
heat-engine  up
heat-engine  up
heat-engine  up
heat-engine  up
```

**Comment le lire :** la fonctionnalité est cochée ; Keystone a deux **nouveaux services** au catalogue (`heat` pour l’API native, `heat-cfn` pour la compatibilité CloudFormation d’AWS) ; quatre processus `heat-engine` sont `up`, ce sont eux qui exécutent les modèles.

### Étape 4 : 🔎 utiliser Heat avec un petit modèle

**À quoi ça sert :** montrer ce qu’apporte Heat : décrire une infrastructure dans un fichier, la créer et la supprimer d’une seule commande.

Créer le modèle :

```bash
cat > ~/lab-pile.yaml <<'EOF'
heat_template_version: 2021-04-16
description: Reseau et groupe de securite de demonstration
parameters:
  cidr:
    type: string
    default: 10.40.0.0/24
resources:
  reseau:
    type: OS::Neutron::Net
    properties: {name: lab-heat-net}
  sous_reseau:
    type: OS::Neutron::Subnet
    properties: {name: lab-heat-subnet, network: {get_resource: reseau}, cidr: {get_param: cidr}}
  groupe:
    type: OS::Neutron::SecurityGroup
    properties:
      name: lab-heat-sg
      rules: [{protocol: tcp, port_range_min: 22, port_range_max: 22, remote_ip_prefix: 192.168.57.1/32}]
outputs:
  reseau_id: {value: {get_resource: reseau}}
EOF
```

| Section du modèle | Rôle |
|---|---|
| `heat_template_version` | Version du format de modèle |
| `parameters` | Valeurs modifiables à la création (ici la plage d’adresses, par défaut `10.40.0.0/24`) |
| `resources` | Ce qu’il faut créer : un réseau, un sous-réseau **dans ce réseau** (`get_resource: reseau`), un groupe de sécurité qui autorise SSH depuis Windows |
| `outputs` | Ce que la pile renvoie une fois créée (ici l’identifiant du réseau) |

Créer la pile (une **pile** = l’ensemble des ressources créées à partir d’un modèle) dans le projet `demo` :

```bash
source ~/demo-openrc
openstack stack create lab-pile -t ~/lab-pile.yaml --wait
```

**Ce que tu vois :**

```text
[lab-pile]: CREATE_IN_PROGRESS  Stack CREATE started
[lab-pile.reseau]: CREATE_IN_PROGRESS  state changed
[lab-pile.groupe]: CREATE_IN_PROGRESS  state changed
[lab-pile.reseau]: CREATE_COMPLETE  state changed
[lab-pile.sous_reseau]: CREATE_IN_PROGRESS  state changed
[lab-pile.groupe]: CREATE_COMPLETE  state changed
[lab-pile.sous_reseau]: CREATE_COMPLETE  state changed
[lab-pile]: CREATE_COMPLETE  Stack CREATE completed successfully
```

**Comment le lire :** chaque ligne est un événement, `[pile.ressource]: ÉTAT`. On voit que Heat **calcule l’ordre** tout seul : le réseau et le groupe démarrent ensemble, le sous-réseau attend que le réseau soit `CREATE_COMPLETE`. Toute la pile est créée en 10 secondes.

```bash
openstack stack resource list lab-pile -c resource_name -c resource_type -c resource_status
openstack stack output show lab-pile reseau_id -c output_value -f value
```

```text
| groupe      | OS::Neutron::SecurityGroup | CREATE_COMPLETE |
| sous_reseau | OS::Neutron::Subnet        | CREATE_COMPLETE |
| reseau      | OS::Neutron::Net           | CREATE_COMPLETE |
5290cd6c-657a-4ab3-8149-46a903b735d7
```

**Comment le lire :** les trois ressources du modèle, toutes créées ; puis la valeur de la sortie `reseau_id`, l’identifiant du réseau créé.

Supprimer toute la pile d’un coup :

```bash
openstack stack delete lab-pile --yes --wait
openstack network list --name lab-heat-net
rm -f ~/lab-pile.yaml
```

✅ Attendu : `Stack DELETE completed successfully`, puis une liste **vide** de réseaux `lab-heat-net` : Heat a supprimé les trois ressources, sans oubli, dans l’ordre inverse.

**Si tu vois autre chose :** `CREATE_FAILED` sur une ressource : `openstack stack event list lab-pile` donne la raison (quota, nom en double, valeur invalide).

### Étape 5 : désactiver

```bash
sunbeam disable orchestration
sunbeam list-features | grep orchestration
juju status -m openstack --color=false | grep -c -i heat
```

**Ce que tu vois :**

```text
OpenStack orchestration application disabled.
│ orchestration │         │
0
```

**Comment le lire :** la fonctionnalité n’est plus cochée, et `0` ligne Heat dans Juju : les applications sont retirées.

### Étape 6 : 🔎 ⚠ nettoyer ce que la désactivation laisse derrière elle

**À quoi ça sert :** observé sur le lab, `sunbeam disable` retire les applications mais **pas** ce que Heat avait créé dans Keystone. Le catalogue annonce encore un service qui n’existe plus, et un compte de service reste actif.

Repérer les restes :

```bash
source ~/admin-openrc
openstack service list | grep -i heat
openstack domain list | grep heat
openstack user list --domain service_domain | grep -i heat
openstack role list | grep -i heat
```

| Reste trouvé sur le lab | Ce que c’est |
|---|---|
| Services `heat` et `heat-cfn` (avec 6 points d’accès) | Les entrées du catalogue, qui pointent vers un service disparu |
| Domaine `heat` (compte `heat_domain_admin-…`) | Le domaine où Heat range les comptes qu’il crée pour les piles |
| Compte `svc_heat-…` dans `service_domain` | Le compte de service de Heat |
| Rôle `heat_stack_user` | Un rôle propre à Heat |

Les supprimer :

```bash
openstack service delete heat heat-cfn
for u in $(openstack user list --domain service_domain -f value -c Name | grep "^svc_heat"); do
  openstack user delete --domain service_domain "$u"
done
openstack role delete heat_stack_user
openstack domain set --disable heat
openstack domain delete heat
openstack catalog list -f value -c Name
```

| Ligne | Rôle |
|---|---|
| `service delete` | Retire les services ; **leurs points d’accès partent avec eux** |
| Boucle `for` | Retrouve et supprime le ou les comptes `svc_heat-…` (le suffixe change à chaque installation) |
| `role delete` | Retire le rôle propre à Heat |
| `domain set --disable` puis `domain delete` | Un domaine ne se supprime qu’une fois désactivé ; ses comptes partent avec lui |
| `catalog list` | Vérification finale |

✅ Attendu : un catalogue sans Heat (`glance placement neutron keystone nova cinder swift cinderv3 s3`) et quatre domaines (`admin_domain`, `service_domain`, `Default`, `users`).

À retenir pour l’entreprise : **après chaque désactivation, vérifier le catalogue et les comptes de service.** Un compte de service oublié est un accès inutile qui reste ouvert.

---

## 8. Autres commandes utiles en entreprise

### 8.1 Lire sans rien changer ✅

| Commande | À quoi ça sert | Résultat sur le lab | Comment le lire |
|---|---|---|---|
| `sunbeam list-feature-gates` | Voir les fonctionnalités **expérimentales**, verrouillées par défaut | ~40 lignes : `baremetal`, `multi-region`, `split-roles`, des pilotes de baies (`netapp`, `hitachi`, `purestorage`…) ; colonne `Unlocked` vide | Une fonctionnalité expérimentale n’est pas utilisable tant qu’on ne l’a pas déverrouillée volontairement |
| `sunbeam proxy show` | Voir le proxy HTTP utilisé par le cloud | Tableau vide | Pas de proxy : le lab sort directement sur Internet |
| `sunbeam storage list` | Voir les baies de stockage externes branchées sur Cinder | `No storage backends found` | Les volumes sont stockés dans MicroCeph, pas sur une baie |
| `sunbeam identity provider list` | Voir les sources d’identité | Seul `Keystone Credentials` (`Built-in`) | Pas de fédération (Keycloak, Azure AD…) configurée |
| `sunbeam prepare-node-script` | Afficher le script de préparation d’une nouvelle machine | Script `bash` : vérifie Ubuntu 24.04, refuse de tourner en `root`, installe les prérequis | À **relire** avant de l’exécuter sur une machine |

### 8.2 Faire évoluer le cloud ⚠ non exécutées

Ces commandes modifient l’architecture : elles n’ont pas été lancées sur le lab (nœud unique). Elles sont présentées dans l’ordre de la vie d’un cloud : installation, agrandissement, mise à jour, dépannage.

**Installer le premier nœud** (déjà fait sur le lab, le 9 octobre) :

```bash
sunbeam cluster bootstrap --role control,compute,storage --topology single
```

Crée le cloud sur la machine courante. `--role` choisit ses rôles (`control`, `compute`, `storage`, `network`) ; `--topology` (`auto`, `single`, `multi`, `large`) règle la répartition des services de contrôle ; `-m FICHIER` applique un manifeste préparé à l’avance (démo 4).

**Proxy d’entreprise** (à régler **avant** d’ajouter des nœuds, si le réseau l’exige) :

```bash
sunbeam proxy set --http-proxy http://proxy.entreprise:3128 --https-proxy http://proxy.entreprise:3128 \
  --no-proxy "localhost,127.0.0.1,192.168.56.0/24,.lab.test"
```

`--no-proxy` liste ce qui ne doit **pas** passer par le proxy : le réseau de gestion et les noms internes. S’il les oublie, les services ne se parlent plus entre eux.

**Ajouter un nœud :**

```bash
sunbeam cluster add noeud2.lab.test --output ~/noeud2.token
```

Sur un nœud existant : génère un **jeton d’adhésion** pour la machine `noeud2.lab.test` (le nom doit être complet, avec le domaine) et l’écrit dans un fichier. Le jeton ne vaut que pour ce nœud.

```bash
sunbeam prepare-node-script | bash -x
sunbeam cluster join --role compute,storage "$(cat ~/noeud2.token)"
sunbeam cluster list
```

Sur le **nouveau** nœud : préparer la machine (`bash -x` affiche chaque commande exécutée), puis rejoindre le cluster avec les rôles voulus (`--role` accepte plusieurs valeurs séparées par des virgules, ou répétées). `cluster list` doit alors afficher deux lignes.

**Passer en haute disponibilité :**

```bash
sunbeam cluster resize --topology multi
```

Après l’ajout de nœuds de contrôle : répartir les services de contrôle sur plusieurs nœuds. `--topology` vaut `auto`, `single`, `multi` ou `large`.

**Retirer un nœud :**

```bash
sunbeam cluster remove noeud2.lab.test
```

Déplacer d’abord les VM du nœud. L’option `--force` ignore les contrôles de sécurité : à éviter.

**Mettre à jour :**

```bash
sunbeam cluster refresh
sunbeam cluster refresh mysql
```

La première aligne tous les charms sur la version du snap ; la seconde ne met à jour qu’un composant (`k8s`, `mysql`, `vault`). Procédure prudente : démo 1 (tout est `active` ?), démo 4 (`manifest generate -f ~/avant.yaml`), instantané des VM, `refresh`, puis de nouveau la démo 1 et les contrôles de l’étape 10 du guide apprenant.

**Débloquer une opération interrompue :**

```bash
sunbeam plans unlock openstack-plan
```

À utiliser seulement si `sunbeam plans list` affiche un verrou alors qu’aucune commande `sunbeam` ne tourne.

---

## 9. Pièges observés sur le lab

| Piège | Ce que tu vois | Explication | Réflexe |
|---|---|---|---|
| Session Juju expirée | `Error: Failed to login to Juju Controller` | Après un redémarrage, la connexion à Juju a expiré | `sunbeam utils juju-login` |
| `/tmp` du snap | `Generated … at /tmp/…`, fichier introuvable | `sunbeam` est un snap confiné, avec son propre `/tmp` | Écrire dans `~/` |
| `cloud-config` sans `-u` | Le YAML s’affiche, aucun fichier n’est créé | `-u` est l’option qui écrit | Toujours `-u -f FICHIER` |
| Nom du déploiement | `Deployment local not found` | `show` attend le **nom** (`star-heron`), pas le type (`local`) | `sunbeam deployment list` pour le nom |
| Secrets à l’écran | Certificats, clé privée, mots de passe | `deployment show` et `manifest generate` les exposent | Ne pas projeter, ne pas joindre à un ticket |
| Restes après `disable` | Service fantôme au catalogue, compte de service actif | La désactivation ne nettoie pas Keystone | Étape 6 de la démo 5 |
| `Storage: blocked` | Colonne `Storage` en `blocked`, Ceph pourtant sain | Charm MicroCeph figé après un démarrage lent | Enquête : guide `4-juju-cli/`, démo 4 ; réparation : guide `5-openstack-cli/`, démo 6 |

---

## 10. Récapitulatif des tests

| Commande | Exécutée | Remarque |
|---|---|---|
| `sunbeam -h` et l’aide de chaque groupe | ✅ | |
| `utils juju-login` | ✅ | Corrige « Failed to login to Juju Controller » |
| `deployment list`, `deployment show star-heron` | ✅ | `show` expose des secrets |
| `cluster list` (tableau et YAML) | ✅ | Relu le 17 octobre : tous les rôles `active` |
| `manifest list`, `show latest`, `generate -f ~/…` | ✅ | |
| `list-features`, `list-feature-gates` | ✅ | |
| `plans list` | ✅ | |
| `openrc`, `cloud-config` (`-u`, `-a`, `-c`) | ✅ | Profils vérifiés avec `openstack --os-cloud` |
| `dashboard url` (et l’ancienne forme `dashboard-url`) | ✅ | `dashboard-url` est dépréciée |
| `launch --name` | ✅ | VM joignable depuis Windows en 1 min 25 s |
| `enable orchestration`, `disable orchestration` | ✅ | 9 min 50 s et 4 min 08 s ; restes dans Keystone à nettoyer |
| `proxy show`, `storage list`, `identity provider list`, `prepare-node-script` | ✅ | |
| `cluster add`, `join`, `remove`, `resize`, `refresh`, `bootstrap`, `proxy set`, `plans unlock` | ⚠ non exécutées | Modifient l’architecture ; syntaxe issue de l’aide |

État du lab après les tests : aucune fonctionnalité activée, aucune ressource de test, catalogue sans Heat.
