# TP 1 : Keystone en profondeur

> Statut : **§ 1.1 à 1.7 rejoués sur le lab les 17 et 18 octobre 2026** (Keystone 2024.1, client `openstack` 7.5.0). Les résultats ✅ sont ceux observés. **§ 1.8 (démos complémentaires) : pas encore rejoué** ; les résultats y sont notés 🔲 **Attendu**, à remplacer par ✅ après passage sur le lab. Voir les conventions dans [README.md](README.md).

**Module du support :** 8, Keystone en profondeur.
**Durée :** 2 h 30 (§ 1.1 à 1.7), plus 1 h à 1 h 30 si l’on ajoute le § 1.8.
**Objectifs :** à la fin du TP, l’apprenant sait inventorier les entités de Keystone, lire le catalogue, obtenir, inspecter, valider et révoquer un jeton à la main, identifier la source d’identité d’un compte, et lire une règle de politique pour expliquer un refus.

**Prérequis :** lab démarré et prêt (étape 10 du guide apprenant), session préparée :

```bash
source ~/labs-iam/lab-env.sh
K="sudo k8s kubectl -n openstack"
```

`lab-env.sh` charge les variables `OS_*` de l’administrateur (`admin` du domaine `admin_domain`, projet `admin`), la variable `LAB_PW` et la fonction `os_as`. `K` est un raccourci : toutes les commandes `$K …` parlent au Kubernetes de Sunbeam, dans l’espace de noms `openstack`, où tournent les pods des services.

---

## 1.1 Où tourne Keystone sur Sunbeam

```bash
juju status -m openstack keystone
$K get pod keystone-0 -o wide
$K logs keystone-0 -c keystone --tail=5
```

✅ **Observé** (18 octobre 2026) : l’application `keystone` est `active` ; un pod `keystone-0` en `2/2` (deux conteneurs, `charm` et `keystone`) ; des lignes du serveur web Apache. Selon le moment, ce sont surtout des `"GET /healthcheck HTTP/1.1" 200` (le test de santé que Pebble fait toutes les quelques secondes) ou des `"POST /openstack-keystone/v3/auth/tokens HTTP/1.1" 201` (des demandes de jetons). Pour ne voir que les jetons : `$K logs keystone-0 -c keystone --since=10m | grep auth/tokens | tail -3`.

**Comment lire ces sorties :**

| Valeur | Signification |
|---|---|
| `active` (Juju) | Le charm a terminé sa configuration et juge le service opérationnel : base joignable, clés présentes, points d’accès déclarés |
| `2/2` (Kubernetes) | 2 conteneurs prêts sur 2. Le conteneur `charm` exécute le code Juju qui configure Keystone ; le conteneur `keystone` exécute Apache + Keystone. Pebble est le petit superviseur qui, dans le conteneur `keystone`, démarre Apache et le teste |
| `-c keystone` | Dans un pod à plusieurs conteneurs, `kubectl logs` exige de dire lequel lire |
| `201` sur `POST …/auth/tokens` | `201 Created` : un jeton vient d’être créé. C’est le code normal d’une authentification réussie |
| `200` sur `GET /healthcheck` | Pebble demande « es-tu vivant ? », Keystone répond oui. Ces lignes n’ont rien à voir avec les utilisateurs |

❓ **Question :** pourquoi `keystone-0` n’a-t-il pas de base de données dans le pod ? *Réponse : il utilise MySQL (pod `mysql-0`) via `keystone-mysql-router` ; Keystone est sans état local, hormis ses clés Fernet.*

---

## 1.2 Inventaire des entités

### Scénario : dresser la carte d’un cloud qu’on découvre

Tu arrives sur un cloud inconnu ; tu dois en décrire l’organisation en 10 minutes.

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

`--names` remplace les identifiants (longues chaînes hexadécimales) par des noms au format `nom@domaine` : `demo@users` se lit « le compte `demo` du domaine `users` ».

✅ **Observé sur le lab :**

| Entité | Valeurs |
|---|---|
| Domaines | `admin_domain`, `service_domain` (description « Created by Juju »), `users`, `Default` |
| Projets | `admin` (dans `admin_domain`), `services` (dans `service_domain`), `demo` (dans `users`), et un second `admin` dans `Default` : « Bootstrap project for initializing the cloud » |
| Utilisateurs | `admin` ; dans `service_domain`, un compte par service avec un suffixe aléatoire (`svc_nova-F8OChi`, `svc_neutron-Jbci5R`, `svc_glance-…`, `svc_placement-…`, `svc_cinder-…`), plus `horizon`, `cinder-volume`, `openstack-hypervisor` et un `svc_remote_…` ; `demo` dans `users` ; `_charm-keystone-admin` dans `Default` |
| Rôles | `admin`, `manager`, `member`, `reader`, `service` |
| Rôles impliqués | `admin` → `manager` → `member` → `reader` |
| Régions | `RegionOne` |
| Affectations | `admin@admin_domain` : `admin` et `member` sur le projet `admin`, `admin` sur le **domaine** `admin_domain` ; chaque compte de service : `admin` **et** `service` sur `services` ; `demo` : `member` sur `demo` ; `_charm-keystone-admin@Default` : `admin` sur le **système** (le seul) |

**Comment lire ce tableau :**

- **`Default` et son projet `admin`** : Keystone crée toujours le domaine `Default` à son initialisation (`keystone-manage bootstrap`), avec un projet et un compte d’amorçage. Le charm crée ensuite ses propres domaines (`admin_domain`, `service_domain`, `users`) et range tout dedans ; `Default` ne garde que le compte du charm.
- **Rôles impliqués** : la flèche `admin → manager` signifie « qui a `admin` reçoit aussi `manager` ». On n’affecte donc qu’un seul rôle, et Keystone ajoute les autres dans le jeton (voir § 1.4.2).
- **Rôle `service`** : il ne donne pas de droits d’administration ; il marque le compte comme « un service OpenStack ». Certaines règles l’exigent, par exemple pour qu’un service puisse faire accepter un jeton expiré en fin d’opération longue (`allow_expired_window`, § 1.4.7).
- **`RegionOne`** : le nom de région par défaut. Une région est un regroupement de points d’accès (un site, un centre de données) ; le client choisit la sienne avec `OS_REGION_NAME`.

`_charm-keystone-admin` est le compte que le charm Keystone utilise lui-même pour administrer Keystone : c’est le seul à avoir un rôle sur le système.

### Exercice

Les apprenants complètent ce tableau à partir de leurs sorties :

| Question | Commande | Leur réponse |
|---|---|---|
| Combien de domaines, et lequel héberge les comptes des services ? | `openstack domain list` | |
| Quels utilisateurs ont un rôle sur le projet `services` ? | `openstack role assignment list --project services --project-domain service_domain --names` | |
| Quel rôle `admin` implique-t-il ? | `openstack implied role list` | |
| L’utilisateur `demo` peut-il voir le projet `admin` ? | `openstack role assignment list --user demo --user-domain users --names` | |

⚠ **Piège :** `openstack user list` sans `--domain` ne liste **pas** tous les comptes. Sur le lab, avec le jeton de l’administrateur (projet `admin` du domaine `admin_domain`), il ne renvoie qu’**un** compte, `admin` : ceux du domaine du jeton. Pour inventorier un cloud, interroger chaque domaine : `for d in $(openstack domain list -f value -c Name); do openstack user list --domain "$d"; done`. Deux utilisateurs peuvent aussi porter le même nom dans deux domaines différents (TP 2) : un nom seul ne désigne pas un compte.

