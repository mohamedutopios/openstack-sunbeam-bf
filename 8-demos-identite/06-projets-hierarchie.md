# Démo 06 : arbre de projets et rôles hérités

**Module 10 · 20 min.**
**Crée :** l'arbre d'Orion, les comptes `sarah`, `marc`, `nadia`, les groupes `equipe-portail`, `exploitation`, `audit`, et un réseau commun partagé depuis `socle`.

Le projet est le conteneur étanche des ressources. L'arbre de projets sert à **ranger** et à **faire descendre des droits** ; il ne transmet jamais de ressources.

```bash
source ~/demos-identite/demo-env.sh
```

## 1. Construire l'arbre

**Pourquoi.** Modèle recommandé par le support : un nœud par environnement, une feuille par application. Les nœuds ne portent pas de ressources, seulement des rôles hérités.

```bash
openstack project create prod --domain orion --description "Nœud production"
openstack project create horsprod --domain orion --description "Nœud hors production"
openstack project create prod-portail  --domain orion --parent prod     --tag env:prod --tag app:portail
openstack project create prod-paiement --domain orion --parent prod     --tag env:prod --tag app:paiement
openstack project create rec-portail   --domain orion --parent horsprod --tag env:rec  --tag app:portail
openstack project create dev-portail   --domain orion --parent horsprod --tag env:dev  --tag app:portail
openstack project show prod-portail --domain orion -c name -c parent_id
openstack project list --domain orion --tags env:prod -c Name
```

✅ `parent_id` de `prod-portail` = l'identifiant de `prod`. Le filtre par étiquette rend les deux projets de production.

```text
orion
├── socle
├── prod      → prod-portail, prod-paiement
└── horsprod  → rec-portail, dev-portail
```

## 2. Les règles de l'arbre

```bash
openstack project create intrus --domain prestataires --parent prod
openstack project delete prod --domain orion
```

⛔ `… specifies a parent in a different domain (HTTP 400)`. ⛔ `Cannot delete the project … since it is not a leaf in the hierarchy.`

**À dire.**
- Un arbre ne traverse pas les domaines ; on supprime par les feuilles.
- Le parent est **immuable** : pas de commande pour déplacer un projet. On choisit le modèle avant de créer.
- Les noms restent uniques dans le domaine : `prod/portail` et `rec/portail` impossibles, d'où les préfixes.

## 3. Des groupes, et des rôles hérités

**Pourquoi.** Des droits posés sur des groupes survivent aux arrivées et aux départs ; posés en hérité sur un nœud, ils couvrent aussi les projets futurs.

```bash
for u in sarah marc nadia; do openstack user create $u --domain orion --password "$DEMO_PW"; done
for g in equipe-portail exploitation audit; do openstack group create $g --domain orion; done
openstack group add user --group-domain orion --user-domain orion equipe-portail sarah
openstack group add user --group-domain orion --user-domain orion exploitation marc
openstack group add user --group-domain orion --user-domain orion audit nadia

G="--group-domain orion --project-domain orion"
openstack role add --group exploitation   $G --project prod --inherited member     # l'exploitation agit en production
openstack role add --group equipe-portail $G --project prod --inherited reader     # les développeurs lisent la production
openstack role add --group equipe-portail $G --project dev-portail member          # et agissent hors production
openstack role add --group equipe-portail $G --project rec-portail member
openstack role add --group audit --group-domain orion --domain orion --inherited reader   # l'audit lit tout Orion
```

❓ Marc a-t-il des droits sur le nœud `prod` lui-même ?

```bash
openstack role assignment list --names --effective --user marc --user-domain orion
en_tant_que marc orion projet prod orion -- token issue
```

✅ Marc a `member` (et `reader`) sur `prod-portail` et `prod-paiement`, **pas** sur `prod`. ⛔ `HTTP 401` sur `prod`.

**À dire.**

| Affectation | S'applique à |
|---|---|
| `--project P` | P seul |
| `--project P --inherited` | les descendants de P, **pas** P |
| `--domain D --inherited` | tous les projets du domaine |

- Règle simple : lecture en hérité, large ; écriture en direct, ciblée.
- Un héritage ne se « coupe » pas pour un seul enfant : si une feuille doit y échapper, elle n'est pas dans la bonne branche.

## 4. Vérifier la cloison

```bash
en_tant_que sarah orion projet dev-portail orion -- network create dev-portail-net -f value -c name
en_tant_que sarah orion projet prod-portail orion -- network list -c Name
en_tant_que sarah orion projet prod-portail orion -- network create intrus
en_tant_que nadia orion projet dev-portail orion -- network list -c Name
en_tant_que sarah orion projet rec-portail orion -- network list -c Name
```

| Essai | Attendu |
|---|---|
| Sarah crée un réseau en dev | ✅ `dev-portail-net` |
| Sarah lit la production | ✅ (reader hérité) |
| Sarah crée en production | ⛔ `403 … create_network is disallowed by policy` |
| Nadia lit le dev | ✅ elle voit `dev-portail-net` |
| Sarah, depuis `rec-portail` | ✅ `external-network` seulement : `dev-portail-net` n'y est pas |

**À dire.**
- Personne n'écrit des deux côtés de la frontière production / hors production.
- Même personne, autre projet : autre jeton, autres ressources. Le projet est étanche, y compris entre projets frères.

## 5. Un nouveau projet hérite tout seul

```bash
openstack project create prod-api --domain orion --parent prod --tag env:prod --tag app:api
openstack role assignment list --names --effective --user marc --user-domain orion | grep prod-api
```

✅ Marc a déjà `member` sur `prod-api` ; Nadia et l'équipe portail l'ont aussi en lecture.

**À dire.** C'est l'intérêt de l'héritage, et son risque : savoir ce qui descend avant de créer une branche.

## 6. L'arbre ne partage pas les ressources

**Pourquoi.** Le socle porte un réseau commun. Les projets enfants ne le voient pas d'eux-mêmes : partager est une décision explicite, ressource par ressource, vers un projet précis.

```bash
SOCLE=$(projet_id socle orion); DEV=$(projet_id dev-portail orion)
openstack network create --project "$SOCLE" socle-commun -f value -c id
openstack subnet create --project "$SOCLE" --network socle-commun --subnet-range 10.50.0.0/24 socle-commun-v4 -f value -c id
en_tant_que sarah orion projet dev-portail orion -- network list -c Name
openstack network rbac create --type network --action access_as_shared --target-project "$DEV" socle-commun -c id -f value
en_tant_que sarah orion projet dev-portail orion -- network list -c Name
en_tant_que sarah orion projet rec-portail orion -- network list -c Name
```

`network rbac create` ouvre **un** réseau à **un** projet ; `--share` l'aurait ouvert à tout le cloud.

✅ Avant la règle, `socle-commun` est invisible depuis `dev-portail`. Après, il apparaît dans `dev-portail`, et toujours pas dans `rec-portail`. *(Partage par règle RBAC : non vérifié sur ce lab.)*

**À dire.**
- L'arbre transmet des **rôles**, jamais des ressources. Image : partage avec acceptation ; réseau : règle RBAC ; volume : transfert.
- Un réseau partagé relie des projets : à filtrer par groupes de sécurité, sinon il annule le cloisonnement.
