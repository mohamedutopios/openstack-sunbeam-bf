# TP 3 : projets, hiérarchie et quotas

> Statut : **rejoué sur le lab le 18 octobre 2026** (Keystone 2024.1, client `openstack` 7.5.0). Les résultats « Observé » sont ceux de ce jour. Correction principale : les commandes de quotas désignent le projet par son identifiant, car `quota show` et `quota set` n’acceptent pas `--domain` (§ 3.4). Voir les conventions dans [README.md](README.md).

**Module du support :** 10, projets, hiérarchie et quotas.
**Durée :** 2 h 30.
**Objectifs :** constater l’étanchéité d’un projet, construire un arbre de projets, utiliser les rôles hérités, fixer des quotas et les voir bloquer une demande, puis choisir un modèle d’organisation pour un SI cloisonné.

**Prérequis :** état de fin du TP 2 (domaine `acme`, projets `acme-si` et `acme-dev`, comptes `bruno`, `chloe`, `emma`, `david`, `chloe` membre d’`acme-dev`). Sur ce lab, les comptes et `acme-dev` ont été créés par la plateforme (TP 2, § 2.4). Toutes les actions d’administration de ce TP (projets, affectations, quotas) se font donc avec le compte `admin`. Session préparée :

```bash
source ~/labs-iam/lab-env.sh
```

---

## 3.1 Le projet, conteneur étanche

### Scénario : Chloé travaille dans `acme-dev`

```bash
os_as chloe acme projet acme-dev acme -- network create acme-dev-net
os_as chloe acme projet acme-dev acme -- security group create acme-dev-web
os_as chloe acme projet acme-dev acme -- network list
```

✅ **Observé** (18 octobre 2026) : le réseau `acme-dev-net` et le groupe `acme-dev-web` sont créés dans `acme-dev`. La liste montre `external-network` (le réseau externe de la plateforme) et `acme-dev-net`, mais pas `demo-network`.

Emma n’a encore aucun rôle sur `acme-dev` :

```bash
os_as emma acme projet acme-dev acme -- network list
```

⛔ **Observé :** `The request you have made requires authentication. (HTTP 401)`. Emma ne peut même pas obtenir de jeton sur un projet où elle n’a aucun rôle.

❓ **Question :** qu’est-ce qui est étanche entre deux projets, et qu’est-ce qui est partagé ? *Réponse : étanches : VM, volumes, réseaux privés, groupes de sécurité, clés, quotas. Partagés : images publiques, flavors publics, réseaux marqués partagés ou externes, et l’infrastructure physique (hyperviseurs).*

### Étiquettes et propriétés

```bash
openstack project set acme-dev --domain acme --tag env:dev --tag app:portail
openstack project show acme-dev --domain acme -c tags
openstack project list --domain acme --tags env:dev
```

✅ **Observé :** `tags ['app:portail', 'env:dev']`, et le filtre `--tags env:dev` retrouve `acme-dev`. Les étiquettes sont stockées sur le projet. Usage typique : refacturation, inventaire, automatisation.

---

## 3.2 La hiérarchie de projets

### Scénario : construire l’arbre d’Acme

```bash
openstack project create acme-prod --domain acme --parent acme-si --tag env:prod
openstack project create acme-recette --domain acme --parent acme-si --tag env:recette
openstack project show acme-si --domain acme --children -c name -c subtree
openstack project show acme-prod --domain acme --parents -c name -c parent_id -c parents
openstack project list --domain acme --long
```

✅ **Observé** (18 octobre 2026) : l’arbre suivant.

```text
acme (domaine)
└── acme-si
    ├── acme-dev
    ├── acme-prod
    └── acme-recette
```

**Comment le lire dans les sorties**, qui ne donnent que des identifiants :

| Commande | Ce qu’elle affiche |
|---|---|
| `project show acme-si --children` | `subtree` : les identifiants des trois enfants (`{'7d3b…': None, '9b17…': None, 'd54c…': None}`) |
| `project show acme-prod --parents` | `parent_id` : l’identifiant d’`acme-si` ; `parents` : `{<acme-si>: {<acme>: None}}`, la chaîne jusqu’au **domaine** `acme`, racine de l’arbre |
| `project list --domain acme --long` | Les quatre projets, avec leur `Domain ID`. ⚠ Pas de colonne `Parent ID` dans ce client : le parent se lit avec `openstack project show <projet> --domain acme -c parent_id` |

### Les règles de l’arbre

```bash
openstack project create lab-hors-domaine --domain partenaire --parent acme-si
openstack project delete acme-si --domain acme
```