### Lire une affectation effective

```bash
openstack role assignment list --user demo --user-domain users --names --effective
```

`--effective` développe les **rôles impliqués** et les **groupes** : il répond à la question « que peut réellement faire ce compte ? », alors que la liste simple ne montre que les affectations directes.

❓ **Question :** pourquoi la liste effective de `demo` contient-elle `reader` alors qu’on ne lui a affecté que `member` ? *Réponse : `member` implique `reader` (`openstack implied role list`).*

---

## 1.3 Le catalogue de services

### Scénario : comment le client trouve Neutron

```bash
openstack catalog list
openstack catalog show network
openstack endpoint list --service network
openstack endpoint list --interface internal
```

✅ **Observé :** chaque service a **trois** points d’accès dans `RegionOne` : **public** (`http://cloud.lab.test:80/openstack-<service>`), **internal** (`http://internal.lab.test:80/openstack-<service>`) et **admin** (une adresse interne à Kubernetes, par exemple `http://10.152.183.106:9696` pour Neutron). Exceptions : Keystone, dont l’interface `admin` est aussi `internal.lab.test` ; le stockage objet (`swift`, `s3`), servi par `rgw.lab.test`.

**Vocabulaire :** le **catalogue** est la liste des **services** (une ligne par service : son nom, comme `neutron`, et son **type**, comme `network`). Chaque service a plusieurs **points d’accès** (*endpoints*) : une URL par interface et par région. Le client cherche un service par son **type** (`network`), jamais par son nom : c’est pourquoi `openstack catalog show network` fonctionne.

| Interface | Adresse | Qui l’utilise |
|---|---|---|
| `public` | `cloud.lab.test` → `192.168.56.201` (Traefik public) | Clients : CLI, Horizon, apprenants |
| `internal` | `internal.lab.test` → `192.168.56.202` (Traefik interne) | Services entre eux : nova-compute → Neutron, Glance… ; c’est aussi l’adresse par laquelle les services **valident les jetons** auprès de Keystone |
| `admin` | `10.152.183.x` (adresse de service Kubernetes) | Joignable seulement depuis le cluster |

**Pourquoi `10.152.183.x` :** c’est la plage des adresses de **service** (*ClusterIP*) du Kubernetes de Sunbeam. Une telle adresse n’existe qu’à l’intérieur du cluster : Kubernetes la traduit vers le pod. Depuis Windows ou depuis le réseau du lab, elle ne répond pas. `:9696` est le port historique de Neutron, `:80` celui de Traefik.

⚠ Les services résolvent `internal.lab.test` grâce au DNS de **Lab-Services**. Si Lab-Services est arrêté, Nova, Neutron et Cinder ne peuvent plus valider les jetons et répondent `503 … The Keystone service is temporarily unavailable` (constaté sur le lab).

Voir le catalogue dans le jeton lui-même, et l’appel qui suit :

```bash
openstack --debug network list 2>&1 | grep -E "^REQ: curl|^RESP: \[" | head -6
```

**La commande, morceau par morceau :** `--debug` fait afficher au client chaque requête HTTP sous la forme d’une commande `curl` équivalente (`REQ: curl …`) et chaque réponse (`RESP: [code] …`). Ces traces partent sur la sortie d’erreur : `2>&1` les renvoie dans le tube pour que `grep` les voie. `head -6` garde les 6 premières lignes.

✅ **Observé** (18 octobre 2026) :

```text
REQ: curl -g -i -X GET http://cloud.lab.test/openstack-keystone/v3 …
RESP: [200] …
REQ: curl -g -i -X GET http://cloud.lab.test:80/openstack-neutron/v2.0/networks …
RESP: [200] …
```

**Comment le lire :** le client interroge d’abord Keystone (`GET …/v3` : découverte de la version de l’API), puis obtient un jeton (`POST …/auth/tokens`, que le client n’affiche pas sous la forme `REQ: curl`, car la requête contient le mot de passe), puis appelle Neutron. L’adresse de Neutron, `http://cloud.lab.test:80/openstack-neutron`, il l’a lue **dans le catalogue renvoyé avec le jeton** ; il ne la connaissait pas.

### Simulation : demander une autre interface

```bash
openstack --os-interface internal --debug network list 2>&1 | grep -E "^REQ: curl" | sed -n 2p
```

`sed -n 2p` affiche seulement la 2ᵉ ligne : la 1ʳᵉ est la découverte de Keystone, la 2ᵉ l’appel à Neutron.

✅ **Observé :** l’appel part cette fois vers `http://internal.lab.test:80/openstack-neutron/v2.0/networks`. Depuis Lab-Sunbeam, les deux fonctionnent ; depuis Windows, seul `public` est prévu.

❓ **Question :** un apprenant obtient `EndpointNotFound` en appelant `openstack volume list`. Quelles sont les trois causes possibles ? *Réponse : service absent du catalogue, mauvaise région (`OS_REGION_NAME`), interface demandée inexistante pour ce service.*

---

## 1.4 Les jetons

### 1.4.1 Obtenir un jeton avec le client

```bash
openstack token issue
```

✅ **Observé :** les champs `expires` (une heure plus tard), `id` (le jeton, environ 180 caractères, commençant par `gAAAAA`), `project_id`, `user_id`.

**Comment lire ces champs :**

| Champ | Signification |
|---|---|
| `id` | Le jeton lui-même : c’est **lui** que le client envoie ensuite dans l’en-tête `X-Auth-Token` de chaque appel. Il est secret : qui le possède agit en ton nom (§ 1.4.5) |
| `gAAAAA…` | Tous les jetons Fernet commencent ainsi. Le premier octet d’un jeton Fernet est la version du format (`0x80`), suivi de la date de création sur 8 octets, dont les premiers valent zéro. En base64, `0x80 00 00 00…` s’écrit `gAAAAA` |
| ~180 caractères | La taille d’un jeton Fernet de projet. Il ne contient **pas** le catalogue ni les rôles (§ 1.4.7), d’où sa petite taille |
| `expires` | Date d’expiration, en temps universel (UTC) : une heure après l’émission (`expiration = 3600`, § 1.4.7) |
| `project_id`, `user_id` | Identifiants (et non noms) du projet de la portée et du compte. Ce sont eux que les services comparent aux propriétaires des ressources |

### 1.4.2 Obtenir un jeton à la main, avec l’API

Le corps de la requête décrit **qui** (méthode `password`) et **pour quoi** (portée `scope`).

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

**La demande, bloc par bloc :**

| Bloc | Rôle |
|---|---|
| `DEMO_PW=…` | Extrait le mot de passe de `demo` de son fichier `demo-openrc` : `sed` garde ce qui suit `export OS_PASSWORD=`, `tr` retire les guillemets |
| `"methods": ["password"]` | Comment je prouve qui je suis : par mot de passe. D’autres méthodes existent : `token`, `application_credential` (§ 1.8.1), `totp` |
| `"user": {"name": "demo", "domain": {"name": "users"}}` | Le nom **et** le domaine : un nom seul est ambigu (deux domaines peuvent avoir un `demo`) |
| `"scope": {"project": …}` | Sur quoi je veux agir : le projet `demo` du domaine `users`. Le domaine de l’utilisateur et celui du projet sont indépendants |
| `-o` / `-D` | `-o` écrit le **corps** de la réponse dans un fichier, `-D` les **en-têtes** dans un autre |

