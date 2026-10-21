# TP 2 : les domaines

> Statut : **rejoué sur le lab le 18 octobre 2026** (Keystone 2024.1, client `openstack` 7.5.0). Les résultats « Observé » sont ceux de ce jour. Sur ce lab, Keystone réserve la création de comptes, de projets et d’affectations au rôle `admin` (TP 1, § 1.6.2). Deux commandes ont dû être contournées par l’API à cause du client (`implied role create` sur un rôle de domaine, et l’affichage des refus de Bruno). Voir les conventions dans [README.md](README.md).

**Module du support :** 9, les domaines dans OpenStack.
**Durée :** 2 h.
**Objectifs :** créer des espaces d’identité indépendants, constater ce qui est unique par domaine et ce qui est global, déléguer l’administration d’un domaine à un gestionnaire, et vérifier qu’il ne peut pas en sortir.

**Prérequis :** TP 1 fait (en particulier le relevé de Secure RBAC, § 1.6.1). Session préparée :

```bash
source ~/labs-iam/lab-env.sh
```

---

## 2.1 Créer les domaines du fil rouge

```bash
openstack domain create acme --description "Acme : SI interne"
openstack domain create partenaire --description "Partenaire externe, totalement separe"
openstack domain list
```

✅ **Attendu :** six domaines : les quatre de Sunbeam, plus `acme` et `partenaire`, tous `Enabled = True`.

❓ **Question :** à quoi sert un domaine qui n’a encore aucun utilisateur ? *Réponse : c’est un espace de noms et une frontière d’administration ; il accueillera ses utilisateurs, groupes, projets, et éventuellement sa propre source d’identité.*

---

## 2.2 Des espaces d’identité indépendants

### Scénario : deux Bruno

Acme et le partenaire ont chacun un collaborateur nommé Bruno, deux personnes différentes.

```bash
openstack user create bruno --domain acme --password "$LAB_PW" --description "Bruno, Acme"
openstack user create bruno --domain partenaire --password "$LAB_PW" --description "Bruno, partenaire"
openstack user list --domain acme
openstack user list --domain partenaire
```

✅ **Attendu :** les deux créations réussissent : le nom n’est unique **qu’au sein d’un domaine**. Les deux comptes ont deux identifiants différents.

```bash
openstack user show bruno
```

⛔ **Observé** (18 octobre 2026) : `No User found for bruno`. Le client cherche un compte nommé `bruno` dans le domaine **de ton jeton** (`admin_domain`), et n’en trouve pas. Un nom seul ne désigne pas un compte : selon le contexte, il ne trouve rien, ou il en trouve plusieurs (`More than one user exists with the name 'bruno'`).

```bash
openstack user show bruno --domain acme -c id -c domain_id -c description
openstack user show bruno --domain partenaire -c id -c domain_id -c description
```

✅ **Attendu :** chaque commande désigne un compte précis.

⚠ **Piège :** dans les scripts, désigner un compte par **identifiant**, ou par **nom + domaine**, jamais par nom seul. La même règle vaut pour les projets et les groupes.

### Simulation : un même nom de projet dans deux domaines

```bash
openstack project create app --domain acme
openstack project create app --domain partenaire
openstack project create app --domain acme
```

✅ **Observé** (18 octobre 2026) : les deux premières réussissent. ⛔ La troisième est refusée : `Conflict occurred attempting to store project - it is not permitted to have two projects with either the same name or same id in the same domain: name is app … (HTTP 409)`.

```bash
openstack project delete app --domain acme
openstack project delete app --domain partenaire
```

### Ce qui est global, ce qui appartient à un domaine

```bash
openstack role list
openstack role create --domain acme acme-facturation
openstack role list --domain acme
```

✅ **Attendu :** les rôles standards (`reader`, `member`, `manager`, `admin`) sont **globaux** : ils existent pour tous les domaines. Le rôle `acme-facturation` n’existe que dans `acme`.

| Global (toute la plateforme) | Propre à un domaine |
|---|---|
| Rôles standards, services, catalogue, régions, quotas par défaut | Utilisateurs, groupes, projets, rôles propres au domaine, source d’identité (si configurée par domaine) |

❓ **Question :** un rôle propre au domaine sert à quoi, s’il n’est pas utilisé par les politiques des services ? *Réponse : un rôle propre au domaine n’est jamais vu par les services : il doit **impliquer** un rôle global (ex. `acme-facturation` implique `reader`) pour donner un droit. Il sert à nommer un profil métier propre au domaine.*