⛔ **Observé** (18 octobre 2026), refus pour les deux :

| Tentative | Message | Règle |
|---|---|---|
| Parent dans un autre domaine | `Cannot create project, since it specifies its domain_id …, but specifies a parent in a different domain (…). (HTTP 400)` | Un arbre ne traverse pas les domaines |
| Supprimer un parent qui a des enfants | `Cannot delete the project … since it is not a leaf in the hierarchy. Use the cascade option if you want to delete a whole subtree.` | Il faut supprimer (ou déplacer) les enfants d’abord |

❓ **Question :** quelle est la profondeur maximale d’un arbre ? *Réponse : réglage `max_project_tree_depth` de Keystone, 5 par défaut. Sur le lab, `sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- grep max_project_tree_depth /etc/keystone/keystone.conf` ne trouve rien (`command terminated with exit code 1`) : le réglage n’est pas écrit, la valeur par défaut s’applique.*

---

## 3.3 Les rôles hérités

### Scénario : David audite tout Acme

David doit **lire** tous les projets d’Acme, y compris ceux qui seront créés plus tard, sans rien pouvoir modifier.

```bash
openstack role add --user david --user-domain acme --project acme-si --project-domain acme --inherited reader
openstack role assignment list --user david --user-domain acme --names
openstack role assignment list --user david --user-domain acme --names --effective
```

✅ **Observé** (18 octobre 2026) :

- liste simple : une affectation `reader` sur `acme-si`, marquée `Inherited = True` ;
- liste effective : `reader` sur `acme-dev`, `acme-prod` et `acme-recette`, **mais pas sur `acme-si` lui-même**. Un rôle hérité s’applique au sous-arbre, pas au projet qui le porte.

```bash
os_as david acme projet acme-dev acme -- network list
os_as david acme projet acme-dev acme -- network create acme-intrus
os_as david acme projet acme-si acme -- network list
```

✅ **Observé :** la lecture réussit sur `acme-dev` (`external-network`, `acme-dev-net`). ⛔ La création est refusée : `ForbiddenException: 403, rule:create_network is disallowed by policy`. Sur ce lab, la règle de Neutron est `create_network: (rule:admin_only) or (role:member and project_id:%(project_id)s)` (TP 1, § 1.6.2) ; elle exige `member`, et `reader` n’implique pas `member`. ⛔ Sur `acme-si` : `(HTTP 401)`, aucun rôle effectif sur ce projet.

### Simulation : un nouveau projet hérite automatiquement

```bash
openstack project create acme-dev-api --domain acme --parent acme-dev
openstack role assignment list --user david --user-domain acme --names --effective | grep acme-dev-api
os_as david acme projet acme-dev-api acme -- server list
```

Le projet est créé par la plateforme : sur ce lab, le gestionnaire de domaine ne peut pas créer de projet (TP 2, § 2.4).

✅ **Observé :** une ligne `reader | david@acme | | acme-dev-api@acme | … | True`, et `server list` répond (liste vide) : David a déjà `reader` sur `acme-dev-api`, sans qu’on l’ait ajouté. L’héritage s’évalue à chaque jeton.

### Scénario : Emma, exploitante

Emma travaille en production et doit pouvoir **lire** tout le reste d’Acme.

```bash
openstack role add --user emma --user-domain acme --project acme-prod --project-domain acme member
openstack role add --user emma --user-domain acme --domain acme --inherited reader
openstack role assignment list --user emma --user-domain acme --names --effective
```

✅ **Observé :** `member` sur `acme-prod`, `reader` sur **tous** les projets du domaine `acme` (y compris `acme-si`, cette fois : l’héritage depuis le **domaine** couvre tous ses projets).

| Affectation | Où s’applique-t-elle |
|---|---|
| `--project P` | P seulement |
| `--project P --inherited` | les descendants de P, pas P |
| `--domain D` | le domaine D lui-même (jeton de domaine), aucun projet |
| `--domain D --inherited` | tous les projets du domaine D |

### Ce que la hiérarchie ne fait pas

❓ **Question :** Chloé a créé `acme-dev-net` dans `acme-dev`. Peut-elle l’utiliser depuis `acme-dev-api`, projet enfant ?

```bash
openstack role add --user chloe --user-domain acme --project acme-dev-api --project-domain acme member
os_as chloe acme projet acme-dev-api acme -- network list
```

✅ **Observé :** seulement `external-network` : `acme-dev-net` **n’apparaît pas**. La hiérarchie transmet des **rôles**, jamais des **ressources** : un réseau, une VM, un volume restent dans leur projet. Pour partager, il faut un partage explicite (RBAC de Neutron, module 13).