⚠ Ne pas ajouter `-i` : il mêlerait les en-têtes au corps, et le fichier ne serait plus du JSON lisible (constaté : `Expecting value: line 1 column 1`).

✅ **Observé :**

- le jeton est dans l’**en-tête** `X-Subject-Token` (`gAAAAA…`), pas dans le corps ;
- le corps contient `methods: ["password"]`, `user`, `project`, `roles`, `expires_at`, `issued_at`, `audit_ids`, et `catalog` (la liste des services).

**Comment lire le corps de la réponse :**

| Champ | Signification |
|---|---|
| `methods` | Comment le jeton a été obtenu (`password`). Une règle de sécurité peut exiger certaines méthodes (authentification à plusieurs facteurs, § 1.8.6) |
| `user` | Le compte : `id`, `name`, `domain`, et `password_expires_at` (`null` : le mot de passe n’expire pas, § 1.5.4) |
| `project` | La portée du jeton : le projet sur lequel il permet d’agir |
| `roles` | Les rôles du compte **sur cette portée**, rôles impliqués compris |
| `issued_at` / `expires_at` | Émission et expiration, en UTC |
| `audit_ids` | Un identifiant court du jeton, **non secret**. On le trouve dans les journaux et dans les événements de révocation : il permet de suivre un jeton sans jamais écrire le jeton lui-même |
| `catalog` | Le catalogue de services, tel que vu au § 1.3, joint pour que le client sache où appeler chaque service |

Pour extraire les trois valeurs utiles :

```bash
python3 -c "import json; t=json.load(open('/tmp/token-body.json'))['token']; print('roles :', [r['name'] for r in t['roles']]); print('services au catalogue :', len(t['catalog'])); print('expire :', t['expires_at'])"
```

```text
roles : ['member', 'reader']
services au catalogue : 9
expire : 2026-10-17T21:47:25.000000Z
```

**Comment lire ces trois lignes :**

| Ligne | Ce qu’elle dit | Pourquoi |
|---|---|---|
| `roles : ['member', 'reader']` | `demo` a deux rôles sur le projet `demo` | On ne lui a affecté que `member` (§ 1.2). Keystone a ajouté `reader`, parce que `member` implique `reader`. Les rôles impliqués sont **développés dans le jeton** : les services n’ont pas à connaître la chaîne `admin → manager → member → reader`, ils lisent simplement la liste |
| `services au catalogue : 9` | Le catalogue joint au jeton contient **9 services** | `len(t['catalog'])` compte les **entrées** du catalogue, et chaque entrée est **un service** (Keystone, Nova, Neutron, Glance…), avec à l’intérieur la liste de ses points d’accès. Ce n’est **pas** le nombre de points d’accès : 9 services × 3 interfaces donnent environ 27 points d’accès. C’est le même nombre que les lignes de `openstack catalog list` |
| `expire : 2026-10-17T21:47:25.000000Z` | Le jeton expire le 17 octobre à 21 h 47 min 25 s **UTC** | Format ISO 8601 : date, `T`, heure. Le `Z` final signifie « temps universel » : à Paris en octobre (heure d’été jusqu’au 25 octobre), c’est **23 h 47**. Les six zéros sont les microsecondes, que Keystone arrondit à la seconde. C’est `issued_at` + 3 600 s |

Pour voir **quels** sont ces 9 services, et le nombre de points d’accès de chacun :

```bash
python3 -c "import json; t=json.load(open('/tmp/token-body.json'))['token']
for s in t['catalog']: print(f\"{s['type']:16} {s['name']:12} {len(s['endpoints'])} points d'acces\")"
openstack catalog list -f value -c Name -c Type | sort
openstack endpoint list -f value | wc -l
```

La première commande affiche une ligne par service (type, nom, nombre de points d’accès) ; la deuxième affiche la même liste vue par le client ; la troisième compte tous les points d’accès. Les apprenants vérifient que le nombre de lignes des deux premières vaut 9, et que la troisième vaut à peu près 9 × 3.

L’ordre des rôles peut varier d’un jeton à l’autre (`['reader', 'member']` le 18 octobre) : Keystone ne les trie pas.

### 1.4.3 Les portées : sans portée, projet, domaine, système

**Jeton sans portée** : il prouve l’identité, sans autoriser d’action. Première tentative, en retirant simplement le `scope` de la demande :

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

Le script Python fabrique deux variantes de la demande : `auth-defaut.json` (sans bloc `scope`) et `auth-sans-portee.json` (avec `"scope": "unscoped"`). La dernière ligne affiche trois réponses : le jeton contient-il des rôles ? un catalogue ? sur quel projet porte-t-il ?

✅ **Observé :** `True True demo`. Surprise : le jeton **a** une portée, le projet `demo`. Le compte `demo` a un **projet par défaut** (`openstack user show demo --domain users -c default_project_id`) : sans portée demandée, Keystone lui applique celui-là.

Pour un vrai jeton sans portée, il faut le **demander explicitement** avec `"scope": "unscoped"` (second fichier préparé ci-dessus) :

```bash
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-sans-portee.json \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['token']; print('roles' in t, 'catalog' in t, list(t))"
```

✅ **Observé :** `False False ['methods', 'user', 'audit_ids', 'expires_at', 'issued_at']` : ni rôles, ni catalogue, ni projet. Sans portée, il n’y a rien sur quoi calculer des rôles, et aucun service à appeler : le jeton dit seulement « c’est bien `demo` ». Il sert à découvrir ce à quoi on a droit :

```bash
UNSCOPED=$(curl -s -i -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/auth-sans-portee.json | grep -i "^X-Subject-Token" | cut -d' ' -f2 | tr -d '\r')
curl -s "$OS_AUTH_URL/auth/projects" -H "X-Auth-Token: $UNSCOPED" | python3 -m json.tool | grep -E '"name"'
```

Ici `-i` est voulu : on ne lit que l’en-tête `X-Subject-Token` (`cut` garde la valeur, `tr` retire le retour chariot de fin de ligne HTTP). Le jeton est ensuite présenté dans `X-Auth-Token` à `GET /v3/auth/projects`, qui renvoie les projets où le compte a au moins un rôle. C’est exactement ce que fait Horizon pour remplir la liste déroulante des projets après la connexion.

✅ **Observé :** `"name": "demo"` (le seul projet où `demo` a un rôle).

**Jeton de domaine** et **jeton système**, avec l’administrateur. D’abord, sur quoi `admin` a-t-il un rôle ?

```bash
openstack role assignment list --user admin --user-domain admin_domain --names
openstack role assignment list --system all --names
```

✅ **Observé :** `admin` a `admin` et `member` sur le projet `admin`, et `admin` sur le **domaine** `admin_domain` ; sur le **système**, seul `_charm-keystone-admin@Default` a un rôle. `admin` n’en a **aucun**.

```bash
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-domain-name admin_domain token issue -c domain_id -c expires
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-system-scope all token issue -c system -c expires
```

`env -u VAR` lance la commande **sans** la variable `VAR`, sans la retirer de ta session. `-c domain_id -c expires` limite l’affichage à ces colonnes.

✅ **Observé :** un jeton de domaine (`domain_id` de `admin_domain`) ; puis ⛔ `The request you have made requires authentication. (HTTP 401)` pour le jeton système, puisqu’`admin` n’a aucun rôle sur le système : **on ne peut pas obtenir une portée sur laquelle on n’a rien**. Sur un cloud Sunbeam, l’administrateur travaille donc avec des jetons de **projet** ou de **domaine**.