⚠ **Piège du client :** `openstack implied role create acme-facturation --implied-role reader` échoue avec le client 7.5.0 : `Could not find role: None. (HTTP 404)`, même en donnant l’identifiant du rôle. Le client ne sait pas retrouver un rôle **propre à un domaine** et envoie `PUT /v3/roles/None/implies/…` (constaté le 18 octobre 2026 dans le journal de Keystone). On passe donc par l’API :

```bash
FACT=$(openstack role show acme-facturation --domain acme -f value -c id)
READER=$(openstack role show reader -f value -c id)
T=$(openstack token issue -f value -c id)
curl -s -o /dev/null -w "implication : %{http_code}\n" -X PUT "$OS_AUTH_URL/roles/$FACT/implies/$READER" -H "X-Auth-Token: $T"
openstack implied role list
```

✅ **Observé :** `implication : 201`, puis une ligne `acme-facturation → reader` dans `implied role list`, à côté de la chaîne `admin → manager → member → reader`.

---

## 2.3 L’administration globale

L’équipe plateforme (`admin`, projet `admin` du domaine `admin_domain`) voit et administre tous les domaines.

```bash
openstack project list --long
for d in acme partenaire; do openstack user list --domain "$d" --long; done
```

✅ **Observé** (18 octobre 2026) : l’administrateur voit les comptes des deux domaines (un `bruno` dans chacun). ⚠ Ne pas écrire `openstack user list --long | grep acme` : sans `--domain`, la liste ne contient que les comptes du domaine du jeton (`admin_domain`), et le `grep` ne trouve rien (TP 1, § 1.2).

### Le piège du rôle `admin`

❓ **Question :** pour qu’Acme gère ses comptes, on envisage de donner à Bruno le rôle `admin` sur un projet d’Acme. Que se passe-t-il ?

```bash
openstack project create acme-si --domain acme --description "Racine de l'arbre d'Acme"
openstack role add --user bruno --user-domain acme --project acme-si --project-domain acme admin
os_as bruno acme projet acme-si acme -- user list --domain partenaire
os_as bruno acme projet acme-si acme -- project list --domain admin_domain
openstack role remove --user bruno --user-domain acme --project acme-si --project-domain acme admin
```

✅ **Observé** (18 octobre 2026) : les deux commandes de Bruno **réussissent** : il voit le `bruno` du partenaire et le projet `admin` de la plateforme. Les règles `identity:list_users` et `identity:list_projects` commencent par `rule:admin_required`, qui accepte un rôle `admin` **quelle que soit sa cible** : Bruno, `admin` d’un simple projet d’Acme, voit les comptes du partenaire et les projets de la plateforme. C’est la démonstration de « admin quelque part, admin partout ». On retire tout de suite ce rôle.

⚠ **Piège :** ne jamais donner `admin` à un client ou à un gestionnaire de domaine. Le rôle prévu pour déléguer est `manager` sur le domaine (§ 2.4) ; on va voir ce qu’il permet réellement sur ce lab.

---

## 2.4 L’administration déléguée

### Scénario : Bruno devient gestionnaire du domaine Acme

```bash
openstack role list -f value -c Name | grep -x manager || echo "ATTENTION : role manager absent"
openstack role add --user bruno --user-domain acme --domain acme manager
openstack role assignment list --user bruno --user-domain acme --names
```

✅ **Attendu :** `bruno@acme` → `manager` sur le domaine `acme`. Le rôle `manager` existe sur le lab (TP 1, § 1.2), dans la chaîne `admin` → `manager` → `member` → `reader`.

Bruno obtient un **jeton de domaine** :

```bash
os_as bruno acme domaine acme -- token issue -c domain_id -c expires
```

✅ **Attendu :** un jeton avec le `domain_id` d’`acme` : Bruno a un rôle sur ce domaine, il peut donc en obtenir la portée.

### Ce qu’un gestionnaire de domaine devrait pouvoir faire

Dans le modèle Secure RBAC (support, module 12), un gestionnaire de domaine crée les comptes et les projets de son domaine, et leur donne `reader`, `member` ou `manager`. On le vérifie :