---

## 3.4 Les quotas

⚠ **Piège du client, à connaître avant tout :** `openstack quota show` et `openstack quota set` n’acceptent **pas** l’option `--domain` (client 7.5.0 : `error: unrecognized arguments: --domain acme`, constaté le 18 octobre 2026). Et un nom de projet seul est ambigu dès que deux domaines ont un projet du même nom. On désigne donc le projet par son **identifiant**, lu une fois pour toutes :

```bash
DEV=$(openstack project show acme-dev --domain acme -f value -c id)
REC=$(openstack project show acme-recette --domain acme -f value -c id)
echo "$DEV $REC"
```

### 3.4.1 Lire

```bash
openstack quota show --default
openstack quota show "$DEV"
openstack quota show --usage "$DEV"
sudo k8s kubectl -n openstack exec nova-0 -c nova-api -- grep -A3 "^\[quota\]" /etc/nova/nova.conf
openstack registered limit list
```

✅ **Observé** (18 octobre 2026) :

| Commande | Résultat |
|---|---|
| `quota show --default` | Les défauts du cloud : `instances 10`, `cores 20`, `ram 51200` (Mo), `networks 100`, `subnets 100`, `ports 500`, `routers 10`, `floating-ips 50`, `secgroups 10`, `volumes 10`, `gigabytes 1000`… |
| `quota show "$DEV"` | Les mêmes valeurs : rien n’a encore été fixé pour `acme-dev` |
| `quota show --usage "$DEV"` | Colonnes `Limit`, `In Use`, `Reserved` ; on y voit le réseau (`networks`) et les groupes de sécurité (`secgroups`) de Chloé |
| `grep … nova.conf` | Rien (`command terminated with exit code 1`) : Nova n’a pas de section `[quota]`, il garde ses défauts |
| `registered limit list` | Vide : le lab utilise les **quotas classiques** de chaque service, pas les limites unifiées de Keystone |

⚠ Dans la vue `--usage`, les lignes de Neutron (`networks`, `ports`…) affichent un dictionnaire `{'limit': …, 'reserved': …, 'in_use': …}` dans la colonne `Limit` : c’est un défaut d’affichage du client, les vraies valeurs sont dedans.

### 3.4.2 Fixer

```bash
openstack quota set "$DEV" --instances 2 --cores 2 --ram 2048
openstack quota set "$DEV" --networks 1 --subnets 2 --ports 10 --routers 1 --floating-ips 1 --secgroups 3
openstack quota set "$DEV" --volumes 2 --gigabytes 20
openstack quota show "$DEV" -f value | grep -E '^(instances|cores|ram|networks|subnets|ports|routers|floating-ips|secgroups|volumes|gigabytes) '
```

✅ **Observé** (18 octobre 2026) : `cores 2`, `instances 2`, `ram 2048`, `networks 1`, `subnets 2`, `ports 10`, `routers 1`, `floating-ips 1`, `secgroups 3`, `volumes 2`, `gigabytes 20`. Une seule commande `quota set` règle les trois services (Nova, Neutron, Cinder) : le client répartit les options.

### 3.4.3 Simulation : le quota bloque

**Réseaux :** Chloé a déjà `acme-dev-net`, le quota est à 1.

```bash
os_as chloe acme projet acme-dev acme -- network create acme-dev-net2
```

⛔ **Observé :** `Error while executing command: ConflictException: 409, Quota exceeded for resources: ['network'].`

**Instances :** on bloque toute instance en recette, sans rien consommer.

```bash
openstack quota set "$REC" --instances 0
openstack role add --user emma --user-domain acme --project acme-recette --project-domain acme member
os_as emma acme projet acme-recette acme -- server create lab-quota --flavor m1.tiny --image ubuntu --nic none
os_as emma acme projet acme-recette acme -- server list
```

⛔ **Observé :** `ForbiddenException: 403: … Quota exceeded for instances: Requested 1, but already used 0 of 0 instances`. Le refus a lieu **avant** toute réservation : `server list` est vide, rien n’a été créé.

⚠ **Constaté en rejouant ce TP :** si le `quota set` a échoué (par exemple avec `--domain`), le quota reste celui par défaut, et la VM **est créée** (`BUILD`). Toujours vérifier la valeur avec `quota show` avant de tester le blocage. Si une VM `lab-quota` a été créée par erreur : `os_as emma acme projet acme-recette acme -- server delete lab-quota --wait`.

**Le gestionnaire ne fixe pas les quotas :**

```bash
os_as bruno acme domaine acme -- quota set "$DEV" --instances 50
openstack quota show "$DEV" -f value | grep -E '^instances '
```