**Pourquoi `401` et pas `403` :** Keystone refuse d’**émettre** le jeton ; il n’y a donc pas d’identité authentifiée pour cette demande. `403` est réservé au cas où l’identité est établie mais l’action interdite (§ 1.6.3).

⚠ **Piège :** le client `openstack` refuse de mélanger les portées. Si `OS_PROJECT_NAME` est défini, `--os-domain-name` est ignoré ou provoque une erreur : d’où les `env -u …`. La fonction `os_as` du fichier `lab-env.sh` s’en charge.

| Portée | Ce qu’elle cible | Exemples d’usage |
|---|---|---|
| sans portée | rien | découvrir ses projets (`/v3/auth/projects`) |
| projet | les ressources d’un projet | créer une VM, un réseau |
| domaine | les identités d’un domaine | créer des utilisateurs et des projets du domaine |
| système | la plateforme entière | lister les hyperviseurs, gérer les services et le catalogue |

### 1.4.4 Valider un jeton (ce que font les services)

Chaque service qui reçoit un jeton le fait vérifier par Keystone (on le voit dans le traceur : `GET /v3/auth/tokens (validation du jeton)`). On reproduit l’appel :

```bash
TOKEN=$(grep -i "^X-Subject-Token" /tmp/token-headers.txt | cut -d' ' -f2 | tr -d '\r')
ADMIN_TOKEN=$(openstack token issue -f value -c id)
curl -s -o /dev/null -w "validation : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" \
  -H "X-Auth-Token: $ADMIN_TOKEN" -H "X-Subject-Token: $TOKEN"
```

**Les deux en-têtes :**

| En-tête | Contient | Rôle |
|---|---|---|
| `X-Auth-Token` | Le jeton de **celui qui demande** (ici `admin` ; dans la réalité, le compte de service de Nova, Neutron…) | Prouver qu’on a le droit de faire valider des jetons |
| `X-Subject-Token` | Le jeton **à vérifier** (celui de `demo`) | Le « sujet » de la question |

`-I` envoie une requête `HEAD` : on ne veut que le code de réponse, pas le contenu. `-o /dev/null` jette le corps, `-w "…%{http_code}"` affiche le code.

✅ **Observé :** `validation : 200`. Le jeton de `demo` est valide. Avec un `GET` au lieu d’un `HEAD`, Keystone renverrait en plus le contenu complet (utilisateur, rôles, catalogue) : c’est ce que reçoit réellement un service, et c’est avec ces rôles qu’il applique sa politique (§ 1.6).

### 1.4.5 Un jeton est un « porteur »

Quiconque possède le jeton agit comme son propriétaire, sans mot de passe :

```bash
curl -s "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $TOKEN" \
  | python3 -c "import sys,json; print([n['name'] for n in json.load(sys.stdin)['networks']])"
```

✅ **Observé :** `['demo-network', 'external-network']`, les réseaux visibles par `demo`, obtenus sans aucun mot de passe. `demo-network` appartient au projet `demo` ; `external-network` appartient au projet `admin` mais il est **partagé** (ou externe), donc visible de tous.

❓ **Question :** quelles conséquences pour la sécurité ? *Réponse : un jeton intercepté vaut un accès complet jusqu’à son expiration ; d’où HTTPS, une durée courte, et la révocation.*

### 1.4.6 Révoquer un jeton

```bash
openstack token revoke "$TOKEN"
curl -s -o /dev/null -w "validation après révocation : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" \
  -H "X-Auth-Token: $ADMIN_TOKEN" -H "X-Subject-Token: $TOKEN"
curl -s -o /dev/null -w "appel Neutron après révocation : %{http_code}\n" \
  "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $TOKEN"
```

✅ **Observé :** `validation après révocation : 404` : Keystone refuse aussitôt le jeton. Pour Neutron, ça dépend du moment : le 17 octobre, `appel Neutron après révocation : 401` ; le 18 octobre, `200`.

**Pourquoi `404` et non `401` :** l’appel de validation, lui, est authentifié (le jeton `admin` est bon). C’est le **sujet** de la question qui est rejeté : Keystone répond « ce jeton n’existe pas (ou plus) », `404 Not Found`. Neutron, lui, renvoie `401` à l’utilisateur : pour Neutron, l’appelant n’est plus authentifié.

**Pourquoi Neutron répond parfois encore `200` :** un service garde en **cache** les jetons qu’il vient de faire valider (bibliothèque `keystonemiddleware`), pour ne pas interroger Keystone à chaque appel. Un jeton que Neutron venait d’accepter (§ 1.4.5) est donc encore accepté juste après sa révocation. Mesuré le 18 octobre :

| Moment | Appel Neutron avec le jeton révoqué |
|---|---|
| Avant révocation | `200` |
| Juste après | `200` (cache) |
| 30 secondes après, et ensuite | `401` |

⚠ **Piège :** révoquer un jeton volé ne le coupe pas **instantanément** partout : il reste utilisable quelques secondes, le temps que les caches des services expirent.

### 1.4.7 Durée de vie et clés Fernet

```bash
python3 -c "import json; print(json.load(open('/tmp/token-body.json'))['token']['expires_at'])"
date -u +%Y-%m-%dT%H:%M:%S
$K exec keystone-0 -c keystone -- sh -c 'awk "/^\[/{p=(\$0==\"[token]\" || \$0==\"[fernet_tokens]\")} p && NF" /etc/keystone/keystone.conf; ls -l /etc/keystone/fernet-keys/'
```

Les deux premières lignes comparent l’expiration du jeton à l’heure actuelle, **toutes deux en UTC** (`date -u`) : sans `-u`, `date` afficherait l’heure de Paris et l’écart semblerait faux de 2 heures.

**La troisième commande, mot par mot :** `awk` lit le fichier ligne par ligne ; à chaque titre de section (`[…]`), il note si c’est `[token]` ou `[fernet_tokens]` ; il n’affiche que les lignes non vides (`NF`) de ces deux sections. `ls -l` liste les clés. (Un simple `grep -A6 "^\[token\]"` afficherait aussi le début des sections voisines.)

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

| Réglage | Signification |
|---|---|
| `expiration = 3600` | Un jeton vit **une heure** (3 600 secondes) |
| `allow_expired_window = 169200` | Pendant 47 heures (169 200 s) après expiration, un service peut encore faire accepter un jeton expiré pour **terminer** une opération longue déjà commencée (par exemple la copie d’une grosse image). Il faut pour cela le rôle `service` : un utilisateur, lui, ne peut pas réutiliser un jeton expiré |
| `max_active_keys = 4` | Quatre clés Fernet au plus. À chaque rotation, une nouvelle clé arrive et la plus ancienne disparaît : un jeton chiffré avec une clé supprimée devient illisible, donc invalide |
| Fichiers `0`, `7`, `8`, `9` | Les clés : `0` est la clé **en attente** (la prochaine primaire) ; la plus grande, `9`, est la clé **primaire**, qui chiffre les nouveaux jetons ; les autres servent encore à **déchiffrer** les jetons émis avant la dernière rotation |
| `-rw-------`, `keystone` | Lisible et modifiable par le seul compte `keystone` : qui lit ces fichiers peut fabriquer des jetons valides pour n’importe qui |
| Taille `44` | Une clé Fernet fait 32 octets aléatoires (16 pour signer, 16 pour chiffrer), écrits en base64 : 44 caractères |
| `lost+found` | Dossier créé par le système de fichiers ext4 : les clés sont sur un **volume persistant** monté par Kubernetes, et survivent donc au redémarrage du pod |