```bash
os_as bruno acme domaine acme -- user list --domain acme
os_as bruno acme domaine acme -- user create chloe --domain acme --password "$LAB_PW" --description "Chloe, developpeuse"
os_as bruno acme domaine acme -- project create acme-dev --domain acme --parent acme-si
os_as bruno acme domaine acme -- role assignment list --domain acme --names
```

✅ **Observé** (18 octobre 2026) :

| Commande | Résultat | Règle en cause |
|---|---|---|
| `user list --domain acme` | ✅ réussit (Bruno ne voit que lui-même, seul compte d’Acme à ce stade) | `list_users` accepte `reader` sur le domaine visé ; `manager` implique `reader` |
| `user create chloe` | ⛔ `403 … identity:create_user` | `identity:create_user` = `rule:admin_required` : **seulement** `admin` |
| `project create acme-dev` | ⛔ `403 … identity:create_project` | `identity:create_project` = `rule:admin_required` |
| `role assignment list --domain acme` | ✅ réussit : `manager bruno@acme` sur `acme` | La lecture des affectations de son domaine est permise |

**Conclusion à faire tirer aux apprenants :** sur ce Keystone, aucune règle ne mentionne `manager` (TP 1, § 1.6.2). Un gestionnaire de domaine y est, en pratique, un **lecteur** de son domaine. La délégation de la gestion des identités n’est pas possible telle quelle :

| Option | Effet sur ce lab |
|---|---|
| `manager` sur le domaine | Lecture seule du domaine : pas de délégation |
| `admin` sur le domaine ou sur un projet | Tout est permis, **partout** (§ 2.3) : délégation sans plafond, inacceptable |
| Politique personnalisée de Keystone (règles pour `manager`) | Possible, mais hors du périmètre de Sunbeam (le charm gère la configuration de Keystone) |

La gestion des comptes reste donc à la **plateforme**. C’est elle qui crée maintenant les comptes et le projet dont les TP suivants ont besoin :

```bash
for u in chloe emma david; do
  openstack user show "$u" --domain acme >/dev/null 2>&1 || openstack user create "$u" --domain acme --password "$LAB_PW"
done
openstack user set chloe --domain acme --description "Chloe, developpeuse"
openstack user set emma --domain acme --description "Emma, exploitation"
openstack user set david --domain acme --description "David, auditeur"
openstack project show acme-dev --domain acme >/dev/null 2>&1 || openstack project create acme-dev --domain acme --parent acme-si
openstack role add --user chloe --user-domain acme --project acme-dev --project-domain acme member
openstack role assignment list --domain acme --names
openstack role assignment list --project acme-dev --project-domain acme --names
```

Les `show … || create` évitent une erreur si un compte ou le projet existe déjà, par exemple si la création par Bruno a finalement réussi sur ton lab.

✅ **Observé** (18 octobre 2026) : les trois comptes dans `acme`, le projet `acme-dev` sous `acme-si` (`parent_id` = l’identifiant d’`acme-si`), et `chloe@acme` → `member` sur `acme-dev`. `role assignment list --domain acme` ne montre que `manager bruno@acme` : l’affectation de Chloé porte sur un **projet**, pas sur le domaine ; elle apparaît avec `--project acme-dev`.

### Ce que Bruno ne doit pas pouvoir faire

```bash
os_as bruno acme domaine acme -- user list --domain partenaire
os_as bruno acme domaine acme -- user create intrus --domain partenaire --password "$LAB_PW"
os_as bruno acme domaine acme -- role add --user chloe --user-domain acme --project acme-dev --project-domain acme admin
os_as bruno acme domaine acme -- role add --user bruno --user-domain acme --domain acme admin
os_as bruno acme domaine acme -- domain create acme2
os_as bruno acme domaine acme -- hypervisor list
```

⛔ **Observé** (18 octobre 2026) : tout est refusé, mais **le client `openstack` 7.5.0 ne l’affiche pas toujours clairement** :

| Tentative | Ce qu’affiche le client | Ce qu’a fait Keystone |
|---|---|---|
| Lister les comptes du partenaire | `'NoneType' object has no attribute 'id'` | Bruno n’a pas le droit de lire le domaine `partenaire` (`identity:get_domain` refusé) : le client ne trouve pas son identifiant et plante |
| Créer un compte chez le partenaire | `No Domain found for partenaire` | Même cause |
| Donner `admin` à Chloé, ou à lui-même | **rien**, et code de sortie `0` | Refus `403 identity:create_grant` (journal de Keystone). **Aucune affectation créée** |
| Créer un domaine | `You are not authorized to perform the requested action: identity:create_domain. (HTTP 403)` | Refus |
| Lister les hyperviseurs | `403 … Policy doesn't allow os_compute_api:os-hypervisors:list-detail to be performed.` | Refus de Nova |

