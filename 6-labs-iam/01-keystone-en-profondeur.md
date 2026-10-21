# TP 1 : Keystone en profondeur

> Statut : **rejoué sur le lab les 17 et 18 octobre 2026** (Keystone 2024.1, client `openstack` 7.5.0). Les résultats ✅ ci-dessous sont ceux observés. Voir les conventions dans [README.md](README.md).

**Module du support :** 8, Keystone en profondeur.
**Durée :** 2 h 30.

## Ce que ce TP cherche à établir

Keystone est le service que **tout le monde appelle en premier** et que **personne ne regarde** : Horizon, le client `openstack`, Nova, Neutron lui demandent « qui est cette personne, et que peut-elle faire ? ». Quand il répond mal, tout le cloud répond mal (`401`, `403`, `503`), et le message d'erreur arrive d'un autre service. Ce TP ouvre la boîte pour qu'un refus ne soit plus un mystère.

À la fin, l'apprenant sait répondre, preuves à l'appui, à sept questions d'exploitant :

| Question | Section |
|---|---|
| Où tourne Keystone, et de quoi dépend-il ? | 1.1 |
| Comment est organisé ce cloud, et qui a le droit de faire quoi ? | 1.2 |
| Comment le client sait-il où sont Nova, Neutron… ? | 1.3 |
| Qu'est-ce qu'un jeton, qu'est-ce qu'il contient, combien de temps vaut-il, comment le couper ? | 1.4 |
| D'où viennent les comptes (base locale, annuaire, fédération) ? | 1.5 |
| Pourquoi cette commande est-elle refusée, et pouvait-on le prédire ? | 1.6 |
| Comment relier un refus vu par l'utilisateur à une ligne du journal ? | 1.7 |

Chaque section suit la même trame : **pourquoi** on fait ça (la situation réelle), **ce qu'il faut savoir** (la notion, avec les mots du support), **ce qu'on va démontrer**, les commandes, **ce qu'on observe**, **comment le lire**, et **ce que ça change** pour l'exploitant ou pour les TP suivants.

**Prérequis :** lab démarré et prêt (étape 10 du guide apprenant), session préparée :

```bash
source ~/labs-iam/lab-env.sh
K="sudo k8s kubectl -n openstack"
```

`lab-env.sh` charge les identifiants administrateur et définit `os_as`, qui exécute une commande en tant qu'un autre compte (README). `$K` abrège l'accès à Kubernetes : Keystone tourne dans un pod, et on ira lire sa configuration et ses journaux dedans.

---

## 1.1 Où tourne Keystone, et de quoi dépend-il ?

**Pourquoi on fait ça.** Premier réflexe en cas de panne d'authentification : vérifier que Keystone est vivant et savoir de quoi il dépend. Sur Sunbeam, il n'est pas un service `systemd` sur une machine : c'est un pod Kubernetes piloté par Juju. Il faut savoir où regarder.