**Pourquoi une clé « en attente » :** Keystone tourne parfois en plusieurs exemplaires. La clé `0` est distribuée partout **avant** de devenir primaire : quand une instance commence à chiffrer avec elle, toutes les autres savent déjà la déchiffrer.

`provider = fernet` n’est pas écrit : c’est la valeur par défaut. Le charm Keystone ne propose pas d’option Juju pour la durée des jetons ni pour la rotation des clés (`juju config -m openstack keystone` n’en montre aucune) : ces réglages sont fixés par le charm.

❓ **Question :** un jeton Fernet ne contient pas le catalogue, alors que la réponse de `POST /auth/tokens` le contient. Pourquoi ? *Réponse : le jeton Fernet est un petit message chiffré (utilisateur, portée, méthodes, expiration, identifiant d’audit) ; Keystone reconstruit le reste (rôles, catalogue) à chaque validation. Il n’est stocké nulle part : c’est pourquoi la révocation passe par une liste d’événements de révocation (§ 1.8.4). Le § 1.8.5 ouvre un jeton pour le vérifier.*

---

## 1.5 Les sources d’identité

### 1.5.1 Identités locales (SQL)

```bash
openstack user show demo --domain users
$K exec keystone-0 -c keystone -- sh -c 'sed -n "/^\[identity\]/,/^\[/p" /etc/keystone/keystone.conf | grep -v "^\["'
```

**Comment lire `openstack user show` :**

| Champ | Signification |
|---|---|
| `domain_id` | Le domaine du compte : c’est lui qui détermine **où** le compte est stocké (SQL ou annuaire) |
| `default_project_id` | Le projet utilisé quand on s’authentifie sans portée (§ 1.4.3) |
| `enabled` | `True` : le compte peut s’authentifier. À `False`, plus aucun jeton n’est délivré et ceux en cours sont invalidés (§ 1.8.3) |
| `password_expires_at` | `None` : le mot de passe n’expire jamais (aucune politique, § 1.5.4) |
| `options` | Options de sécurité propres au compte (exemption de verrouillage, authentification à plusieurs facteurs, § 1.8.6) ; `{}` : aucune |

La seconde commande n’affiche **que** la section `[identity]`. ⚠ Ne pas utiliser `grep -A8 "^\[identity\]"` : sur le lab, les lignes suivantes sont celles de la section `[database]`, dont la chaîne de connexion contient **le mot de passe MySQL de Keystone** (constaté).

✅ **Observé :**

```text
driver = sql
default_domain_id = default
domain_specific_drivers_enabled = True
domain_config_dir = /etc/keystone/domains
```

**Comment le lire :**

| Ligne | Signification |
|---|---|
| `driver = sql` | Par défaut, les comptes sont dans la base MySQL de Keystone : nom, mot de passe haché, domaine |
| `default_domain_id = default` | Le domaine utilisé quand une requête n’en précise pas : `Default` (identifiant `default`). C’est pour cela que, sans `--user-domain`, le client cherche le compte dans `Default` |
| `domain_specific_drivers_enabled = True` | Keystone accepte qu’**un domaine** ait sa **propre** source d’identité (un annuaire LDAP, par exemple) |
| `domain_config_dir = /etc/keystone/domains` | Où sont les fichiers de ces sources : un fichier `keystone.<domaine>.conf` par domaine |

C’est ce qui permet de brancher l’annuaire d’un client sur son seul domaine, sans toucher aux comptes des autres domaines (module 11).

### 1.5.2 Comptes de service

```bash
openstack user list --domain service_domain
openstack role assignment list --project services --project-domain service_domain --names
```

✅ **Observé :** un compte par service, nommé `svc_<service>-<suffixe aléatoire>` (`svc_nova-F8OChi`, `svc_neutron-Jbci5R`…), plus `horizon`, `cinder-volume`, `openstack-hypervisor` et `svc_remote_…`, chacun avec **deux** rôles sur le projet `services` : `admin` et `service`. Ce sont eux qui valident les jetons des utilisateurs (§ 1.4.4) et qui s’appellent entre eux (nova-compute → Neutron).

**Pourquoi ces deux rôles :** `service` permet les opérations réservées aux services (faire accepter un jeton expiré en fin d’opération, § 1.4.7 ; certains appels internes de Nova vers Neutron ou Cinder). `admin` leur permet de voir les ressources de tous les projets, par exemple pour que Nova branche le port réseau d’une VM de n’importe quel projet. **Pourquoi un suffixe aléatoire :** le charm crée un compte neuf (et un mot de passe neuf) à chaque relation Juju, sans risquer de collision avec un compte existant du même nom.

### 1.5.3 Identités externes (fédération)

```bash
openstack identity provider list
openstack mapping list
```

✅ **Observé :** deux listes vides, tant que la fédération Keycloak n’est pas configurée (module 11). Keycloak tourne pourtant dans Lab-Services : **présence d’un fournisseur d’identité ne veut pas dire fédération active**.

**Ce que seraient ces deux objets :** un *identity provider* déclare à Keystone « je fais confiance aux identités émises par ce Keycloak » ; un *mapping* dit comment traduire ce que Keycloak envoie (nom, groupes) en utilisateur et groupes Keystone. Sans les deux, Keystone ignore Keycloak.

### 1.5.4 Politique de mots de passe

```bash
$K exec keystone-0 -c keystone -- sh -c 'grep -E "^\[security_compliance\]" -A15 /etc/keystone/keystone.conf'
```

✅ **Observé :** aucune ligne, et `command terminated with exit code 1` (`grep` n’a rien trouvé) : la section est **absente**, donc réglages par défaut : pas de verrouillage après échecs, pas d’expiration des mots de passe. À comparer avec les recommandations de l’ANSSI vues au module 11.

**Ce que réglerait cette section si elle existait :** `lockout_failure_attempts` (nombre d’échecs avant verrouillage), `lockout_duration` (durée du verrouillage), `password_expires_days` (durée de vie d’un mot de passe), `unique_last_password_count` (interdiction de réutiliser les N derniers), `password_regex` (complexité imposée). Le code `exit code 1` n’est pas une panne : c’est la façon dont `grep` signale « rien trouvé ».

### Simulation : un utilisateur change son mot de passe

```bash
openstack user create lab-pwtest --domain users --password "$LAB_PW"
openstack role add --user lab-pwtest --user-domain users --project demo --project-domain users member
os_as lab-pwtest users projet demo users -- user password set --original-password "$LAB_PW" --password "${LAB_PW}-2"
```

`os_as <compte> <domaine du compte> projet <projet> <domaine du projet> -- <commande>` exécute une commande `openstack` sous l’identité d’un autre compte, sans toucher aux variables de ta session.

⚠ **Observé :** avec le client `openstack` 7.5.0 du lab, cette commande **plante** : `Proxy.update_user() missing 1 required positional argument: 'user'`. C’est un défaut du client, pas de Keystone : le mot de passe n’est pas changé. On passe donc par l’**API**, ce que fait de toute façon le client :

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