⚠ **Piège du client : un `role add` refusé ne dit rien.** Bruno ne peut pas lire les rôles : le client ne traduit pas le nom `admin` en identifiant, envoie la demande quand même, reçoit `404` ou `403`, et se tait. On croirait que l’affectation a réussi. **Toujours vérifier** :

```bash
openstack role assignment list --role admin --names | grep -E "acme|partenaire" || echo "aucun admin chez Acme ou le partenaire"
```

✅ **Observé :** `aucun admin chez Acme ou le partenaire`.

Pour **voir** les refus, on appelle l’API avec le jeton de Bruno :

```bash
TB=$(os_as bruno acme domaine acme -- token issue -f value -c id)
ADMIN_ROLE=$(openstack role show admin -f value -c id)
CHLOE=$(openstack user show chloe --domain acme -f value -c id)
DEV=$(openstack project show acme-dev --domain acme -f value -c id)
PART=$(openstack domain show partenaire -f value -c id)
curl -s -w "\n%{http_code}\n" -X PUT "$OS_AUTH_URL/projects/$DEV/users/$CHLOE/roles/$ADMIN_ROLE" -H "X-Auth-Token: $TB"
curl -s "$OS_AUTH_URL/users?domain_id=$PART" -H "X-Auth-Token: $TB"; echo
```

✅ **Observé :**

- `{"error": {"code": 403, … "You are not authorized to perform the requested action: identity:create_grant." …}}` puis `403` : Bruno ne peut pas fabriquer d’administrateur ;
- `{"users": [], …}` : pour les comptes du partenaire, Keystone ne refuse pas, il renvoie une liste **vide**. Il filtre sur le domaine de Bruno : les deux domaines restent étanches.

| Tentative | Pourquoi c’est refusé |
|---|---|
| Lister les comptes du partenaire | `list_users` n’accepte `reader` que sur **le domaine visé** : `partenaire` n’est pas le sien |
| Créer un compte chez le partenaire | `create_user` exige `admin` |
| Donner `admin` à Chloé ou à lui-même | `create_grant` exige `admin` : il ne peut pas fabriquer d’administrateur |
| Créer un domaine | Réservé à `admin` |
| Lister les hyperviseurs | `os-hypervisors:list` = `rule:context_is_admin` |

Ces refus sont ceux qu’on souhaite. Le problème de ce lab est ailleurs : Bruno est aussi refusé pour ce qu’il **devrait** pouvoir faire (paragraphe précédent).

❓ **Question :** pourquoi est-il essentiel que Bruno ne puisse pas se donner `admin` ? *Réponse : sinon la délégation n’a pas de plafond ; un gestionnaire compromis deviendrait administrateur de toute la plateforme (§ 2.3).*

### Le partenaire, par symétrie

```bash
openstack role add --user bruno --user-domain partenaire --domain partenaire manager
openstack project create partenaire-app --domain partenaire
os_as bruno partenaire domaine partenaire -- project list --domain partenaire
os_as bruno partenaire domaine partenaire -- user list --domain acme
```

Le projet `partenaire-app` est créé par la plateforme, pour la raison vue plus haut.

✅ **Observé** (18 octobre 2026) : le Bruno du partenaire **voit** son domaine (`partenaire-app`). ⛔ Sur la liste des comptes d’Acme, le client plante (`'NoneType' object has no attribute 'id'`) : comme plus haut, Bruno ne peut pas lire le domaine `acme`. Deux gestionnaires homonymes, deux périmètres de lecture étanches.

---

## 2.5 Répartir l’administration : global ou délégué

Exercice en groupe : pour chaque tâche, les apprenants indiquent qui la fait, puis le vérifient sur le lab quand c’est possible.

