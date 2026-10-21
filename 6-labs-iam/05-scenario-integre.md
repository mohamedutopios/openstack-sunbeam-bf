# TP 5 : scénario intégré, mettre en service et auditer un SI cloisonné

> Statut : **rejoué sur le lab le 18 octobre 2026** (Keystone 2024.1, client `openstack` 7.5.0), mise en œuvre, audit et les sept incidents. Corrections : les quotas désignent les projets par leur identifiant (`quota set` n’accepte pas `--domain`) ; les refus des lignes 1 et 2 de l’audit ne s’affichent pas comme un `403` (client). Voir les conventions dans [README.md](README.md).

**Modules du support :** 8 à 12.
**Durée :** 3 h (1 h 30 de mise en œuvre, 30 min d’audit, 1 h d’incidents).
**Objectifs :** mettre en service un nouveau client de bout en bout, en respectant le moindre privilège, puis diagnostiquer des incidents d’identité et d’autorisation.

Ce TP peut se jouer **seul**, sans les TP 1 à 4 : il crée son propre domaine, `lab-globex`. Il sert d’évaluation de fin de parcours.

```bash
source ~/labs-iam/lab-env.sh
```

---

## Partie A : le cahier des charges

À distribuer aux apprenants.

> **Globex** rejoint la plateforme OpenStack. Elle veut :
>
> 1. un espace d’identité à elle, administré par **Gaëlle**, sa responsable informatique, **sans** que Gaëlle puisse agir sur un autre client ou sur la plateforme ;
> 2. deux environnements, **production** et **développement**, regroupés sous une racine commune ;
> 3. **Hugo** (développeur) travaille en développement uniquement ; **Inès** (exploitation) travaille en production et lit le développement ; **Jules** (auditeur) lit tout, sans rien pouvoir modifier ;
> 4. les droits sont donnés **par groupe**, jamais directement à une personne sur un projet ;
> 5. le développement est limité à **2 instances, 2 vCPU, 4 Go de RAM, 2 réseaux** ; la production à **5 instances, 10 vCPU, 20 Go, 3 réseaux** ;
> 6. un script de supervision **lit** les instances de production, sans mot de passe, avec un accès qui expire dans 30 jours.

| Compte | Domaine | Groupe |
|---|---|---|
| `gaelle` | `lab-globex` | — (gestionnaire du domaine) |
| `hugo` | `lab-globex` | `globex-dev` |
| `ines` | `lab-globex` | `globex-ops` |
| `jules` | `lab-globex` | `globex-audit` |

**Livrable demandé avant de toucher au lab :** l’arbre des projets, et le tableau des affectations (acteur, rôle, cible, hérité ou non). Le corrigé est en partie B.

---

## Partie B : la mise en œuvre, rôle par rôle

Chaque phase indique **qui** agit. Respecter cet ordre est une partie de l’exercice : la plateforme ne fait que ce que le gestionnaire ne peut pas faire.

### Phase 1 : la plateforme crée le cadre (compte `admin`)

```bash
openstack domain create lab-globex --description "Client Globex"
openstack user create gaelle --domain lab-globex --password "$LAB_PW" --description "Gaelle, responsable informatique Globex"
openstack role add --user gaelle --user-domain lab-globex --domain lab-globex manager
openstack role assignment list --domain lab-globex --names
```

✅ **Observé :** `gaelle@lab-globex` → `manager` sur le domaine `lab-globex`. Dans le modèle Secure RBAC, c’est la **seule** affectation que la plateforme fait sur Globex ; sur ce lab, elle devra aussi faire la phase 2 à la place de Gaëlle.

### Phase 2 : la gestionnaire organise son domaine (compte `gaelle`, jeton de domaine)

Dans le modèle Secure RBAC, c’est Gaëlle qui fait cette phase. **Sur ce lab, elle ne le peut pas** : Keystone réserve la création de projets, de comptes et d’affectations au rôle `admin` (et sans doute celle des groupes, règle non lue) (TP 1, § 1.6.2 ; TP 2, § 2.4). On le constate d’abord sur une commande :

```bash
os_as gaelle lab-globex domaine lab-globex -- project create globex-si --domain lab-globex
```

⛔ **Observé** (18 octobre 2026) : `You are not authorized to perform the requested action: identity:create_project. (HTTP 403)`. On fait alors faire la phase par la plateforme, **avec les mêmes commandes** : la fonction `G` désigne qui agit. Choisir **une** des deux lignes :