✅ **Observé** (18 octobre 2026) : `changement : 204`, puis un jeton obtenu avec le nouveau mot de passe. Un utilisateur change son mot de passe avec **son propre** jeton, en prouvant qu’il connaît l’ancien. `204 No Content` : l’opération a réussi, et Keystone n’a rien à renvoyer.

**Effet de bord à connaître :** changer son mot de passe **révoque tous les jetons** déjà émis pour ce compte (Keystone enregistre un événement de révocation pour l’utilisateur). Le jeton `T` utilisé pour le changement ne fonctionne plus après.

⚠ **Pièges :**

- si `USER_ID` est vide (commande précédente en échec), la requête part vers `…/v3/users/password` et Keystone répond `500` (constaté dans son journal) ;
- `os_as` lit `LAB_PW` : d’où le `LAB_PW=… os_as` sur une seule ligne, pour ne pas modifier la variable de la session.

---

## 1.6 Les politiques d’accès

### 1.6.1 Où en est Secure RBAC sur ton lab (à faire en premier)

```bash
for pc in keystone-0/keystone:/etc/keystone/keystone.conf nova-0/nova-api:/etc/nova/nova.conf \
          neutron-0/neutron-server:/etc/neutron/neutron.conf glance-0/glance-api:/etc/glance/glance-api.conf \
          placement-0/placement-api:/etc/placement/placement.conf; do
  pod=${pc%%/*}; rest=${pc#*/}; c=${rest%%:*}; f=${rest#*:}
  echo "== $c"; $K exec "$pod" -c "$c" -- sh -c "grep -A6 '^\[oslo_policy\]' $f 2>/dev/null | grep -E 'enforce_scope|enforce_new_defaults|policy_file' || echo '  (valeurs par defaut)'"
done
```

**La boucle, ligne par ligne :** chaque élément a la forme `pod/conteneur:fichier`. Les expressions `${pc%%/*}`, `${pc#*/}`, `${rest%%:*}` et `${rest#*:}` découpent cette chaîne : `%%/*` garde ce qui précède le premier `/`, `#*/` ce qui le suit, et de même avec `:`. Pour chaque service, on cherche dans la section `[oslo_policy]` de son fichier les trois options qui règlent l’application des politiques ; si aucune n’est écrite, on affiche `(valeurs par defaut)`.

✅ **Observé :** les cinq services répondent `(valeurs par defaut)` : aucun ne fixe ces options dans son fichier.

« Valeurs par défaut » : pour les lire, génère la configuration de référence de la bibliothèque de politiques :

```bash
$K exec keystone-0 -c keystone -- oslo-config-generator --namespace oslo.policy 2>/dev/null | grep -B2 -A2 -E "^#enforce_(scope|new_defaults)"
```

`oslo-config-generator` écrit un fichier de configuration modèle, où chaque option apparaît en commentaire (`#`) avec sa valeur par défaut. `--namespace oslo.policy` limite la sortie à la bibliothèque de politiques.

✅ **Observé :** `#enforce_scope = false` et `#enforce_new_defaults = false`.

| Option | Ce qu’elle active |
|---|---|
| `enforce_scope` | Refuser une action si la **portée** du jeton ne convient pas (par exemple, un jeton de projet pour une action de niveau système) |
| `enforce_new_defaults` | Utiliser les **nouvelles** règles (`reader`, `member`, `manager`, portées) au lieu des anciennes (`admin` ou propriétaire) |
| `policy_file` | Un fichier de règles locales qui remplacent celles du code |

⚠ Ce sont les défauts de la **bibliothèque** ; un service peut les surcharger dans son code. La preuve se lit dans les règles (§ 1.6.2) et dans les essais des TP 2 à 4. Note le résultat :

| Service | `enforce_scope` | `enforce_new_defaults` |
|---|---|---|
| Keystone | | |
| Nova | | |
| Neutron | | |
| Glance | | |
| Placement | | |

| Si… | Alors |
|---|---|
| `enforce_scope = True` et `enforce_new_defaults = True` | Secure RBAC complet : `reader`, `member`, `manager`, `admin` et les portées s’appliquent comme dans le support |
| `enforce_new_defaults = True` seul | Les nouveaux rôles s’appliquent, mais une portée inadaptée n’est pas refusée |
| les deux à `False` | Anciennes règles : `admin` sur n’importe quel projet = administrateur de tout le cloud (« admin quelque part, admin partout ») |

### 1.6.2 Lire une règle

```bash
$K exec keystone-0 -c keystone -- oslopolicy-policy-generator --namespace keystone 2>/dev/null \
  | grep -E '"identity:(list_users|create_user|list_projects|create_project|create_grant)"'
```

`oslopolicy-policy-generator` affiche les règles **effectivement appliquées** par le service (code + options + éventuel fichier local), une ligne par action : `"action": "règle"`.

✅ **Observé sur le lab :**

```text
"identity:create_grant": "(rule:admin_required) or ((role:admin and domain_id:%(target.user.domain_id)s and domain_id:%(target.project.domain_id)s) or …"
"identity:list_projects": "(rule:admin_required) or (role:reader and system_scope:all) or (role:reader and domain_id:%(target.domain_id)s)"
"identity:create_project": "rule:admin_required"
"identity:list_users": "(rule:admin_required) or (role:reader and system_scope:all) or (role:reader and domain_id:%(target.domain_id)s)"
"identity:create_user": "rule:admin_required"
```

**Mini-grammaire des règles :**

| Élément | Se lit | Est vrai si… |
|---|---|---|
| `role:reader` | « a le rôle reader » | `reader` figure dans les rôles du jeton (impliqués compris) |
| `system_scope:all` | « jeton de portée système » | le jeton est un jeton système |
| `domain_id:%(target.domain_id)s` | « même domaine que la cible » | le domaine **du jeton** est égal au domaine de l’**objet visé**. `%(…)s` est remplacé, au moment de la vérification, par l’attribut de l’objet : `target.domain_id` est le domaine de l’utilisateur ou du projet que l’on veut lister |
| `project_id:%(project_id)s` | « même projet que la ressource » | le projet du jeton est le propriétaire de la ressource |
| `rule:admin_required` | « applique la règle nommée admin_required » | la règle `admin_required` est vraie (ici : `role:admin`, sans condition de portée) |
| `and`, `or`, parenthèses | logique habituelle | — |

**Comment le lire :**

| Règle | Qui peut |
|---|---|
| `list_users`, `list_projects` | Un `admin` (`rule:admin_required`), **ou** un `reader` sur le système, **ou** un `reader` sur le domaine visé |
| `create_user`, `create_project` | **Seulement** un `admin` |
| `create_grant` (donner un rôle) | Un `admin`, éventuellement limité au domaine de l’utilisateur et de la cible |

Deux conclusions, essentielles pour la suite :

1. **`rule:admin_required` est en tête de chaque règle**, et il ne regarde pas la portée : un rôle `admin`, **n’importe où**, suffit. C’est la marque des anciennes règles (`enforce_new_defaults = false`), et l’origine du « admin quelque part, admin partout » (TP 2, § 2.3).
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

Lister les hyperviseurs : réservé à l’administrateur (`context_is_admin` : le jeton porte le rôle `admin`) ; créer une VM : membre du projet ou administrateur ; créer un réseau : administrateur, ou `member` **du projet** ; le rendre partagé : administrateur seulement.

**Pourquoi `create_network:shared` :** Neutron vérifie l’action (`create_network`), **puis** chaque attribut sensible de la demande. Une règle `action:attribut` s’applique seulement si la demande contient cet attribut (ici `shared=True`). Un même appel peut donc être accepté sans l’option et refusé avec.