| Tâche | Plateforme (admin) | Gestionnaire de domaine : modèle Secure RBAC | Gestionnaire de domaine : **ce lab** | Vérification |
|---|---|---|---|---|
| Créer le domaine `acme` | ✅ | ⛔ | ⛔ | § 2.4 |
| Lister les comptes d’`acme` | ✅ | ✅ | ✅ | § 2.4 |
| Créer un utilisateur dans `acme` | ✅ | ✅ | ⛔ | § 2.4 |
| Créer un projet dans `acme` | ✅ | ✅ | ⛔ | § 2.4 |
| Donner `member` sur un projet d’Acme | ✅ | ✅ | ⛔ | § 2.4 |
| Donner `admin` | ✅ | ⛔ | ⛔ | § 2.4 |
| Fixer les quotas d’un projet d’Acme | ✅ | ⛔ | ⛔ | TP 3 |
| Créer un réseau partagé, un flavor public | ✅ | ⛔ | ⛔ | TP 4 |
| Ajouter un hyperviseur, modifier le catalogue | ✅ | ⛔ | ⛔ | — |
| Brancher l’annuaire d’Acme (LDAP, fédération) | ✅ | ⛔ | ⛔ | module 11 |

---

## 2.6 Cycle de vie d’un domaine

### Simulation : désactiver un domaine

```bash
openstack domain set --disable partenaire
os_as bruno partenaire domaine partenaire -- token issue
openstack domain set --enable partenaire
os_as bruno partenaire domaine partenaire -- token issue -c expires
```

⛔ **Observé** (18 octobre 2026) pendant que le domaine est désactivé : `The request you have made requires authentication. (HTTP 401)` : aucun de ses comptes ne peut s’authentifier. ✅ Après réactivation, le jeton est de nouveau délivré.

### Simulation : supprimer un domaine (sur un domaine jetable)

```bash
openstack domain create lab-ephemere
openstack user create jetable --domain lab-ephemere --password "$LAB_PW"
openstack project create jetable --domain lab-ephemere
openstack domain delete lab-ephemere
```

⛔ **Observé** (18 octobre 2026) : `Cannot delete a domain that is enabled, please disable it first. (HTTP 403)`.

```bash
JETABLE=$(openstack user show jetable --domain lab-ephemere -f value -c id)
openstack domain set --disable lab-ephemere
openstack domain delete lab-ephemere
openstack user show "$JETABLE"
```

✅ **Attendu :** suppression réussie, puis `No User found for …` : **les utilisateurs, groupes et projets du domaine disparaissent avec lui**. On garde l’identifiant du compte **avant** la suppression : après, son domaine n’existe plus, on ne peut plus le chercher par nom. (Un `openstack user list | grep jetable` ne prouverait rien : sans `--domain`, la liste ne contient que les comptes d’`admin_domain`.)

⚠ **Piège :** les ressources (VM, volumes, réseaux) des projets supprimés ne sont **pas** supprimées : elles deviennent orphelines. Avant de supprimer un domaine, vider ses projets.

---

## 2.7 Les domaines dans Horizon

Depuis Windows, ouvre `http://cloud.lab.test/openstack-horizon` et connecte-toi avec :

| Champ | Valeur |
|---|---|
| Domaine | `acme` |
| Utilisateur | `bruno` |
| Mot de passe | `LAB_PW` |

La page de connexion de Horizon a bien un champ **Domaine** (constaté le 18 octobre 2026 : champs `domain`, `username`, `password`) : Horizon est configuré pour plusieurs domaines.

❓ **Question :** Bruno voit-il le menu **Identité** ? Quels domaines voit-il ? *Attendu : il voit le menu Identité restreint à son domaine (selon la version d’Horizon et les politiques). Comparer avec une connexion de `demo` (domaine `users`).*

---

## État à la fin du TP

| Objet | État |
|---|---|
| Domaines | `acme`, `partenaire` |
| Projets | `acme-si`, `acme-dev` (enfant d’`acme-si`) ; `partenaire-app` |
| Utilisateurs | `bruno`, `chloe`, `emma`, `david` dans `acme` (les trois derniers créés par la plateforme, § 2.4) ; `bruno` dans `partenaire` |
| Affectations | `bruno@acme` manager d’`acme` ; `chloe` member d’`acme-dev` ; `bruno@partenaire` manager de `partenaire` |
| Rôle propre | `acme-facturation` (implique `reader`) |

Conserve cet état pour le TP 3. Pour tout effacer : `bash ~/labs-iam/nettoyage.sh`.