⛔ **Observé :** `Programming error choosing an endpoint.`, puis `instances 2` : rien n’a changé. Bruno n’a qu’un jeton de **domaine** ; les quotas se règlent par projet, auprès de Nova, Neutron et Cinder, et son jeton ne lui permet même pas de les atteindre. Sur ce lab, Bruno n’est de toute façon qu’un lecteur de son domaine (TP 2, § 2.4) : les quotas restent à la plateforme, qui protège la capacité commune.

### 3.4.4 Les quotas par défaut

❓ **Question :** quel est le réglage le plus important pour protéger la plateforme ? *Réponse : les quotas **par défaut**, car ils s’appliquent à tout nouveau projet tant qu’on ne les a pas fixés explicitement.*

```bash
openstack quota show --default -f value | grep -E '^(instances|cores|ram) '
```

✅ **Observé :** `cores 20`, `instances 10`, `ram 51200`. (Le tableau de `quota show` n’a que deux colonnes, `Resource` et `Limit` : `-c instances` ne fonctionne pas, d’où le `grep`.)

⚠ **Piège :** `openstack quota set --class default …` change le défaut **de tous les projets** du cloud qui n’ont pas de valeur propre. À faire en connaissance de cause ; ne pas le lancer en TP sans revenir ensuite à la valeur initiale.

---

## 3.5 Organiser un SI cloisonné

### Trois modèles

**Modèle A, par environnement** (celui d’Acme) :

```text
acme
└── acme-si
    ├── acme-prod
    ├── acme-recette
    └── acme-dev
```

**Modèle B, par application puis environnement :**

```text
acme
├── acme-portail
│   ├── acme-portail-prod
│   └── acme-portail-dev
└── acme-paie
    ├── acme-paie-prod
    └── acme-paie-dev
```

**Modèle C, par entité (direction, filiale), un domaine chacune :**

```text
acme-rh   (domaine)        acme-finance (domaine)
└── rh-prod, rh-dev        └── fin-prod, fin-dev
```

| Critère | A : environnement | B : application | C : domaine par entité |
|---|---|---|---|
| Séparation production / hors production | Forte | Forte | Forte |
| Séparation entre applications | Faible (toutes dans `acme-prod`) | Forte | Forte |
| Nombre de projets | Faible | Élevé | Élevé |
| Auditeur transversal | Un rôle hérité sur `acme-si` | Un rôle hérité sur le domaine | Un rôle par domaine |
| Délégation | Un gestionnaire pour tout Acme | Un gestionnaire par application possible (rôles sur sous-arbre) | Un gestionnaire par entité |
| Source d’identité distincte | Non | Non | Oui, possible par domaine |

### Exercice de conception

Énoncé à donner aux apprenants : « Acme héberge le portail client (exposé sur Internet, données personnelles) et la paie (données sensibles, accès restreint à 3 personnes). L’équipe de développement est commune. L’auditeur de sécurité doit tout lire. La production ne doit jamais être modifiable par les développeurs. »

1. Choisir un modèle et dessiner l’arbre.
2. Écrire la liste des affectations (qui, quel rôle, où, hérité ou non).
3. Fixer les quotas de chaque projet.
4. L’implémenter sur le lab dans le domaine `acme`, avec des noms préfixés `acme-`.

Corrigé indicatif : modèle B ; `acme-portail` et `acme-paie` sous le domaine ; développeurs `member` sur `acme-portail-dev` et `acme-paie-dev` ; exploitants `member` sur les deux `-prod` ; auditeur `reader` hérité sur le domaine ; quotas faibles en `-dev`, dimensionnés en `-prod`. La paie pourrait justifier un domaine propre (modèle C) si ses comptes viennent d’une autre source d’identité.

---

## État à la fin du TP

| Objet | État |
|---|---|
| Arbre | `acme-si` → `acme-dev` (→ `acme-dev-api`), `acme-prod`, `acme-recette` |
| David | `reader` hérité sur `acme-si` |
| Emma | `member` sur `acme-prod` et `acme-recette`, `reader` hérité sur le domaine `acme` |
| Chloé | `member` sur `acme-dev` et `acme-dev-api` ; réseau `acme-dev-net`, groupe `acme-dev-web` |
| Quotas | `acme-dev` réduits ; `acme-recette` : 0 instance |

Conserve cet état pour le TP 4. Avant de nettoyer, supprime le réseau et le groupe de Chloé :

```bash
os_as chloe acme projet acme-dev acme -- network delete acme-dev-net
os_as chloe acme projet acme-dev acme -- security group delete acme-dev-web
```