❓ **Question :** pourquoi `create_network:shared` a-t-il une règle distincte de `create_network` ? *Réponse : un réseau partagé est visible par tous les projets ; c’est une action d’administration, alors que créer un réseau privé est un droit de membre.*

### 1.6.3 Expliquer un refus

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

Chaque message **nomme la règle** refusée : l’apprenant la relie à celle lue en 1.6.2.

**Deux détails à faire remarquer :**

- Nova refuse `os-hypervisors:list-detail`, pas `os-hypervisors:list` lue au § 1.6.2 : `openstack hypervisor list` appelle `GET /os-hypervisors/detail`, qui a sa propre règle (de même valeur). Pour vérifier : refaire le `grep` du § 1.6.2 avec `os-hypervisors:list-detail`.
- Neutron cite **deux** règles reliées par `and` : la création n’est permise que si l’action **et** l’attribut `shared` sont permis. `demo` passe la première (il est `member` de son projet), pas la seconde.

| Code | Signification |
|---|---|
| `401 Unauthorized` | Keystone ne sait pas qui tu es (jeton absent, expiré, révoqué, mauvais mot de passe) |
| `403 Forbidden` | Keystone sait qui tu es, mais la **politique** du service refuse cette action à ton rôle sur cette portée |

---

## 1.7 Exploitation : relier un refus aux journaux

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

**Comment lire ces deux lignes :**

| Morceau | Signification |
|---|---|
| `req-40a5efb0-…` | Identifiant unique que le service attribue à chaque requête et renvoie au client dans l’en-tête `X-Openstack-Request-Id` |
| `[None req-… …]` | Le contexte de la ligne de journal : `None` est l’identifiant de requête global (fixé quand un service en appelle un autre, absent ici), puis l’identifiant local, puis utilisateur et projet |
| `ERROR … ForbiddenAction` | La décision de la politique, avec la règle en cause |
| `"GET /openstack-keystone/v3/users HTTP/1.1" 403 132` | La ligne d’accès Apache : méthode, chemin, code renvoyé, taille de la réponse en octets |

L’identifiant de requête relie le refus vu par l’utilisateur à la ligne du serveur. C’est l’information à demander à un utilisateur qui signale un refus : sans elle, retrouver sa requête dans les journaux est un jeu de devinettes.

---

## 1.8 Démos complémentaires (pas encore rejouées)

> Ces démos prolongent le TP. Elles n’ont **pas encore été rejouées sur le lab** : les résultats sont notés 🔲 **Attendu**. À la première exécution, remplacer chaque 🔲 par le ✅ observé, et corriger la commande si besoin.

### 1.8.1 Identifiants d’application : un accès limité pour un script

**Scénario :** une chaîne d’intégration continue doit lister les réseaux du projet `demo`. On ne veut ni lui donner le mot de passe de `demo`, ni qu’elle puisse créer ou supprimer quoi que ce soit.

```bash
source ~/demo-openrc
openstack application credential create lab-ci --role reader \
  --expiration 2026-12-31T00:00:00 --description "CI : lecture seule" -f json | tee /tmp/appcred.json
AC_ID=$(python3 -c "import json; print(json.load(open('/tmp/appcred.json'))['id'])")
AC_SECRET=$(python3 -c "import json; print(json.load(open('/tmp/appcred.json'))['secret'])")
```

🔲 **Attendu :** un objet avec `id`, `secret`, `roles` (`reader`), `project_id` (celui de `demo`), `expires_at`, `unrestricted: False`. Le **secret n’est affiché qu’une fois** : Keystone n’en garde qu’une empreinte.

S’authentifier avec, à la place du mot de passe :

```bash
env -i PATH="$PATH" HOME="$HOME" OS_AUTH_URL="$OS_AUTH_URL" OS_IDENTITY_API_VERSION=3 \
  OS_AUTH_TYPE=v3applicationcredential OS_APPLICATION_CREDENTIAL_ID="$AC_ID" OS_APPLICATION_CREDENTIAL_SECRET="$AC_SECRET" \
  sh -c 'openstack token issue -c expires -c project_id; openstack network list -c Name; openstack network create lab-ci-net'
```

`env -i` lance la commande avec un environnement **vide** : aucune variable `OS_*` de `demo` ne fuit, seules celles de l’identifiant d’application sont présentes.

🔲 **Attendu :** un jeton sur le projet `demo` (l’identifiant est lié à un projet, pas besoin de portée) ; la liste des réseaux s’affiche ; puis ⛔ `403` sur `network create` : le jeton ne porte que `reader`, alors que `create_network` exige `member` (§ 1.6.2).

**Ce qu’il faut retenir :** un identifiant d’application porte **une partie** des rôles de son propriétaire, sur **un** projet, avec une date de fin, et se révoque seul, sans changer le mot de passe de personne. C’est la façon recommandée de donner un accès à un script, à Terraform ou à une CI.

Le restreindre encore, à un seul appel d’API (*access rules*) :

```bash
openstack application credential create lab-ci-strict --role reader \
  --access-rules '[{"service": "network", "method": "GET", "path": "/v2.0/networks"}]' -f value -c id -c secret
```

🔲 **Attendu :** avec cet identifiant, `openstack network list` fonctionne ; `openstack server list` est refusé, même en lecture, car l’appel à Nova n’est pas dans la liste.

Nettoyage :

```bash
openstack application credential delete lab-ci lab-ci-strict
source ~/admin-openrc
```

### 1.8.2 Groupes : donner un rôle à une équipe plutôt qu’à des personnes

```bash
openstack group create lab-equipe --domain users
openstack user create lab-alice --domain users --password "$LAB_PW"
openstack group add user --group-domain users --user-domain users lab-equipe lab-alice
openstack role add --group lab-equipe --group-domain users --project demo --project-domain users member
openstack role assignment list --user lab-alice --user-domain users --names
openstack role assignment list --user lab-alice --user-domain users --names --effective
os_as lab-alice users projet demo users -- token issue -c project_id
```

🔲 **Attendu :** la première liste est **vide** (aucun rôle affecté directement à `lab-alice`) ; la liste `--effective` montre `member` et `reader` sur `demo`, hérités du groupe ; `lab-alice` obtient un jeton sur `demo`.

```bash
openstack group remove user --group-domain users --user-domain users lab-equipe lab-alice
os_as lab-alice users projet demo users -- token issue -c project_id
```

🔲 **Attendu :** ⛔ `401` : sortir du groupe retire le rôle, donc la portée.

**Ce qu’il faut retenir :** on affecte les rôles aux groupes ; arrivées et départs se gèrent en ajoutant ou en retirant des personnes du groupe. Avec la fédération (module 11), ce sont les groupes de Keycloak qui alimentent ces groupes.

Nettoyage : `openstack user delete lab-alice --domain users ; openstack group delete lab-equipe --domain users`.

### 1.8.3 Désactiver un compte : effet immédiat sur ses jetons

```bash
openstack user create lab-bob --domain users --password "$LAB_PW"
openstack role add --user lab-bob --user-domain users --project demo --project-domain users member
TB=$(os_as lab-bob users projet demo users -- token issue -f value -c id)
ADMIN_TOKEN=$(openstack token issue -f value -c id)
openstack user set --disable lab-bob --domain users
curl -s -o /dev/null -w "validation après désactivation : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" \
  -H "X-Auth-Token: $ADMIN_TOKEN" -H "X-Subject-Token: $TB"
os_as lab-bob users projet demo users -- token issue
```