```bash
G() { openstack "$@"; }                                          # ce lab : la plateforme agit pour Gaelle
# G() { os_as gaelle lab-globex domaine lab-globex -- "$@"; }   # Keystone avec regles pour manager
```

Puis :

```bash
G project create globex-si --domain lab-globex --description "Racine Globex"
G project create globex-prod --domain lab-globex --parent globex-si --tag env:prod
G project create globex-dev --domain lab-globex --parent globex-si --tag env:dev

for u in hugo ines jules; do G user create "$u" --domain lab-globex --password "$LAB_PW"; done
for g in globex-dev globex-ops globex-audit; do G group create "$g" --domain lab-globex; done
G group add user --group-domain lab-globex --user-domain lab-globex globex-dev hugo
G group add user --group-domain lab-globex --user-domain lab-globex globex-ops ines
G group add user --group-domain lab-globex --user-domain lab-globex globex-audit jules

G role add --group globex-dev --group-domain lab-globex --project globex-dev --project-domain lab-globex member
G role add --group globex-ops --group-domain lab-globex --project globex-prod --project-domain lab-globex member
G role add --group globex-ops --group-domain lab-globex --project globex-dev --project-domain lab-globex reader
G role add --group globex-audit --group-domain lab-globex --domain lab-globex --inherited reader

G role assignment list --domain lab-globex --names
```

✅ **Observé :** avec `G` = `openstack`, toutes les commandes réussissent ; `role assignment list --domain lab-globex` montre `manager gaelle` et `reader` hérité pour le groupe `globex-audit` (les affectations sur les projets se lisent avec `--project`). Avec `G` = Gaëlle, sur ce lab, elles échoueraient en `403` : c’est une limite du rôle `manager` de ce Keystone, à faire relever dans l’évaluation (partie E).

✅ **Attendu (corrigé du livrable) :**

```text
lab-globex (domaine)
└── globex-si
    ├── globex-prod
    └── globex-dev
```

| Acteur | Rôle | Cible | Hérité |
|---|---|---|---|
| `gaelle` | `manager` | domaine `lab-globex` | non |
| groupe `globex-dev` | `member` | `globex-dev` | non |
| groupe `globex-ops` | `member` | `globex-prod` | non |
| groupe `globex-ops` | `reader` | `globex-dev` | non |
| groupe `globex-audit` | `reader` | domaine `lab-globex` | **oui** (tous les projets) |

### Phase 3 : la plateforme fixe les quotas (compte `admin`)

```bash
GDEV=$(openstack project show globex-dev --domain lab-globex -f value -c id)
GPROD=$(openstack project show globex-prod --domain lab-globex -f value -c id)
openstack quota set "$GDEV" --instances 2 --cores 2 --ram 4096 --networks 2
openstack quota set "$GPROD" --instances 5 --cores 10 --ram 20480 --networks 3
openstack quota show "$GDEV" -f value | grep -E "^(instances|cores|ram|networks) "
```

`quota show` et `quota set` n’acceptent pas `--domain` (client 7.5.0) : on désigne chaque projet par son identifiant (TP 3, § 3.4).

❓ **Question :** pourquoi pas Gaëlle ? *Réponse : les quotas protègent la capacité commune de la plateforme ; un client ne fixe pas lui-même sa part.*

### Phase 4 : les membres travaillent

```bash
os_as hugo lab-globex projet globex-dev lab-globex -- network create globex-dev-net
os_as ines lab-globex projet globex-prod lab-globex -- network create globex-prod-net
os_as ines lab-globex projet globex-dev lab-globex -- network list
os_as jules lab-globex projet globex-prod lab-globex -- network list
```

✅ **Observé :** Hugo et Inès créent leurs réseaux ; Inès voit `globex-dev-net` (et `external-network`) ; Jules voit `globex-prod-net`.

### Phase 5 : le compte de service de supervision (compte `ines`)

```bash
os_as ines lab-globex projet globex-prod lab-globex -- application credential create globex-supervision \
  --role reader --expiration "$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%S)" \
  --description "Supervision : lecture des instances de production" -f json > /tmp/globex-ac.json
AC_ID=$(python3 -c "import json; print(json.load(open('/tmp/globex-ac.json'))['id'])")
AC_SECRET=$(python3 -c "import json; print(json.load(open('/tmp/globex-ac.json'))['secret'])")
os_appcred "$AC_ID" "$AC_SECRET" -- server list
```