**Ce qu'il faut savoir.** Juju déploie Keystone comme une *application* ; Kubernetes l'exécute dans un *pod* `keystone-0` qui contient deux conteneurs : `charm` (l'agent Juju qui configure) et `keystone` (le serveur, derrière Apache). Keystone n'a **pas d'état local** : ses données (comptes, projets, rôles, affectations) sont dans MySQL. La seule chose qu'il garde sur son disque, ce sont les clés qui chiffrent les jetons (§ 1.4.7).

**Ce qu'on va démontrer.** Keystone est joignable, il tourne dans un pod à deux conteneurs, et son journal montre deux types de trafic : la surveillance et les demandes de jetons.

```bash
juju status -m openstack keystone
$K get pod keystone-0 -o wide
$K logs keystone-0 -c keystone --tail=5
```

✅ **Observé** (18 octobre 2026) : l'application `keystone` est `active` ; un pod `keystone-0` en `2/2` (deux conteneurs, `charm` et `keystone`) ; des lignes du serveur web Apache. Selon le moment, ce sont surtout des `"GET /healthcheck HTTP/1.1" 200` (le test de santé que Pebble fait toutes les quelques secondes) ou des `"POST /openstack-keystone/v3/auth/tokens HTTP/1.1" 201` (des demandes de jetons). Pour ne voir que les jetons : `$K logs keystone-0 -c keystone --since=10m | grep auth/tokens | tail -3`.

**Comment le lire.** `active` dans Juju et `2/2` dans Kubernetes disent la même chose à deux niveaux : le charm est content, et les deux conteneurs tournent. Dans le journal, `POST …/auth/tokens 201` est **la** ligne à connaître : c'est une authentification réussie (`201` = jeton créé). Un `401` à cet endroit, c'est un mot de passe faux ; une absence totale de ces lignes alors que les utilisateurs se plaignent, c'est que les demandes n'arrivent pas jusqu'à Keystone (réseau, Traefik, DNS).

❓ **Question :** pourquoi `keystone-0` n'a-t-il pas de base de données dans le pod ? *Réponse : il utilise MySQL (pod `mysql-0`) via `keystone-mysql-router` ; Keystone est sans état local, hormis ses clés Fernet.*

**Ce que ça change pour toi.** Quand « plus personne ne peut se connecter », l'ordre de vérification est : `mysql-0` prêt ? `keystone-mysql-router` en erreur ? (cas réel du guide apprenant, 10.1 : un routeur en `error` donne des `HTTP 500` partout) ; puis seulement le journal de Keystone.

---

## 1.2 Comment est organisé ce cloud, et qui a le droit de faire quoi ?

### Scénario : dresser la carte d'un cloud qu'on découvre

**Pourquoi on fait ça.** Tu reprends un cloud dont le prédécesseur est parti. Avant de toucher à quoi que ce soit, tu dois savoir qui existe, ce qu'il y a comme projets, et qui a des droits sur quoi. C'est aussi la première demande d'un auditeur.

**Ce qu'il faut savoir.** Keystone range tout en cinq types d'objets :

| Objet | Rôle | Exemple sur le lab |
|---|---|---|
| **Domaine** | Un espace de noms indépendant : ses utilisateurs, ses groupes, ses projets. Deux domaines peuvent avoir un utilisateur `bruno` chacun, sans lien | `admin_domain`, `users` |
| **Projet** | Le conteneur des ressources (VM, réseaux, volumes) ; les quotas s'appliquent au projet | `demo` |
| **Utilisateur**, **groupe** | Les acteurs ; un groupe permet de donner un rôle à plusieurs personnes d'un coup | `demo`, `admin` |
| **Rôle** | Un simple nom (`member`, `admin`…). Il ne contient aucun droit : ce sont les *politiques* des services (§ 1.6) qui disent ce qu'un nom autorise | `reader`, `member`, `admin` |
| **Affectation** | Le triplet qui relie les trois : *acteur* + *rôle* + *cible* (projet, domaine ou système). C'est la seule chose qui donne un droit | `demo` a `member` sur le projet `demo` |

Un rôle seul ne sert à rien, un utilisateur seul ne peut rien : **tout passe par les affectations**.

**Ce qu'on va démontrer.** En huit commandes, on reconstitue l'organisation complète du lab, et on constate que les droits ne sont lisibles que dans les affectations.

```bash
openstack domain list
openstack project list --long
openstack user list --long
openstack group list
openstack role list
openstack implied role list
openstack region list
openstack service list
```

Puis les **affectations**, qui relient les trois : acteur, rôle, cible.

```bash
openstack role assignment list --names
```

✅ **Observé sur le lab :**

| Entité | Valeurs |
|---|---|
| Domaines | `admin_domain`, `service_domain` (description « Created by Juju »), `users`, `Default` |
| Projets | `admin` (dans `admin_domain`), `services` (dans `service_domain`), `demo` (dans `users`), et un second `admin` dans `Default` : « Bootstrap project for initializing the cloud » |
| Utilisateurs | `admin` ; dans `service_domain`, un compte par service avec un suffixe aléatoire (`svc_nova-F8OChi`, `svc_neutron-Jbci5R`, `svc_glance-…`, `svc_placement-…`, `svc_cinder-…`), plus `horizon`, `cinder-volume`, `openstack-hypervisor` et un `svc_remote_…` ; `demo` dans `users` ; `_charm-keystone-admin` dans `Default` |
| Rôles | `admin`, `manager`, `member`, `reader`, `service` |
| Rôles impliqués | `admin` → `manager` → `member` → `reader` |
| Affectations | `admin@admin_domain` : `admin` et `member` sur le projet `admin`, `admin` sur le **domaine** `admin_domain` ; chaque compte de service : `admin` **et** `service` sur `services` ; `demo` : `member` sur `demo` ; `_charm-keystone-admin@Default` : `admin` sur le **système** (le seul) |

**Comment le lire.** Sunbeam a séparé les choses en quatre domaines, et cette séparation a un sens :

- `admin_domain` : l'équipe plateforme (un seul compte, `admin`) ;
- `service_domain` : les **services eux-mêmes** (Nova, Neutron…), qui ont besoin d'un compte pour se parler et pour valider les jetons (§ 1.4.4). Le suffixe aléatoire évite qu'on devine leur nom ;
- `users` : les **utilisateurs du cloud** (ici `demo`). C'est là que Horizon crée les comptes ;
- `Default` : le domaine de démarrage, où vit `_charm-keystone-admin`, le compte avec lequel le charm Keystone s'administre lui-même. C'est le **seul** à avoir un rôle sur le *système* (§ 1.4.3) : même `admin` n'en a pas.

Deux projets s'appellent `admin` (dans `admin_domain` et dans `Default`) : un nom de projet n'est unique **que dans son domaine**. C'est pourquoi toutes les commandes de ces TP précisent `--domain` ou `--project-domain`.

**Ce que ça change pour toi.** Pour répondre à « qui peut faire quoi ? », la seule commande qui compte est `role assignment list`. `user list` et `role list` donnent des noms ; ils ne donnent aucun droit.

### Exercice

Les apprenants complètent ce tableau à partir de leurs sorties :

| Question | Commande | Leur réponse |
|---|---|---|
| Combien de domaines, et lequel héberge les comptes des services ? | `openstack domain list` | |
| Quels utilisateurs ont un rôle sur le projet `services` ? | `openstack role assignment list --project services --project-domain service_domain --names` | |
| Quel rôle `admin` implique-t-il ? | `openstack implied role list` | |
| L'utilisateur `demo` peut-il voir le projet `admin` ? | `openstack role assignment list --user demo --user-domain users --names` | |

⚠ **Piège :** `openstack user list` sans `--domain` ne liste **pas** tous les comptes. Sur le lab, avec le jeton de l'administrateur (projet `admin` du domaine `admin_domain`), il ne renvoie qu'**un** compte, `admin` : ceux du domaine du jeton. Pour inventorier un cloud, interroger chaque domaine : `for d in $(openstack domain list -f value -c Name); do openstack user list --domain "$d"; done`. Deux utilisateurs peuvent aussi porter le même nom dans deux domaines différents (TP 2) : un nom seul ne désigne pas un compte.

### Rôles impliqués : pourquoi `demo` a `reader` alors qu'on ne le lui a jamais donné

**Pourquoi on fait ça.** Un auditeur te demande « qui peut lire les réseaux du projet `demo` ? ». Si tu réponds en regardant seulement les rôles qu'on a *donnés*, tu te trompes : Keystone ajoute des rôles tout seul.

**Ce qu'il faut savoir.** Un **rôle impliqué** est une règle de Keystone : « avoir le rôle A implique avoir le rôle B ». Elle est appliquée à l'**émission du jeton** : si on t'a donné `member`, ton jeton contient aussi `reader`. Sunbeam installe la chaîne `admin → manager → member → reader`. Intérêt : on donne **un** rôle par personne, et on est sûr qu'un administrateur peut tout lire sans qu'on ait à lui donner `reader` partout. Revers : une règle de politique écrite pour `reader` s'applique aussi, silencieusement, à `member`, `manager` et `admin`.

**Ce qu'on va démontrer.** `demo` n'a reçu que `member`, et pourtant son jeton contient `reader`.

```bash
openstack role assignment list --user demo --user-domain users --names
openstack implied role list
openstack role assignment list --user demo --user-domain users --names --effective
```

✅ **Observé :** 1re commande : une ligne, `member` sur le projet `demo`. 2e : `admin` implique `manager`, `manager` implique `member`, `member` implique `reader`. 3e : deux lignes, `member` **et** `reader`.

**Comment le lire.** La 1re liste est ce qu'un humain a décidé ; la 3e, avec `--effective`, est ce que Keystone mettra dans le jeton : elle développe les rôles impliqués **et** les rôles reçus par les groupes. L'écart entre les deux, c'est la 2e commande. On le revérifiera dans le jeton lui-même au § 1.4.2 : `roles : ['member', 'reader']`.

❓ **Question :** pourquoi la liste effective de `demo` contient-elle `reader` alors qu'on ne lui a affecté que `member` ? *Réponse : `member` implique `reader` (`openstack implied role list`).*

**Ce que ça change pour toi.** Pour auditer des droits, toujours `--effective`. Au TP 4, quand tu créeras le rôle `lab-auditeur-securite`, tu devras décider s'il implique `reader` (sinon il ne lit rien). Et un piège qu'on rencontrera au TP 4 : les identifiants d'application **ne** suivent **pas** ces implications.

---

## 1.3 Comment le client sait-il où sont Nova, Neutron… ?

### Scénario : comment le client trouve Neutron

**Pourquoi on fait ça.** Tu tapes `openstack network list` : la commande part vers Neutron. Mais tu n'as donné au client qu'une seule adresse, `OS_AUTH_URL`, celle de Keystone. Comment a-t-il trouvé Neutron ? La réponse explique la panne la plus fréquente du lab : « Lab-Services éteinte, tout répond `503` ».

**Ce qu'il faut savoir.** Keystone tient le **catalogue** : la liste des services et, pour chacun, ses **points d'accès** (*endpoints*), avec trois **interfaces** : `public` (pour les clients, depuis l'extérieur), `internal` (pour les services entre eux) et `admin`. Le catalogue est renvoyé **avec le jeton** : le client reçoit en une seule réponse « voici qui tu es » et « voici où sont les services ». Il n'a donc besoin de connaître qu'une adresse : Keystone.

**Ce qu'on va démontrer.** Chaque service a trois adresses ; le client lit celle de Neutron dans la réponse de Keystone avant d'appeler Neutron ; et on peut lui faire choisir une autre interface.

```bash
openstack catalog list
openstack catalog show network
openstack endpoint list --service network
openstack endpoint list --interface internal
```

✅ **Observé :** chaque service a **trois** points d'accès dans `RegionOne` : **public** (`http://cloud.lab.test:80/openstack-<service>`), **internal** (`http://internal.lab.test:80/openstack-<service>`) et **admin** (une adresse interne à Kubernetes, par exemple `http://10.152.183.106:9696` pour Neutron). Exceptions : Keystone, dont l'interface `admin` est aussi `internal.lab.test` ; le stockage objet (`swift`, `s3`), servi par `rgw.lab.test`.

**Comment le lire.** Trois adresses pour un même service, parce que trois chemins réseau différents :

| Interface | Adresse | Qui l'utilise |
|---|---|---|
| `public` | `cloud.lab.test` → `192.168.56.201` (Traefik public) | Clients : CLI, Horizon, apprenants |
| `internal` | `internal.lab.test` → `192.168.56.202` (Traefik interne) | Services entre eux : nova-compute → Neutron, Glance… ; c'est aussi l'adresse par laquelle les services **valident les jetons** auprès de Keystone |
| `admin` | `10.152.183.x` (adresse de service Kubernetes) | Joignable seulement depuis le cluster |

Sur un vrai cloud, `public` est sur Internet derrière un pare-feu, `internal` sur un réseau de gestion non routé : séparer les deux, c'est ne pas exposer le trafic entre services.

⚠ Les services résolvent `internal.lab.test` grâce au DNS de **Lab-Services**. Si Lab-Services est arrêté, Nova, Neutron et Cinder ne peuvent plus valider les jetons et répondent `503 … The Keystone service is temporarily unavailable` (constaté sur le lab). C'est l'explication de la panne : ce n'est pas Keystone qui est tombé, c'est l'adresse `internal` que les services n'arrivent plus à résoudre.

Voir le catalogue dans le jeton lui-même, et l'appel qui suit :

```bash
openstack --debug network list 2>&1 | grep -E "^REQ: curl|^RESP: \[" | head -6
```

✅ **Observé** (18 octobre 2026) :

```text
REQ: curl -g -i -X GET http://cloud.lab.test/openstack-keystone/v3 …
RESP: [200] …
REQ: curl -g -i -X GET http://cloud.lab.test:80/openstack-neutron/v2.0/networks …
RESP: [200] …
```

**Comment le lire :** le client interroge d'abord Keystone (`GET …/v3` : découverte de la version de l'API), puis obtient un jeton (`POST …/auth/tokens`, que le client n'affiche pas sous la forme `REQ: curl`, car la requête contient le mot de passe), puis appelle Neutron. L'adresse de Neutron, `http://cloud.lab.test:80/openstack-neutron`, il l'a lue **dans le catalogue renvoyé avec le jeton** ; il ne la connaissait pas. C'est ce qui permet de déplacer un service (changer son adresse dans le catalogue) sans reconfigurer un seul client.

### Simulation : demander une autre interface

```bash
openstack --os-interface internal --debug network list 2>&1 | grep -E "^REQ: curl" | sed -n 2p
```

✅ **Observé :** l'appel part cette fois vers `http://internal.lab.test:80/openstack-neutron/v2.0/networks`. Depuis Lab-Sunbeam, les deux fonctionnent ; depuis le poste de l'apprenant, seul `public` est prévu.

**Comment le lire.** Même commande, même jeton, autre adresse : c'est le client qui a choisi une autre ligne du catalogue. Les services font pareil, avec `internal`, par leur configuration.

❓ **Question :** un apprenant obtient `EndpointNotFound` en appelant `openstack volume list`. Quelles sont les trois causes possibles ? *Réponse : service absent du catalogue, mauvaise région (`OS_REGION_NAME`), interface demandée inexistante pour ce service.*

**Ce que ça change pour toi.** `EndpointNotFound` n'est jamais une panne du service visé : c'est une ligne qui manque dans le catalogue. Et quand « tout » répond `503 Keystone unavailable` alors que `openstack token issue` marche, regarde la résolution DNS d'`internal.lab.test` depuis les services, pas Keystone.

---

## 1.4 Qu'est-ce qu'un jeton ?

**Pourquoi on fait ça.** Chaque commande `openstack`, chaque clic dans Horizon, chaque appel de Nova vers Neutron porte un jeton. Si tu ne sais pas ce qu'il contient, combien de temps il vaut et comment l'annuler, tu ne peux ni diagnostiquer un `401`, ni réagir à un jeton volé. Cette section le fabrique à la main, le lit, le fait valider, le prête, le révoque et le date.

### 1.4.1 Obtenir un jeton avec le client

**Ce qu'il faut savoir.** Un jeton est une chaîne que Keystone délivre contre un mot de passe (ou un autre moyen d'authentification) et que le client présente ensuite à chaque service, **à la place** du mot de passe.

```bash
openstack token issue
```

✅ **Observé :** les champs `expires` (une heure plus tard), `id` (le jeton, environ 180 caractères, commençant par `gAAAAA`), `project_id`, `user_id`.

**Comment le lire.** `gAAAAA` est la signature d'un jeton **Fernet** (§ 1.4.7) : un petit message chiffré, pas un identifiant stocké en base. `project_id` dit que ce jeton a une **portée** (§ 1.4.3) : il vaut pour ce projet, pas pour un autre.

### 1.4.2 Obtenir un jeton à la main, avec l'API

**Pourquoi on fait ça.** Le client cache ce qu'il envoie. Pour comprendre un `401`, il faut voir la demande telle que Keystone la reçoit, et la réponse telle qu'il la renvoie.

**Ce qu'il faut savoir.** La demande décrit **qui** (`identity` : la méthode, ici `password`, et le compte) et **pour quoi** (`scope` : la portée demandée). La réponse a deux parties : le jeton lui-même dans un **en-tête** HTTP, et sa description (rôles, catalogue, expiration) dans le **corps**.

**Ce qu'on va démontrer.** Une demande de jeton tient en dix lignes de JSON ; le jeton revient dans l'en-tête `X-Subject-Token` ; le corps contient tout ce que le client saura sur lui-même, dont les rôles impliqués et le catalogue.

```bash
DEMO_PW=$(sed -n 's/^export OS_PASSWORD=//p' ~/demo-openrc | tr -d "\"'")
cat > /tmp/auth-projet.json <<EOF
{"auth": {
  "identity": {"methods": ["password"],
    "password": {"user": {"name": "demo", "domain": {"name": "users"}, "password": "$DEMO_PW"}}},
  "scope": {"project": {"name": "demo", "domain": {"name": "users"}}}
}}
EOF
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-projet.json \
  -o /tmp/token-body.json -D /tmp/token-headers.txt
grep -i "^X-Subject-Token" /tmp/token-headers.txt | cut -c1-60
python3 -m json.tool /tmp/token-body.json | head -40
```

`-o` écrit le **corps** de la réponse dans un fichier, `-D` les **en-têtes** dans un autre. ⚠ Ne pas ajouter `-i` : il mêlerait les en-têtes au corps, et le fichier ne serait plus du JSON lisible (constaté : `Expecting value: line 1 column 1`).

✅ **Observé :**

- le jeton est dans l'**en-tête** `X-Subject-Token` (`gAAAAA…`), pas dans le corps ;
- le corps contient `methods: ["password"]`, `user`, `project`, `roles`, `expires_at`, `audit_ids`, et `catalog` (la liste des services).

```bash
python3 -c "import json; t=json.load(open('/tmp/token-body.json'))['token']; print('roles :', [r['name'] for r in t['roles']]); print('services au catalogue :', len(t['catalog'])); print('expire :', t['expires_at'])"
```

```text
roles : ['member', 'reader']
services au catalogue : 9
expire : 2026-10-17T21:47:25.000000Z
```

L'ordre des rôles peut varier d'un jeton à l'autre (`['reader', 'member']` le 18 octobre) : Keystone ne les trie pas.

**Comment le lire.** Trois choses à retenir de ce corps :

- `roles` contient `reader`, qu'on n'a jamais donné à `demo` : c'est le rôle impliqué du § 1.2, calculé **au moment de l'émission** ;
- `catalog` est là : c'est le § 1.3, le client apprend les adresses des services en même temps qu'il s'authentifie ;
- `methods: ["password"]` dit **comment** l'identité a été prouvée. Pour un compte fédéré (module 11), on y lirait `saml2` ; pour un identifiant d'application (TP 4), `application_credential`. Un auditeur peut donc distinguer les modes de connexion.

**Ce que ça change pour toi.** Tu sais maintenant reproduire une authentification sans le client : c'est l'outil pour isoler une panne (« est-ce le client, ou Keystone ? ») et pour voir le vrai code de retour, que le client masque parfois (TP 2).

### 1.4.3 Les portées : sans portée, projet, domaine, système

**Pourquoi on fait ça.** Un même compte peut obtenir des jetons différents selon ce qu'il veut faire : travailler dans un projet, administrer un domaine, administrer la plateforme. Comprendre les portées explique pourquoi l'administrateur du lab, pourtant `admin`, se fait refuser certaines commandes (TP 4, § 4.4).

**Ce qu'il faut savoir.** La **portée** (*scope*) d'un jeton est la cible sur laquelle il vaut. Il y en a quatre : **sans portée** (le jeton prouve l'identité, rien de plus), **projet**, **domaine**, **système** (la plateforme entière). Les rôles d'un jeton sont **ceux que le compte a sur cette cible** : un jeton de projet porte les rôles sur ce projet, un jeton de domaine les rôles sur ce domaine. On ne peut demander une portée que si l'on a au moins un rôle dessus.

**Ce qu'on va démontrer.** (1) Sans `scope`, Keystone en choisit une quand même. (2) Un vrai jeton sans portée n'a ni rôles ni catalogue, mais permet de découvrir ses projets. (3) L'administrateur peut obtenir un jeton de domaine, mais pas de système, car il n'a aucun rôle dessus.

**Jeton sans portée** : il prouve l'identité, sans autoriser d'action. Première tentative, en retirant simplement le `scope` de la demande :

```bash
python3 - <<'EOF'
import json
d = json.load(open('/tmp/auth-projet.json'))
del d['auth']['scope']
json.dump(d, open('/tmp/auth-defaut.json', 'w'))
d['auth']['scope'] = 'unscoped'
json.dump(d, open('/tmp/auth-sans-portee.json', 'w'))
EOF
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-defaut.json \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['token']; print('roles' in t, 'catalog' in t, t.get('project',{}).get('name'))"
```

✅ **Observé :** `True True demo`. Surprise : le jeton **a** une portée, le projet `demo`. Le compte `demo` a un **projet par défaut** (`openstack user show demo --domain users -c default_project_id`) : sans portée demandée, Keystone lui applique celui-là.

**Comment le lire.** C'est un confort pour l'utilisateur (Horizon s'en sert) et un piège pour l'exploitant : un script qui « oublie » la portée obtient quand même un jeton **avec des droits**. Le projet par défaut d'un compte fait partie de ses droits effectifs.

Pour un vrai jeton sans portée, il faut le **demander explicitement** avec `"scope": "unscoped"` (second fichier préparé ci-dessus) :

```bash
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-sans-portee.json \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['token']; print('roles' in t, 'catalog' in t, list(t))"
```

✅ **Observé :** `False False ['methods', 'user', 'audit_ids', 'expires_at', 'issued_at']` : ni rôles, ni catalogue, ni projet. Un jeton sans portée sert seulement à découvrir ce à quoi on a droit :

```bash
UNSCOPED=$(curl -s -i -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-sans-portee.json | grep -i "^X-Subject-Token" | cut -d' ' -f2 | tr -d '\r')
curl -s "$OS_AUTH_URL/auth/projects" -H "X-Auth-Token: $UNSCOPED" | python3 -m json.tool | grep -E '"name"'
```

✅ **Observé :** `"name": "demo"` (le seul projet où `demo` a un rôle).

**Comment le lire.** C'est exactement ce que fait Horizon à la connexion : un jeton sans portée pour afficher la liste des projets dans le menu, puis un jeton de projet quand on en choisit un. Un jeton sans portée dans un journal n'est donc pas suspect : c'est la première étape normale.

**Jeton de domaine** et **jeton système**, avec l'administrateur. D'abord, sur quoi `admin` a-t-il un rôle ?

```bash
openstack role assignment list --user admin --user-domain admin_domain --names
openstack role assignment list --system all --names
```

✅ **Observé :** `admin` a `admin` et `member` sur le projet `admin`, et `admin` sur le **domaine** `admin_domain` ; sur le **système**, seul `_charm-keystone-admin@Default` a un rôle. `admin` n'en a **aucun**.

```bash
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-domain-name admin_domain token issue -c domain_id -c expires
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-system-scope all token issue -c system -c expires
```

✅ **Observé :** un jeton de domaine (`domain_id` de `admin_domain`) ; puis ⛔ `The request you have made requires authentication. (HTTP 401)` pour le jeton système, puisqu'`admin` n'a aucun rôle sur le système : **on ne peut pas obtenir une portée sur laquelle on n'a rien**. Sur un cloud Sunbeam, l'administrateur travaille donc avec des jetons de **projet** ou de **domaine**.

**Comment le lire.** Le `401` ne veut pas dire « mauvais mot de passe » : le mot de passe est bon, c'est la *portée* demandée qui est impossible. Keystone ne distingue pas les deux cas dans son code de retour : d'où l'importance de vérifier les affectations avant de soupçonner le mot de passe.

⚠ **Piège :** le client `openstack` refuse de mélanger les portées. Si `OS_PROJECT_NAME` est défini, `--os-domain-name` est ignoré ou provoque une erreur : d'où les `env -u …`. La fonction `os_as` du fichier `lab-env.sh` s'en charge.

| Portée | Ce qu'elle cible | Exemples d'usage |
|---|---|---|
| sans portée | rien | découvrir ses projets (`/v3/auth/projects`) |
| projet | les ressources d'un projet | créer une VM, un réseau |
| domaine | les identités d'un domaine | créer des utilisateurs et des projets du domaine |
| système | la plateforme entière | lister les hyperviseurs, gérer les services et le catalogue |

**Ce que ça change pour toi.** Sur ce lab, l'administrateur n'a pas de jeton système. Tant que les anciennes règles sont actives (§ 1.6.1), ça ne le gêne pas : son rôle `admin` sur un projet suffit à tout. Le jour où Secure RBAC est activé, les actions « plateforme » (hyperviseurs, catalogue) exigeront un jeton système, et il faudra lui donner un rôle `--system all`. Le TP 4 (§ 4.4) montre un compte avec ce rôle.

### 1.4.4 Valider un jeton (ce que font les services)

**Pourquoi on fait ça.** Quand Nova reçoit un jeton, il ne peut pas le lire lui-même : il est chiffré par Keystone. Il demande donc à Keystone « ce jeton est-il valable, et qui est-ce ? ». Ce va-et-vient est invisible, mais c'est lui qui tombe en panne quand Lab-Services est éteinte (§ 1.3), et c'est lui qui est mis en cache (§ 1.4.6).

**Ce qu'il faut savoir.** La validation est un appel `GET /v3/auth/tokens` avec **deux** jetons : `X-Auth-Token`, celui du service qui demande (il doit avoir le droit de valider), et `X-Subject-Token`, celui de l'utilisateur à vérifier. Chaque service l'implémente avec la bibliothèque `keystonemiddleware`, configurée avec son compte de service (§ 1.5.2).

**Ce qu'on va démontrer.** On joue le rôle de Nova : on fait valider le jeton de `demo` avec un jeton qui en a le droit.

Chaque service qui reçoit un jeton le fait vérifier par Keystone (on le voit dans le traceur : `GET /v3/auth/tokens (validation du jeton)`). On reproduit l'appel :

```bash
TOKEN=$(grep -i "^X-Subject-Token" /tmp/token-headers.txt | cut -d' ' -f2 | tr -d '\r')
ADMIN_TOKEN=$(openstack token issue -f value -c id)
curl -s -o /dev/null -w "validation : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" \
  -H "X-Auth-Token: $ADMIN_TOKEN" -H "X-Subject-Token: $TOKEN"
```

✅ **Observé :** `validation : 200`. Le jeton de `demo` est vérifié avec le jeton de quelqu'un qui a le droit de vérifier (ici `admin`, en pratique le compte de service de Nova, de Neutron…).

**Comment le lire.** `200` = « valable, et voici son contenu » (avec `GET` au lieu de `-I`, on recevrait le même corps qu'au § 1.4.2 : c'est ainsi que Nova apprend les rôles de l'appelant). `404` = inconnu, expiré ou révoqué. C'est **ce code-là** que les services reçoivent, et qu'ils traduisent en `401` pour l'utilisateur.

**Ce que ça change pour toi.** Un `401` renvoyé par Nova peut avoir deux origines : le jeton est mauvais, **ou** Nova n'a pas réussi à joindre Keystone pour le vérifier. Le journal de Nova (`keystonemiddleware`) fait la différence ; le § 1.3 a montré le cas du DNS.

### 1.4.5 Un jeton est un « porteur »

**Pourquoi on fait ça.** Pour mesurer ce que vaut un jeton entre de mauvaises mains.

**Ce qu'il faut savoir.** Un jeton est un jeton **porteur** (*bearer token*) : rien ne le lie à la machine ou au programme qui l'a obtenu. Le présenter suffit. Il n'y a pas de second facteur à l'usage.

**Ce qu'on va démontrer.** Avec le seul jeton de `demo`, depuis n'importe où, on agit comme `demo` sans connaître son mot de passe.

Quiconque possède le jeton agit comme son propriétaire, sans mot de passe :

```bash
curl -s "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $TOKEN" \
  | python3 -c "import sys,json; print([n['name'] for n in json.load(sys.stdin)['networks']])"
```

✅ **Observé :** `['demo-network', 'external-network']`, les réseaux visibles par `demo`, obtenus sans aucun mot de passe.

❓ **Question :** quelles conséquences pour la sécurité ? *Réponse : un jeton intercepté vaut un accès complet jusqu'à son expiration ; d'où HTTPS, une durée courte, et la révocation.*

**Ce que ça change pour toi.** Un jeton dans un journal, dans un ticket, dans une capture d'écran projetée, c'est un mot de passe en clair pendant une heure. Sur le lab, l'API est en HTTP : le jeton passe en clair sur le réseau (le module 13 et la démo `7-securite/01` le montrent avec `tcpdump`, puis activent TLS).

### 1.4.6 Révoquer un jeton

**Pourquoi on fait ça.** Un jeton a fuité. On le révoque. Est-il coupé tout de suite, partout ? La réponse est non, et il faut savoir de combien.

**Ce qu'il faut savoir.** Keystone ne stocke pas les jetons (§ 1.4.7) ; révoquer, c'est ajouter une ligne à une **liste d'événements de révocation**, consultée à chaque validation. Mais les services ne valident pas à chaque appel : `keystonemiddleware` garde en **cache** le résultat d'une validation pendant quelques secondes.

**Ce qu'on va démontrer.** Keystone refuse le jeton immédiatement ; Neutron continue de l'accepter un court instant.

```bash
openstack token revoke "$TOKEN"
curl -s -o /dev/null -w "validation après révocation : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" \
  -H "X-Auth-Token: $ADMIN_TOKEN" -H "X-Subject-Token: $TOKEN"
curl -s -o /dev/null -w "appel Neutron après révocation : %{http_code}\n" \
  "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $TOKEN"
```

✅ **Observé :** `validation après révocation : 404` : Keystone refuse aussitôt le jeton. Pour Neutron, ça dépend du moment : le 17 octobre, `appel Neutron après révocation : 401` ; le 18 octobre, `200`.

**Pourquoi :** un service garde en **cache** les jetons qu'il vient de faire valider (bibliothèque `keystonemiddleware`), pour ne pas interroger Keystone à chaque appel. Un jeton que Neutron venait d'accepter (§ 1.4.5) est donc encore accepté juste après sa révocation. Mesuré le 18 octobre :

| Moment | Appel Neutron avec le jeton révoqué |
|---|---|
| Avant révocation | `200` |
| Juste après | `200` (cache) |
| 30 secondes après, et ensuite | `401` |

**Comment le lire.** Le 17 octobre, Neutron n'avait pas ce jeton en cache (le § 1.4.5 avait été joué plus tôt) : `401` immédiat. Le 18, il l'avait : `200` jusqu'à expiration du cache. Les deux résultats sont corrects ; la différence est le cache, pas Keystone.

⚠ **Piège :** révoquer un jeton volé ne le coupe pas **instantanément** partout : il reste utilisable quelques secondes, le temps que les caches des services expirent.

**Ce que ça change pour toi.** En réponse à incident, révoquer le jeton ne suffit pas : il faut aussi changer le mot de passe (sinon le voleur en redemande un) et, si l'origine est inconnue, désactiver le compte (`user set --disable`, TP 5). Et le délai du cache est à connaître pour ne pas croire la révocation en panne.

### 1.4.7 Durée de vie et clés Fernet

**Pourquoi on fait ça.** Deux questions d'exploitation : « combien de temps un jeton vaut-il ? » et « si on change les clés, est-ce que tout le monde est déconnecté ? ». La réponse est dans la configuration de Keystone et dans un répertoire de clés.

**Ce qu'il faut savoir.** Un jeton **Fernet** est un petit message **chiffré et signé** par Keystone avec une clé symétrique : il contient l'identifiant de l'utilisateur, la portée, les méthodes, l'expiration et un identifiant d'audit. Rien d'autre : ni rôles, ni catalogue (Keystone les recalcule à la validation). Il n'est **stocké nulle part** : il suffit de la clé pour le vérifier. Les clés tournent : à chaque rotation, une nouvelle clé **primaire** chiffre les nouveaux jetons, et les anciennes restent pour **déchiffrer** ceux déjà émis, jusqu'à leur expiration.

**Ce qu'on va démontrer.** Un jeton vit une heure ; Keystone garde quatre clés, numérotées, dont une primaire et une « en attente ».

```bash
python3 -c "import json; print(json.load(open('/tmp/token-body.json'))['token']['expires_at'])"
date -u +%Y-%m-%dT%H:%M:%S
$K exec keystone-0 -c keystone -- sh -c 'awk "/^\[/{p=(\$0==\"[token]\" || \$0==\"[fernet_tokens]\")} p && NF" /etc/keystone/keystone.conf; ls -l /etc/keystone/fernet-keys/'
```

**La commande, mot par mot :** `awk` lit le fichier ligne par ligne ; à chaque titre de section (`[…]`), il note si c'est `[token]` ou `[fernet_tokens]` ; il n'affiche que les lignes non vides (`NF`) de ces deux sections. `ls -l` liste les clés. (Un simple `grep -A6 "^\[token\]"` afficherait aussi le début des sections voisines.)

✅ **Observé** (17 octobre ; le 18, après une rotation, les clés étaient `0`, `8`, `9`, `10` : les numéros changent chaque jour, voir `7-securite/04-rotation-secrets.md`, § 4.3) :

```text
[token]
expiration = 3600
allow_expired_window = 169200

[fernet_tokens]
max_active_keys = 4

-rw------- 1 keystone keystone    44 Oct 17 17:10 0
-rw------- 1 keystone keystone    44 Oct 15 14:10 7
-rw------- 1 keystone keystone    44 Oct 15 14:10 8
-rw------- 1 keystone keystone    44 Oct 16 12:45 9
drwx------ 2 root     root     16384 Oct  9 10:35 lost+found
```

**Comment le lire :**

| Réglage | Signification |
|---|---|
| `expiration = 3600` | Un jeton vit **une heure** |
| `allow_expired_window = 169200` | Pendant 47 heures après expiration, un service peut encore faire accepter un jeton expiré pour **terminer** une opération longue déjà commencée (une migration de VM, par exemple) |
| `max_active_keys = 4` | Quatre clés Fernet au plus |
| Fichiers `0`, `7`, `8`, `9` | Les clés : `0` est la clé **en attente** (la prochaine primaire) ; la plus grande, `9`, est la clé **primaire**, qui chiffre les nouveaux jetons ; les autres servent encore à **déchiffrer** les jetons émis avant la dernière rotation |

Avec 4 clés et un jeton d'une heure, une rotation ne déconnecte personne : le jeton émis hier avec la clé `8` se déchiffre encore avec la clé `8`, tant qu'elle est dans le répertoire. Entre le 17 et le 18, la clé `7` a disparu et `10` est apparue : les jetons chiffrés avec `7` avaient tous expiré depuis longtemps.

`provider = fernet` n'est pas écrit : c'est la valeur par défaut. Le charm Keystone ne propose pas d'option Juju pour la durée des jetons ni pour la rotation des clés (`juju config -m openstack keystone` n'en montre aucune) : ces réglages sont fixés par le charm.

❓ **Question :** un jeton Fernet ne contient pas le catalogue, alors que la réponse de `POST /auth/tokens` le contient. Pourquoi ? *Réponse : le jeton Fernet est un petit message chiffré (utilisateur, portée, méthodes, expiration, identifiant d'audit) ; Keystone reconstruit le reste (rôles, catalogue) à chaque validation. Il n'est stocké nulle part : c'est pourquoi la révocation passe par une liste d'événements de révocation.*

**Ce que ça change pour toi.** Les clés Fernet sont **le** secret de Keystone : qui les a peut fabriquer un jeton de n'importe qui. Elles sont en `-rw-------`, propriété de `keystone`, et un Keystone multi-instances doit les partager (c'est le charm qui s'en occupe sur Sunbeam). Si tu les perds (restauration d'une sauvegarde sans ce répertoire), tous les jetons en cours deviennent invalides d'un coup : tout le monde se reconnecte, rien de plus.

---

## 1.5 D'où viennent les comptes ?

**Pourquoi on fait ça.** Avant de brancher un annuaire d'entreprise ou une fédération (module 11), il faut savoir ce qui existe déjà : où sont stockés les comptes, lesquels sont des humains et lesquels des services, et si une politique de mots de passe est en place. C'est aussi la première chose qu'un audit demande.

### 1.5.1 Identités locales (SQL)

**Ce qu'il faut savoir.** Keystone a un **pilote d'identité** (*driver*) par défaut, qui dit où il lit les comptes : `sql` (sa base) ou `ldap` (un annuaire). Depuis longtemps, il peut aussi avoir **un pilote différent par domaine** : le domaine `acme` sur l'annuaire d'Acme, le domaine `users` en SQL. C'est ce qui permet d'héberger plusieurs organisations avec chacune sa source de comptes.

**Ce qu'on va démontrer.** Les comptes du lab sont en SQL, et Keystone est déjà prêt à accepter une source par domaine.

```bash
openstack user show demo --domain users
$K exec keystone-0 -c keystone -- sh -c 'sed -n "/^\[identity\]/,/^\[/p" /etc/keystone/keystone.conf | grep -v "^\["'
```

La seconde commande n'affiche **que** la section `[identity]`. ⚠ Ne pas utiliser `grep -A8 "^\[identity\]"` : sur le lab, les lignes suivantes sont celles de la section `[database]`, dont la chaîne de connexion contient **le mot de passe MySQL de Keystone** (constaté).

✅ **Observé :**

```text
driver = sql
default_domain_id = default
domain_specific_drivers_enabled = True
domain_config_dir = /etc/keystone/domains
```

**Comment le lire :** les comptes sont en base SQL (`driver = sql`) ; mais `domain_specific_drivers_enabled = True` : Keystone accepte qu'**un domaine** ait sa **propre** source d'identité (un annuaire LDAP, par exemple), décrite par un fichier dans `/etc/keystone/domains`. C'est ce qui permet de brancher l'annuaire d'un client sur son seul domaine (module 11). Dans `user show demo`, le champ `password_expires_at` vide annonce déjà le § 1.5.4 : pas d'expiration des mots de passe.

**Ce que ça change pour toi.** Brancher un LDAP ne demande pas de migrer les comptes existants : on crée un domaine, on lui donne son fichier de configuration, et `users` reste en SQL. Un domaine LDAP est en général **en lecture seule** : on n'y crée pas de comptes avec `openstack user create`.

### 1.5.2 Comptes de service

**Ce qu'il faut savoir.** Les services OpenStack sont eux-mêmes des utilisateurs de Keystone : Nova a un compte pour valider les jetons (§ 1.4.4) et pour appeler Neutron ou Glance. Ces comptes ont le rôle `service`, prévu pour les distinguer des humains dans les politiques, et, sur ce lab, aussi `admin`.

**Ce qu'on va démontrer.** Il existe un compte par service, et il est plus puissant qu'un humain.

```bash
openstack user list --domain service_domain
openstack role assignment list --project services --project-domain service_domain --names
```

✅ **Observé :** un compte par service, nommé `svc_<service>-<suffixe aléatoire>` (`svc_nova-F8OChi`, `svc_neutron-Jbci5R`…), plus `horizon`, `cinder-volume`, `openstack-hypervisor` et `svc_remote_…`, chacun avec **deux** rôles sur le projet `services` : `admin` et `service`. Ce sont eux qui valident les jetons des utilisateurs (§ 1.4.4) et qui s'appellent entre eux (nova-compute → Neutron).

**Comment le lire.** `admin` sur le projet `services` : avec les anciennes règles (§ 1.6.1, « admin quelque part, admin partout »), chaque compte de service est donc **administrateur de tout le cloud**. C'est nécessaire aujourd'hui (Nova doit pouvoir toucher aux ports de tous les projets), et c'est précisément ce que le rôle `service` et Secure RBAC visent à réduire.

**Ce que ça change pour toi.** Les mots de passe de ces comptes sont dans les secrets Juju (`7-securite/04`). Leur fuite vaut une fuite du compte `admin`. Et dans un journal Keystone, un `POST /auth/tokens` de `svc_nova-…` toutes les quelques minutes est normal : c'est Nova qui renouvelle son jeton de service.

### 1.5.3 Identités externes (fédération)

**Ce qu'il faut savoir.** La **fédération** délègue l'authentification à un **fournisseur d'identité** externe (Keycloak, un Azure AD…) : Keystone ne connaît plus le mot de passe, il reçoit une assertion (SAML, OpenID Connect) et une **correspondance** (*mapping*) la traduit en utilisateur, groupe et projet. Keystone garde la trace de deux objets : le fournisseur (`identity provider`) et la correspondance (`mapping`).

**Ce qu'on va démontrer.** Rien n'est fédéré sur le lab, bien que Keycloak tourne à côté.

```bash
openstack identity provider list
openstack mapping list
```

✅ **Observé :** deux listes vides, tant que la fédération Keycloak n'est pas configurée (module 11). Keycloak tourne pourtant dans Lab-Services : **présence d'un fournisseur d'identité ne veut pas dire fédération active**.

**Ce que ça change pour toi.** Pour savoir si un cloud est fédéré, on ne regarde pas Horizon (qui n'affiche un bouton SSO que si on l'y configure), on lance ces deux commandes. La démo `7-securite/02` crée ces deux objets et montre `methods: ["saml2"]` dans le jeton obtenu.

### 1.5.4 Politique de mots de passe

**Ce qu'il faut savoir.** Keystone sait imposer une politique de mots de passe aux comptes SQL : longueur et complexité, expiration, verrouillage après échecs, interdiction de réutiliser les anciens. Tout est dans une section `[security_compliance]`. Sans elle, **rien** n'est imposé.

**Ce qu'on va démontrer.** Le lab n'impose rien.

```bash
$K exec keystone-0 -c keystone -- sh -c 'grep -E "^\[security_compliance\]" -A15 /etc/keystone/keystone.conf'
```

✅ **Observé :** aucune ligne, et `command terminated with exit code 1` (`grep` n'a rien trouvé) : la section est **absente**, donc réglages par défaut : pas de verrouillage après échecs, pas d'expiration des mots de passe. À comparer avec les recommandations de l'ANSSI vues au module 11.

**Ce que ça change pour toi.** Un compte SQL du lab accepte un mot de passe d'un caractère et résiste à un nombre illimité d'essais : les tentatives en boucle ne sont visibles que dans le journal (§ 1.7). Sur un cloud réel, soit on remplit cette section (la démo `7-securite/03` compare avec l'ANSSI), soit on fédère pour que la politique soit celle du fournisseur d'identité.

### Simulation : un utilisateur change son mot de passe

**Pourquoi on fait ça.** Vérifier qu'un utilisateur ordinaire peut changer **son propre** mot de passe sans administrateur, et voir ce que Keystone exige pour ça.

**Ce qu'on va démontrer.** Le changement passe par l'API `POST /users/{id}/password`, avec le jeton de l'utilisateur **et** l'ancien mot de passe.

```bash
openstack user create lab-pwtest --domain users --password "$LAB_PW"
openstack role add --user lab-pwtest --user-domain users --project demo --project-domain users member
os_as lab-pwtest users projet demo users -- user password set --original-password "$LAB_PW" --password "${LAB_PW}-2"
```

⚠ **Observé :** avec le client `openstack` 7.5.0 du lab, cette commande **plante** : `Proxy.update_user() missing 1 required positional argument: 'user'`. C'est un défaut du client, pas de Keystone : le mot de passe n'est pas changé. On passe donc par l'**API**, ce que fait de toute façon le client :

```bash
USER_ID=$(openstack user show lab-pwtest --domain users -f value -c id)
[ -n "$USER_ID" ] || echo "ATTENTION : identifiant vide, relancer la commande precedente"
T=$(os_as lab-pwtest users projet demo users -- token issue -f value -c id)
curl -s -o /dev/null -w "changement : %{http_code}\n" -X POST "$OS_AUTH_URL/users/$USER_ID/password" \
  -H "X-Auth-Token: $T" -H "Content-Type: application/json" \
  -d "{\"user\": {\"original_password\": \"$LAB_PW\", \"password\": \"${LAB_PW}-2\"}}"
LAB_PW="${LAB_PW}-2" os_as lab-pwtest users projet demo users -- token issue -c expires
openstack user delete lab-pwtest --domain users
```

✅ **Observé** (18 octobre 2026) : `changement : 204`, puis un jeton obtenu avec le nouveau mot de passe. Un utilisateur change son mot de passe avec **son propre** jeton, en prouvant qu'il connaît l'ancien.

**Comment le lire.** `204` = fait, sans contenu. L'ancien mot de passe est exigé même avec un jeton valable : un jeton volé (§ 1.4.5) ne permet donc **pas** de changer le mot de passe et de verrouiller le propriétaire dehors. C'est une des rares protections qui ne dépend pas du jeton.

⚠ **Pièges :**

- si `USER_ID` est vide (commande précédente en échec), la requête part vers `…/v3/users/password` et Keystone répond `500` (constaté dans son journal) ;
- `os_as` lit `LAB_PW` : d'où le `LAB_PW=… os_as` sur une seule ligne, pour ne pas modifier la variable de la session.

---

## 1.6 Pourquoi cette commande est-elle refusée, et pouvait-on le prédire ?

**Pourquoi on fait ça.** Un `403` arrive. L'apprenant sait maintenant qui il est et quels rôles porte son jeton. Il manque le dernier maillon : **la règle** que le service a appliquée. Chaque service a son fichier de politiques ; en le lisant, on prédit le refus avant de le voir, et on l'explique après.

**Ce qu'il faut savoir.** Une **politique** est une liste de règles : pour chaque action (`identity:create_user`, `os_compute_api:servers:create`…), une expression qui dit qui a le droit, en fonction des **rôles** du jeton, de sa **portée**, et parfois de la cible (`project_id:%(project_id)s` : « le projet du jeton est celui de la ressource »). Les règles ont changé avec le temps : les **anciennes** se résument à « `admin` peut tout, `member` le reste » ; les **nouvelles** (*Secure RBAC*) distinguent `reader`, `member`, `manager`, `admin` **et** les portées. Deux options par service disent lesquelles s'appliquent : `enforce_new_defaults` (nouvelles règles) et `enforce_scope` (refuser une portée inadaptée).

### 1.6.1 Où en est Secure RBAC sur ton lab (à faire en premier)

**Ce qu'on va démontrer.** Aucun service du lab ne fixe ces deux options, et leur valeur par défaut est `false` : le lab est sous les **anciennes** règles. Toute la suite des TP en dépend.

```bash
for pc in keystone-0/keystone:/etc/keystone/keystone.conf nova-0/nova-api:/etc/nova/nova.conf \
          neutron-0/neutron-server:/etc/neutron/neutron.conf glance-0/glance-api:/etc/glance/glance-api.conf \
          placement-0/placement-api:/etc/placement/placement.conf; do
  pod=${pc%%/*}; rest=${pc#*/}; c=${rest%%:*}; f=${rest#*:}
  echo "== $c"; $K exec "$pod" -c "$c" -- sh -c "grep -A6 '^\[oslo_policy\]' $f 2>/dev/null | grep -E 'enforce_scope|enforce_new_defaults|policy_file' || echo '  (valeurs par defaut)'"
done
```

✅ **Observé :** les cinq services répondent `(valeurs par defaut)` : aucun ne fixe ces options dans son fichier.

« Valeurs par défaut » : pour les lire, génère la configuration de référence de la bibliothèque de politiques :

```bash
$K exec keystone-0 -c keystone -- oslo-config-generator --namespace oslo.policy 2>/dev/null | grep -B2 -A2 -E "^#enforce_(scope|new_defaults)"
```

✅ **Observé :** `#enforce_scope = false` et `#enforce_new_defaults = false`.

⚠ Ce sont les défauts de la **bibliothèque** ; un service peut les surcharger dans son code. La preuve se lit dans les règles (§ 1.6.2) et dans les essais des TP 2 à 4. Note le résultat :

| Service | `enforce_scope` | `enforce_new_defaults` |
|---|---|---|
| Keystone | | |
| Nova | | |
| Neutron | | |
| Glance | | |
| Placement | | |

**Comment le lire :**

| Si… | Alors |
|---|---|
| `enforce_scope = True` et `enforce_new_defaults = True` | Secure RBAC complet : `reader`, `member`, `manager`, `admin` et les portées s'appliquent comme dans le support |
| `enforce_new_defaults = True` seul | Les nouveaux rôles s'appliquent, mais une portée inadaptée n'est pas refusée |
| les deux à `False` | Anciennes règles : `admin` sur n'importe quel projet = administrateur de tout le cloud (« admin quelque part, admin partout ») |

**Ce que ça change pour toi.** Le support décrit Secure RBAC ; **le lab ne l'applique pas**. Concrètement, pour les TP qui suivent : `manager` ne donne rien (TP 2), `reader` et `member` se comportent presque pareil sur certains services (TP 4, matrice), et un `admin` donné sur un seul projet fait un administrateur de tout (TP 2, § 2.3). Ce n'est pas un défaut du lab : c'est l'état de la plupart des clouds 2024.1 en production.

### 1.6.2 Lire une règle

**Ce qu'on va démontrer.** On lit les règles de Keystone pour cinq actions courantes, et on en tire deux conclusions qui expliquent les refus des TP 2 à 5.

```bash
$K exec keystone-0 -c keystone -- oslopolicy-policy-generator --namespace keystone 2>/dev/null \
  | grep -E '"identity:(list_users|create_user|list_projects|create_project|create_grant)"'
```

`oslopolicy-policy-generator` affiche les règles **effectives** : celles du code, surchargées par un éventuel fichier `policy.yaml`. C'est la seule source fiable ; un fichier `policy.yaml` vide ou absent ne veut pas dire « pas de règles ».

✅ **Observé sur le lab :**

```text
"identity:create_grant": "(rule:admin_required) or ((role:admin and domain_id:%(target.user.domain_id)s and domain_id:%(target.project.domain_id)s) or …"
"identity:list_projects": "(rule:admin_required) or (role:reader and system_scope:all) or (role:reader and domain_id:%(target.domain_id)s)"
"identity:create_project": "rule:admin_required"
"identity:list_users": "(rule:admin_required) or (role:reader and system_scope:all) or (role:reader and domain_id:%(target.domain_id)s)"
"identity:create_user": "rule:admin_required"
```

**Comment le lire :**

| Règle | Qui peut |
|---|---|
| `list_users`, `list_projects` | Un `admin` (`rule:admin_required`), **ou** un `reader` sur le système, **ou** un `reader` sur le domaine visé |
| `create_user`, `create_project` | **Seulement** un `admin` |
| `create_grant` (donner un rôle) | Un `admin`, éventuellement limité au domaine de l'utilisateur et de la cible |

Une règle se lit de gauche à droite comme un **ou** : il suffit qu'une branche soit vraie. `role:reader and domain_id:%(target.domain_id)s` se lit « le jeton a `reader` **et** sa portée est le domaine qu'on cherche à lister ». Comme `admin` implique `reader` (§ 1.2), un administrateur de domaine passe aussi par cette branche.

Deux conclusions, essentielles pour la suite :

1. **`rule:admin_required` est en tête de chaque règle**, et il ne regarde pas la portée : un rôle `admin`, **n'importe où**, suffit. C'est la marque des anciennes règles (`enforce_new_defaults = false`), et l'origine du « admin quelque part, admin partout » (TP 2, § 2.3).
2. **Aucune règle ne mentionne `manager`** : sur ce Keystone, un gestionnaire de domaine ne peut ni créer de comptes ni créer de projets. Le TP 2 (§ 2.4) le vérifie.

Même exercice pour Nova et Neutron :

```bash
$K exec nova-0 -c nova-api -- oslopolicy-policy-generator --namespace nova 2>/dev/null | grep -E '"os_compute_api:(servers:create|os-hypervisors:list)"'
$K exec neutron-0 -c neutron-server -- oslopolicy-policy-generator --namespace neutron 2>/dev/null | grep -E '"(create_network|create_network:shared)"'
```

✅ **Observé :**

```text
"os_compute_api:os-hypervisors:list": "rule:context_is_admin"
"os_compute_api:servers:create": "rule:project_member_or_admin"
"create_network": "(rule:admin_only) or (role:member and project_id:%(project_id)s)"
"create_network:shared": "rule:admin_only"
```

**Comment le lire.** Lister les hyperviseurs : réservé à l'administrateur ; créer une VM : membre du projet ou administrateur ; créer un réseau : administrateur, ou `member` **du projet** ; le rendre partagé : administrateur seulement. Chaque service a ses propres noms de règles de base (`admin_required` chez Keystone, `context_is_admin` chez Nova, `admin_only` chez Neutron) pour la même idée : « a le rôle `admin` ».

❓ **Question :** pourquoi `create_network:shared` a-t-il une règle distincte de `create_network` ? *Réponse : un réseau partagé est visible par tous les projets ; c'est une action d'administration, alors que créer un réseau privé est un droit de membre.*

**Ce que ça change pour toi.** Avant de dire « il n'a pas le droit », tu peux maintenant le **prouver** avec la règle. Et avant de donner un rôle, tu peux lire ce qu'il ouvre : c'est la méthode du TP 4 pour construire un rôle de moindre privilège.

### 1.6.3 Expliquer un refus

**Ce qu'on va démontrer.** Les trois refus ci-dessous étaient prévisibles à partir des règles lues en 1.6.2, et chaque message d'erreur **nomme** la règle.

```bash
source ~/demo-openrc
openstack user list
openstack hypervisor list
openstack network create lab-partage --share
source ~/admin-openrc
```

⛔ **Refus observés** pour les trois, avec un code `403` :

```text
ForbiddenException: 403: … You are not authorized to perform the requested action: identity:list_users.
ForbiddenException: 403: … Policy doesn't allow os_compute_api:os-hypervisors:list-detail to be performed.
Error while executing command: ForbiddenException: 403, (rule:create_network and rule:create_network:shared) is disallowed by policy
```

**Comment le lire.** `demo` a `member` et `reader` sur le **projet** `demo`, rien d'autre. Règle par règle :

| Refus | Règle (1.6.2) | Pourquoi `demo` échoue |
|---|---|---|
| `identity:list_users` | `admin_required` **ou** `reader` sur le système **ou** `reader` sur le domaine | Son `reader` est sur un **projet**, pas sur un domaine ni le système |
| `os-hypervisors:list` | `context_is_admin` | Il n'est pas `admin` |
| `create_network:shared` | `admin_only` | `create_network` passe (il est `member` du projet), mais `:shared` exige `admin` |

Chaque message **nomme la règle** refusée : l'apprenant la relie à celle lue en 1.6.2. Noter que le troisième message cite les **deux** règles évaluées.

| Code | Signification |
|---|---|
| `401 Unauthorized` | Keystone ne sait pas qui tu es (jeton absent, expiré, révoqué, mauvais mot de passe) |
| `403 Forbidden` | Keystone sait qui tu es, mais la **politique** du service refuse cette action à ton rôle sur cette portée |

**Ce que ça change pour toi.** Face à un refus, trois questions dans l'ordre : `401` ou `403` ? Si `403`, quelle règle est nommée ? Quels rôles et quelle portée a le jeton (`token issue`, `role assignment list --effective`) ? La réponse est toujours dans la comparaison des deux.

---

## 1.7 Comment relier un refus vu par l'utilisateur à une ligne du journal ?

**Pourquoi on fait ça.** Un utilisateur dit « ça m'a refusé » sans plus de détail. Toi, tu as les journaux de Keystone, avec des centaines de lignes. Il faut un fil pour retrouver **sa** requête.

**Ce qu'il faut savoir.** Chaque requête reçoit un **identifiant de requête** (`X-Openstack-Request-Id`, de la forme `req-…`), renvoyé au client dans les en-têtes et écrit dans le journal du service. C'est la clé commune aux deux côtés. Et quand une requête traverse plusieurs services (Nova appelle Neutron), chacun en journalise un, lié au précédent.

**Ce qu'on va démontrer.** Le `req-…` reçu par le client se retrouve, à l'identique, dans la ligne d'erreur de Keystone.

```bash
source ~/demo-openrc
openstack --debug user list 2>&1 | grep -i -E "X-Openstack-Request-Id|RESP: \[403\]" | head -3
source ~/admin-openrc
$K logs keystone-0 -c keystone --since=2m | grep -E " 403 |Forbidden|not authorized" | tail -3
```

✅ **Observé :** le client reçoit `RESP: [403] … X-Openstack-Request-Id: req-40a5efb0-…` ; le journal de Keystone contient la même requête :

```text
… ERROR keystone.server.flask.application [None req-40a5efb0-a28e-4ac4-a530-625bd7acda2a …] keystone.exception.ForbiddenAction: You are not authorized to perform the requested action: identity:list_users.
… "GET /openstack-keystone/v3/users HTTP/1.1" 403 132 …
```

**Comment le lire.** L'identifiant de requête relie le refus vu par l'utilisateur à la ligne du serveur. Deux lignes côté Keystone : l'exception, qui nomme la règle (`identity:list_users`, comme au § 1.6.3), et la ligne d'accès Apache, avec le code `403`. La première dit *pourquoi*, la seconde dit *quand* et *quoi*.

**Ce que ça change pour toi.** Demande toujours à l'utilisateur de relancer avec `--debug` et de te donner le `req-…` : c'est plus rapide que de fouiller par heure. Et au TP 2, c'est ce journal (`ForbiddenAction identity:create_grant`) qui révélera un refus que le client **n'affiche pas**.

---

## Ce qu'il faut retenir

| Question | Réponse courte | Preuve dans le TP |
|---|---|---|
| Qui a le droit de faire quoi ? | Seules les **affectations** le disent ; les rôles impliqués s'y ajoutent au moment du jeton | 1.2 |
| Comment le client trouve-t-il les services ? | Dans le **catalogue**, renvoyé avec le jeton ; `internal` dépend du DNS de Lab-Services | 1.3 |
| Que vaut un jeton ? | Une heure, pour une **portée**, pour quiconque le détient ; révocable, avec un délai de cache | 1.4 |
| D'où viennent les comptes ? | SQL ici, une source possible par domaine, aucune fédération ni politique de mots de passe | 1.5 |
| Pourquoi ce `403` ? | La **règle** nommée dans le message, lue avec `oslopolicy-policy-generator` ; le lab est sous les anciennes règles | 1.6 |
| Comment retrouver la requête ? | Par son `req-…`, identique côté client et côté journal | 1.7 |

## Nettoyage

```bash
rm -f /tmp/auth-projet.json /tmp/auth-defaut.json /tmp/auth-sans-portee.json /tmp/token-body.json /tmp/token-headers.txt
openstack user delete lab-pwtest --domain users 2>/dev/null
```

## Pour aller plus loin

- Lancer le traceur (`2-trace/PAS-A-PAS.md`) pendant le § 1.4 : chaque `POST /auth/tokens` et chaque validation `GET /auth/tokens` apparaît en direct.
- Mesurer la taille d'un jeton : `openstack token issue -f value -c id | wc -c`.