🔲 **Attendu :** `validation après désactivation : 404` : le jeton émis **avant** la désactivation est refusé ; puis ⛔ `401` sur la demande d’un nouveau jeton (`The account is disabled`, visible dans le journal de Keystone).

**Ce qu’il faut retenir :** désactiver un compte coupe à la fois les nouveaux jetons et les jetons en cours (aux caches des services près, § 1.4.6). C’est le geste d’urgence quand un compte est compromis, avant toute investigation. On peut faire de même avec un projet (`openstack project set --disable`).

Nettoyage : `openstack user delete lab-bob --domain users`.

### 1.8.4 Voir les événements de révocation

Les jetons Fernet ne sont stockés nulle part : pour en refuser un, Keystone garde une liste d’**événements** (« tous les jetons de tel utilisateur émis avant telle heure », « le jeton d’identifiant d’audit X »). Après les § 1.4.6, 1.5.4 et 1.8.3, cette liste n’est pas vide :

```bash
ADMIN_TOKEN=$(openstack token issue -f value -c id)
curl -s "$OS_AUTH_URL/OS-REVOKE/events" -H "X-Auth-Token: $ADMIN_TOKEN" | python3 -m json.tool | head -40
```

🔲 **Attendu :** des événements avec `audit_id` (révocation d’**un** jeton, § 1.4.6 ; à comparer avec l’`audit_ids` lu au § 1.4.2), et d’autres avec `user_id` et `issued_before` (révocation de **tous** les jetons d’un compte : changement de mot de passe, § 1.5.4 ; désactivation, § 1.8.3).

**Ce qu’il faut retenir :** à chaque validation, Keystone déchiffre le jeton, puis le compare à cette liste. Les événements plus anciens que la durée de vie maximale d’un jeton sont purgés, puisque ces jetons sont expirés de toute façon.

### 1.8.5 Ouvrir un jeton Fernet

**But :** constater qu’un jeton Fernet ne contient ni rôles ni catalogue. ⚠ Cette démo lit les clés Fernet : à faire sur le lab uniquement, jamais en production.

```bash
TOKEN=$(openstack token issue -f value -c id)
cat > /tmp/fernet-open.py <<'EOF'
import os, sys, msgpack
from cryptography.fernet import Fernet, MultiFernet
d = '/etc/keystone/fernet-keys/'
keys = [Fernet(open(d + f, 'rb').read().strip()) for f in sorted((f for f in os.listdir(d) if f.isdigit()), key=int, reverse=True)]
tok = sys.argv[1] + '=' * (-len(sys.argv[1]) % 4)   # Keystone retire le remplissage base64
print(msgpack.unpackb(MultiFernet(keys).decrypt(tok.encode()), raw=False))
EOF
$K exec -i keystone-0 -c keystone -- python3 - "$TOKEN" < /tmp/fernet-open.py
```

**La commande :** le script lit les clés, de la plus grande à la plus petite ; il essaie chacune (`MultiFernet`) jusqu’à ce que l’une déchiffre le jeton, puis décode le contenu (format `msgpack`). `-i` transmet le script par l’entrée standard au `python3` du pod, qui a déjà `cryptography` et `msgpack` (ce sont des dépendances de Keystone).

🔲 **Attendu :** une liste de 6 ou 7 valeurs : un numéro de format (2 pour un jeton de projet), l’identifiant de l’utilisateur, un entier qui code les méthodes (`password`), l’identifiant du projet, l’expiration (secondes depuis 1970), l’identifiant d’audit. **Aucun rôle, aucun catalogue.** Si le script échoue sur `Permission denied`, le conteneur n’exécute pas les commandes sous le compte `keystone` : noter le cas et passer.

**Ce qu’il faut retenir :** le jeton dit seulement **qui**, **sur quoi**, **comment** et **jusqu’à quand**. Les rôles sont recalculés à chaque validation : retirer un rôle à quelqu’un prend effet sur ses jetons en cours, sans révocation. Et quiconque possède les clés peut fabriquer des jetons : elles se protègent comme un mot de passe administrateur.

### 1.8.6 Authentification à plusieurs facteurs (TOTP)

**D’abord vérifier que Keystone accepte la méthode `totp` :**

```bash
$K exec keystone-0 -c keystone -- sh -c 'sed -n "/^\[auth\]/,/^\[/p" /etc/keystone/keystone.conf | grep -v "^\["'
```

🔲 **Attendu :** si une ligne `methods = …` est présente et ne contient pas `totp`, ou si la section est absente (méthodes par défaut : `external, password, token, oauth1, mapped, application_credential`), la méthode n’est pas activée : la démo s’arrête à ce constat, qui est déjà une réponse (« le cloud n’offre pas de second facteur natif ; on le fera par la fédération Keycloak, module 11 »).

Si `totp` est présent :

```bash
openstack user create lab-mfa --domain users --password "$LAB_PW"
openstack role add --user lab-mfa --user-domain users --project demo --project-domain users member
SECRET=$(python3 -c "import base64,os; print(base64.b32encode(os.urandom(20)).decode())")
openstack credential create --type totp $(openstack user show lab-mfa --domain users -f value -c id) "$SECRET"
openstack user set lab-mfa --domain users --enable-multi-factor-auth --multi-factor-auth-rule password,totp
os_as lab-mfa users projet demo users -- token issue
```

🔲 **Attendu :** ⛔ `401` avec le message `Insufficient auth methods received` : le mot de passe seul ne suffit plus. Pour réussir, il faut présenter dans la même demande le mot de passe **et** le code à 6 chiffres calculé à partir de `SECRET` (celui qu’afficherait une application d’authentification sur téléphone).

Nettoyage : `openstack user delete lab-mfa --domain users`.

### Récapitulatif du § 1.8

| Démo | Notion | Durée |
|---|---|---|
| 1.8.1 | Accès limité pour un script, sans mot de passe | 20 min |
| 1.8.2 | Rôles par groupe, `--effective` | 10 min |
| 1.8.3 | Désactivation d’urgence | 10 min |
| 1.8.4 | Événements de révocation | 10 min |
| 1.8.5 | Contenu réel d’un jeton Fernet | 15 min |
| 1.8.6 | Second facteur natif (ou constat de son absence) | 10 à 20 min |

---

## Nettoyage

```bash
rm -f /tmp/auth-projet.json /tmp/auth-defaut.json /tmp/auth-sans-portee.json /tmp/token-body.json /tmp/token-headers.txt \
      /tmp/appcred.json /tmp/fernet-open.py
openstack user delete lab-pwtest --domain users 2>/dev/null
openstack user delete lab-alice lab-bob lab-mfa --domain users 2>/dev/null
openstack group delete lab-equipe --domain users 2>/dev/null
```

`2>/dev/null` masque les erreurs « introuvable » si l’objet a déjà été supprimé.

## Pour aller plus loin

- Lancer le traceur (`2-trace/PAS-A-PAS.md`) pendant le § 1.4 : chaque `POST /auth/tokens` et chaque validation `GET /auth/tokens` apparaît en direct.
- Mesurer la taille d’un jeton : `openstack token issue -f value -c id | wc -c`, puis comparer avec un jeton de domaine : la taille change peu, car le catalogue n’est jamais dans le jeton.