✅ **Observé :** la liste (vide) des instances de `globex-prod`, sans mot de passe.

⚠ L’identifiant ne reçoit que les rôles **nommés** à sa création, pas les rôles impliqués (TP 4, § 4.5.2) : `--role reader` est donc indispensable ici, même si Inès a `member`, qui implique `reader`.

---

## Partie C : l’audit de conformité

Les apprenants vérifient chaque exigence du cahier des charges par une commande, et notent ✅ ou ❌.

| # | Exigence | Commande de vérification | Attendu |
|---|---|---|---|
| 1 | Gaëlle ne sort pas de son domaine | `os_as gaelle lab-globex domaine lab-globex -- user list --domain users` | ⛔ le client échoue : `'NoneType' object has no attribute 'id'` (voir ci-dessous) |
| 2 | Gaëlle ne peut pas créer d’administrateur | `os_as gaelle lab-globex domaine lab-globex -- role add --user hugo --user-domain lab-globex --project globex-dev --project-domain lab-globex admin` | ⛔ aucun message, code de sortie 0 : vérifier avec la ligne 7 (`0`) |
| 3 | Hugo n’a rien en production | `os_as hugo lab-globex projet globex-prod lab-globex -- server list` | ⛔ 401 |
| 4 | Inès lit le développement sans le modifier | `os_as ines lab-globex projet globex-dev lab-globex -- network create globex-intrus` | ⛔ 403 |
| 5 | Jules lit tout, ne modifie rien | `os_as jules lab-globex projet globex-dev lab-globex -- network create globex-intrus` | ⛔ 403 |
| 6 | Aucune affectation directe d’une personne sur un projet | `openstack role assignment list --domain lab-globex --names` puis, pour chaque projet, `openstack role assignment list --project <p> --project-domain lab-globex --names` | seulement des groupes |
| 7 | Aucun `admin` chez Globex | `openstack role assignment list --role admin --names --effective \| grep -c globex` | `0` |
| 8 | Quotas conformes | `openstack quota show "$GDEV"` | `instances` 2, `cores` 2, `ram` 4096, `networks` 2 |
| 9 | Le compte de supervision ne fait que lire | `os_appcred "$AC_ID" "$AC_SECRET" -- network create globex-intrus` | ⛔ 403 |
| 10 | Il expire sous 30 jours | `os_as ines lab-globex projet globex-prod lab-globex -- application credential show globex-supervision -c expires_at` | date à J+30 |

✅ **Observé** (18 octobre 2026) : les dix exigences sont vérifiées (✅), avant les incidents et après leur correction.

⚠ **Lignes 1 et 2 : le client masque les refus** (client 7.5.0 ; TP 2, § 2.4). Gaëlle ne peut pas lire le domaine `users` : le client ne trouve pas son identifiant et plante (`'NoneType' object has no attribute 'id'`). Et un `role add` refusé n’affiche rien : seule la ligne 7 prouve qu’aucun `admin` n’a été créé. Pour voir le vrai `403`, appeler l’API avec le jeton de Gaëlle, comme au TP 2.

Les refus attendus sont cohérents avec les règles lues au TP 1 (§ 1.6.2), même sans Secure RBAC complet :

| Lignes | Règle qui refuse |
|---|---|
| 1 | `list_users` n’accepte `reader` que sur le domaine visé (`users` n’est pas celui de Gaëlle) |
| 2 | `create_grant` exige `admin` |
| 4, 5, 9 | `create_network` exige `member` du projet ; `reader` n’implique pas `member` |

Si l’une passe au lieu d’être refusée, l’apprenant doit l’expliquer à partir des règles du TP 1.

---

## Partie D : les incidents

Le formateur injecte un incident à la fois, **sans dire lequel**. L’apprenant reçoit seulement le symptôme, diagnostique avec les commandes des TP précédents, corrige, et explique la cause.

### Fiche formateur : injection

| Incident | Symptôme donné à l’apprenant | Commande d’injection (compte `admin`) |
|---|---|---|
| I1 | « Hugo ne peut plus se connecter du tout. » | `openstack user set --disable hugo --domain lab-globex` |
| I2 | « Inès ne peut plus créer de réseau en production, alors qu’hier elle pouvait. » | `openstack role remove --group globex-ops --group-domain lab-globex --project globex-prod --project-domain lab-globex member` puis `openstack role add --group globex-ops --group-domain lab-globex --project globex-prod --project-domain lab-globex reader` |
| I3 | « Hugo ne peut plus créer de deuxième réseau en développement. » | `openstack quota set "$GDEV" --networks 1` |
| I4 | « Plus personne chez Globex ne peut se connecter. » | `openstack domain set --disable lab-globex` |
| I5 | « L’audit trouve un administrateur chez Globex. » | `openstack role add --user jules --user-domain lab-globex --project globex-si --project-domain lab-globex admin` |
| I6 | « Le script de supervision échoue avec une erreur d’authentification. » | `openstack role remove --group globex-ops --group-domain lab-globex --project globex-prod --project-domain lab-globex member` |
| I7 | « Un script de Globex lance `openstack user show hugo` et obtient une erreur. » | `openstack user create hugo --domain users --password "$LAB_PW"` |

### Fiche apprenant : méthode de diagnostic

1. **Reproduire** avec le compte concerné (`os_as …`), et lire le code : `401` (identité) ou `403` (autorisation) ou `409`/`413` (quota, conflit).
2. **Identité** : `openstack user show <u> --domain lab-globex -c enabled`, `openstack domain show lab-globex -c enabled`.
3. **Droits effectifs** : `openstack role assignment list --user <u> --user-domain lab-globex --names --effective`.
4. **Quotas** : `openstack quota show --usage <id du projet>` (identifiant : `openstack project show <projet> --domain lab-globex -f value -c id`).
5. **Journaux** : identifiant de requête (`--debug`), puis `sudo k8s kubectl -n openstack logs keystone-0 -c keystone --since=5m`.

### Fiche formateur : solutions

| Incident | Diagnostic attendu | Correction |
|---|---|---|
| I1 | `401` ; `user show` : `enabled = False` | `openstack user set --enable hugo --domain lab-globex` |
| I2 | `403` ; droits effectifs : `reader` seulement sur `globex-prod` | rétablir `member` pour le groupe, retirer `reader` |
| I3 | `409 Quota exceeded` ; `quota show --usage` : 1 réseau utilisé sur 1 | `openstack quota set "$GDEV" --networks 2` |
| I4 | `401` pour tous ; `domain show` : `enabled = False` | `openstack domain set --enable lab-globex` |
| I5 | `role assignment list --role admin --effective` montre `jules` sur `globex-si` | retirer l’affectation ; rappeler pourquoi `admin` déborde de sa cible |
| I6 | `401` avec l’identifiant d’application ; Inès n’a plus de rôle sur `globex-prod` | rétablir `member` pour le groupe ; l’identifiant d’application suit les droits de son propriétaire |
| I7 | Avec le jeton de l’administrateur (domaine `admin_domain`) : `No User found for hugo` (constaté le 18 octobre 2026) ; avec un jeton d’un autre domaine, selon où le client cherche : `No User found` ou `More than one user exists with the name 'hugo'`. Dans les deux cas, le nom seul ne désigne pas le bon compte | corriger le script : `--domain lab-globex`, ou l’identifiant ; supprimer le compte en trop dans `users` |

⚠ Après chaque incident, **vérifier que la correction est complète** en rejouant l’audit de la partie C.

---

## Partie E : grille d’évaluation

| Critère | Points |
|---|---|
| Livrable (arbre et affectations) conforme avant la mise en œuvre | 4 |
| Chaque phase faite par le bon acteur (plateforme, gestionnaire, membre), et limite du rôle `manager` sur ce lab constatée et expliquée | 3 |
| Droits donnés par groupes uniquement | 2 |
| Quotas conformes | 1 |
| Identifiant d’application en lecture seule, avec expiration | 2 |
| Audit de la partie C complet, écarts expliqués | 3 |
| Incidents diagnostiqués avec la bonne commande et la bonne cause (1 point chacun) | 7 |
| Lecture correcte d’un `401` et d’un `403` | 1 |
| **Total** | **23** |

---

## Nettoyage

```bash
os_as hugo lab-globex projet globex-dev lab-globex -- network delete globex-dev-net
os_as ines lab-globex projet globex-prod lab-globex -- network delete globex-prod-net
openstack user delete hugo --domain users 2>/dev/null
rm -f /tmp/globex-ac.json
bash ~/labs-iam/nettoyage.sh
```

Si l’incident I6 n’a pas été corrigé, Inès n’a plus le droit de supprimer son réseau : supprime-le avec le compte `admin` (`openstack network delete globex-prod-net`).
