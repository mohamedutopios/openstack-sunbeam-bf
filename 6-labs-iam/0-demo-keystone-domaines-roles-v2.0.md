# Démo Keystone — domaines, projets, rôles, groupes et scopes

**Cible** : OpenStack Sunbeam (Canonical OpenStack).
**Scénario** : un fournisseur de cloud héberge deux clients, **ACME** et **Globex**. On construit l'organisation d'identité pas à pas, et à chaque étape on prouve par des tests ce qu'un utilisateur peut faire, ce qu'il ne peut pas faire, et pourquoi.

**Idée directrice de toute la démo** : dans Keystone, un rôle ne donne aucun droit par lui-même. Ce qui compte, c'est le triplet **qui** (user ou groupe) × **quel rôle** × **sur quelle portée** (projet, domaine, système). Chaque étape ajoute une dimension et teste ce qui change.

Chaque étape suit le même format :
- **Ce qu'on montre** : la notion.
- **Pourquoi c'est important** : le problème que ça résout en production.
- **Commandes** : ce que l'admin exécute.
- **Tests** : ce qu'on fait faire à l'utilisateur, le résultat attendu, ce que ça prouve.
- **Limite / leçon** : ce qu'il faut retenir.

Codes de résultat : `OK` = réussit ; `401` = Keystone refuse de délivrer un token pour ce scope (l'utilisateur n'y a **aucun** rôle) ; `403` = token délivré mais la policy refuse l'opération (l'utilisateur a un rôle, mais pas le bon ou pas sur la bonne portée). Distinguer 401 et 403 est en soi pédagogique : 401 = « tu n'es pas là », 403 = « tu es là mais tu n'as pas le droit ».

---

## 0. Prérequis

### Ce qu'on montre
L'état initial du cloud : les rôles livrés par Keystone et leur hiérarchie. Avant d'ajouter quoi que ce soit, on regarde ce qui existe.

### Commandes
```bash
# 0.1 Client OpenStack
sudo snap install openstackclients

# 0.2 Identifiants admin du cloud
sunbeam openrc > ~/admin-openrc
source ~/admin-openrc
openstack token issue -f value -c project_id      # OK : l'admin travaille avec un token scopé sur le projet admin

# 0.3 Rôles par défaut et chaîne d'implication
openstack role list
openstack implied role list
```

### Ce qu'on observe
- Quatre rôles par défaut : `reader`, `member`, `manager`, `admin` (plus `service` pour les comptes techniques).
- `implied role list` montre `admin → manager → member → reader` : avoir `admin` c'est avoir aussi les trois autres. On n'a donc jamais besoin de donner plusieurs rôles à la même personne sur la même cible.
- Le domaine de l'admin Sunbeam est `admin_domain` (visible dans `~/admin-openrc`), pas `default`.

Si `manager` est absent : Keystone < 2024.2. L'étape 5 se joue alors avec `admin` sur le domaine, et le test « manager ne distribue pas admin » devient `OK` au lieu de `403`. À signaler aux apprenants.

### Environnement de test
```bash
# 0.4 Fichier d'environnement : survit aux changements de terminal
cat > ~/demo-env.sh <<'EOF'
export PASS='Demo-2026!'

# os_as <user> <domaine-du-user> <scope> <commande openstack...>
# scope : project:<projet>:<domaine>  |  domain:<domaine>  |  system  |  none
os_as() {
  local user="$1" udom="$2" scope="$3"; shift 3
  local scope_env=()
  case "$scope" in
    project:*) IFS=: read -r _ proj pdom <<< "$scope"
               scope_env=(OS_PROJECT_NAME="$proj" OS_PROJECT_DOMAIN_NAME="$pdom") ;;
    domain:*)  scope_env=(OS_DOMAIN_NAME="${scope#domain:}") ;;
    system)    scope_env=(OS_SYSTEM_SCOPE=all) ;;
    none)      ;;
  esac
  env -u OS_CLOUD -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME -u OS_PROJECT_ID -u OS_PROJECT_DOMAIN_ID \
      -u OS_DOMAIN_NAME -u OS_DOMAIN_ID -u OS_SYSTEM_SCOPE -u OS_USER_ID -u OS_USER_DOMAIN_ID \
      OS_USERNAME="$user" OS_PASSWORD="$PASS" OS_USER_DOMAIN_NAME="$udom" "${scope_env[@]}" \
      openstack "$@"
}
EOF
source ~/demo-env.sh
```

`os_as` fait exactement ce qu'un utilisateur ferait avec son propre `openrc` : il s'authentifie avec son mot de passe et demande un token sur le scope indiqué. L'intérêt pédagogique : on bascule d'un utilisateur et d'un scope à l'autre en une ligne, sans perdre la session admin, et on **voit** le scope dans la commande.

À chaque reprise dans un nouveau terminal : `source ~/admin-openrc && source ~/demo-env.sh`.

---

## 1. Domaines — un espace de noms par client

### Ce qu'on montre
Le domaine est le conteneur de plus haut niveau : utilisateurs, groupes et projets y vivent. Deux domaines peuvent contenir un utilisateur `alice` chacun sans conflit.

### Pourquoi c'est important
Multi-tenant : chaque client doit avoir ses identités isolées, administrables par lui, invisibles des autres. Sans domaine dédié, tout le monde serait dans `default` avec les comptes de service du cloud.

### Commandes
```bash
openstack domain create --description "Client ACME"   acme
openstack domain create --description "Client Globex" globex
openstack domain list
```

### Ce qu'on observe
`domain list` montre `default`, `admin_domain`, `acme`, `globex`. Un domaine est un objet trivial : nom, description, activé/désactivé. Tout l'intérêt vient de ce qu'on y range.

### Limite / leçon
Un domaine ne donne aucun droit à personne. Ce n'est qu'un périmètre sur lequel on pourra scoper des rôles plus tard.

---

## 2. Utilisateurs et groupes — une identité ≠ un droit

### Ce qu'on montre
Créer des utilisateurs et les ranger dans des groupes. Puis prouver qu'un utilisateur authentifié mais sans rôle **ne peut rien faire**.

### Pourquoi c'est important
En production, on n'affecte pas les rôles aux utilisateurs un par un mais aux groupes : l'arrivée ou le départ d'une personne se gère par `group add/remove user`, sans toucher aux affectations. C'est aussi ce que fera la fédération (étape ultérieure) : l'IdP place les utilisateurs dans des groupes, les groupes portent les rôles.

### Commandes
```bash
# ACME : alice administrera le domaine, bob développe, carol opère
openstack user create --domain acme --password "$PASS" alice
openstack user create --domain acme --password "$PASS" bob
openstack user create --domain acme --password "$PASS" carol

openstack group create --domain acme acme-devs
openstack group create --domain acme acme-ops
openstack group add user --group-domain acme --user-domain acme acme-devs bob
openstack group add user --group-domain acme --user-domain acme acme-ops  carol

# Globex : un seul utilisateur, pour tester plus tard les frontières entre domaines
openstack user create --domain globex --password "$PASS" dave
openstack group create --domain globex globex-users
openstack group add user --group-domain globex --user-domain globex globex-users dave
```

### Tests
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as bob acme none token issue` | `OK` | Keystone reconnaît bob : le token **non scopé** prouve l'identité, rien d'autre. |
| `os_as bob acme domain:acme token issue` | `401` | Sans rôle sur le domaine, pas de token scopé domaine. |
| `os_as bob acme none project list` | `OK`, liste vide | Un token non scopé permet de demander « où ai-je des droits ? » — réponse : nulle part. |

### Limite / leçon
Authentification et autorisation sont deux choses séparées. Un utilisateur existe, se connecte, et pourtant ne peut rien faire tant qu'on ne lui a pas affecté un rôle sur une portée. Horizon affiche dans ce cas « You are not authorized for any projects ».

---

## 3. Projets et sous-projets — où vivent les ressources

### Ce qu'on montre
Les projets, et la hiérarchie de projets (`--parent`). Puis préparer la question piège : un rôle sur le parent se propage-t-il aux enfants ?

### Pourquoi c'est important
Le projet est la seule portée que Nova, Neutron, Cinder comprennent : toute ressource a un `project_id`. Quotas, facturation, isolation réseau se font par projet. La hiérarchie sert à organiser (prod → web, db) et à préparer l'héritage de l'étape 6.

### Commandes
```bash
openstack project create --domain acme dev
openstack project create --domain acme prod
openstack project create --domain acme --parent prod web-prod
openstack project create --domain acme --parent prod db-prod

openstack project create --domain globex shared

openstack project show --domain acme prod --children
openstack project show --domain acme web-prod --parents
```

### Ce qu'on observe
`--children` et `--parents` affichent l'arbre. Un sous-projet est obligatoirement dans le domaine de son parent. On ne peut pas supprimer un parent qui a encore des enfants.

### Limite / leçon
À retenir dès maintenant et à vérifier à l'étape 5 : **la hiérarchie est purement organisationnelle. Elle ne propage aucun rôle.** Beaucoup d'administrateurs le découvrent en production.

---

## 4. Scope projet — le quotidien d'un utilisateur

### Ce qu'on montre
Le cas standard : `member` sur un projet. On teste ensuite ce que ce rôle **ne** donne **pas**.

### Pourquoi c'est important
C'est 95 % des affectations d'un cloud. Il faut que les apprenants sachent exactement ce qu'un `member` peut faire (toutes les ressources de son projet) et surtout où s'arrête son pouvoir (le projet d'à côté, le domaine, les identités).

### Commandes
```bash
openstack role add --group acme-devs --group-domain acme --project dev --project-domain acme member
openstack role assignment list --group acme-devs --group-domain acme --names
```

`role assignment list --names` est l'outil de diagnostic principal : il répond à « qui a quoi, où ». On l'utilisera à chaque étape.

### Tests (bob, membre de `acme-devs`)
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as bob acme project:dev:acme token issue` | `OK` | bob obtient un token scopé `dev` via son groupe : il n'a aucune affectation directe. |
| `os_as bob acme project:dev:acme network create net-bob` | `OK` | `member` crée des ressources ; le réseau est rattaché au `project_id` de `dev`. |
| `os_as bob acme project:prod:acme token issue` | `401` | Aucun rôle sur `prod` : bob ne peut même pas y entrer. |
| `os_as bob acme domain:acme token issue` | `401` | Un rôle projet ne donne rien sur le domaine qui contient ce projet. |
| `os_as bob acme project:dev:acme user create --domain acme zoe` | `403` | Token valide, mais un scope projet n'autorise jamais la gestion des identités, quel que soit le rôle. |
| `os_as bob acme project:dev:acme project list` | `OK`, montre `dev` seulement | Un utilisateur ne voit que les projets où il a un rôle. |

### Limite / leçon
Le scope projet est une bulle : tout ce qui est dedans, rien de ce qui est dehors. Et il est aveugle à Keystone : impossible de créer un utilisateur ou un projet depuis un scope projet, même en étant `admin` du domaine (on le reverra avec alice).

---

## 5. Scope domaine et `manager` — déléguer l'administration à un client

### Ce qu'on montre
Le rôle `manager` scopé **domaine** : l'administrateur délégué. Il gère les identités de son domaine sans être admin du cloud. On teste ses pouvoirs, puis ses trois limites : pas d'autre domaine, pas de rôle `admin`, pas de ressources.

### Pourquoi c'est important
Un fournisseur ne veut pas créer lui-même chaque utilisateur de chaque client. Il veut donner à un référent client le pouvoir de gérer ses utilisateurs, groupes, projets et affectations — et rien d'autre. Avant 2024.2 il fallait donner `admin` sur le domaine, avec un risque d'escalade ; `manager` est la réponse propre.

### Commandes
```bash
openstack role add --user alice --user-domain acme --domain acme manager
openstack role assignment list --user alice --user-domain acme --names
```

Note : ici le rôle est donné directement à un utilisateur, contrairement au principe de l'étape 2. C'est volontaire pour la démo (un seul administrateur délégué). En production : un groupe `acme-admins`.

### Tests — ce que `manager` peut faire (alice, scope domaine)
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as alice acme domain:acme token issue` | `OK` | Token scopé **domaine** : pas de `project_id` dans ce token. |
| `os_as alice acme domain:acme user create --domain acme --password "$PASS" erin` | `OK` | Crée des utilisateurs dans son domaine. |
| `os_as alice acme domain:acme project create --domain acme staging` | `OK` | Crée des projets dans son domaine. |
| `os_as alice acme domain:acme group add user --group-domain acme --user-domain acme acme-devs erin` | `OK` | Gère les groupes → erin devient `member` de `dev` par ricochet, sans aucune affectation. |
| `os_as alice acme domain:acme role add --user bob --user-domain acme --project prod --project-domain acme member` | `OK` | Distribue des rôles sur les projets de son domaine. |

### Tests — les limites de `manager`
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as alice acme domain:acme user create --domain globex --password "$PASS" eve` | `403` | Le pouvoir s'arrête au bord du domaine. |
| `os_as alice acme domain:acme role add --user bob --user-domain acme --project prod --project-domain acme admin` | `403` | `manager` distribue `reader`, `member`, `manager`, jamais `admin` : pas d'escalade possible. |
| `os_as alice acme domain:acme network create net-alice` | échec | Un token sans `project_id` est inutilisable pour Neutron/Nova : administrer ≠ consommer. |

### Tests — administrer et consommer sont deux scopes différents
```bash
os_as alice acme domain:acme role add --user alice --user-domain acme --project prod --project-domain acme member
```
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as alice acme project:prod:acme network create net-alice` | `OK` | Avec un scope projet et `member`, alice consomme comme n'importe quel utilisateur. |
| `os_as alice acme project:prod:acme user create --domain acme --password "$PASS" frank` | `403` | Même personne, même rôle `manager` sur le domaine, mais le token est scopé projet : Keystone refuse. **Le scope du token décide, pas la liste des rôles de la personne.** |

### Tests — vérifier l'absence d'héritage (annoncée à l'étape 3)
bob vient de recevoir `member` sur `prod` :
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as bob acme project:prod:acme token issue` | `OK` | L'affectation faite par alice fonctionne. |
| `os_as bob acme project:web-prod:acme token issue` | `401` | Sous-projet de `prod`, et pourtant rien : la hiérarchie ne propage pas les rôles. |

### Limite / leçon
- Un même utilisateur cumule souvent deux affectations : `manager` sur le domaine pour administrer, `member` sur des projets pour travailler. Dans Horizon, c'est le sélecteur de scope en haut de page.
- `manager` est conçu pour être donné à un client sans risque : il ne peut ni sortir de son domaine, ni se promouvoir `admin`.
- Si on avait donné `admin` sur le domaine au lieu de `manager` : mêmes pouvoirs, mais alice pourrait distribuer `admin`, et surtout un `admin` scopé projet est traité comme admin global par Nova/Neutron. C'est précisément ce que `manager` évite.

---

## 6. Héritage — propager explicitement un rôle vers le bas

### Ce qu'on montre
L'option `--inherited` : la seule façon de propager un rôle à une sous-arborescence. Deux cas : depuis un projet (vers ses sous-projets), depuis un domaine (vers tous ses projets). Et la subtilité qui piège : l'affectation héritée **ne couvre pas la cible elle-même**.

### Pourquoi c'est important
Cas réels : une équipe ops doit accéder à tous les projets de production présents **et futurs** ; un auditeur doit lire tout un domaine. Sans héritage, il faudrait ajouter une affectation à chaque création de projet — et l'oublier.

### 6.1 Héritage depuis un projet

```bash
openstack role add --group acme-ops --group-domain acme --project prod --project-domain acme --inherited member
```

Tests (carol, membre de `acme-ops`) :
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as carol acme project:web-prod:acme token issue` | `OK` | Hérité depuis `prod`. |
| `os_as carol acme project:db-prod:acme token issue` | `OK` | Idem : toute la descendance. |
| `os_as carol acme project:prod:acme token issue` | `401` | **La cible de l'affectation héritée n'est pas couverte.** Contre-intuitif, source classique de tickets. |
| `os_as carol acme project:dev:acme token issue` | `401` | Hors de l'arbre de `prod`. |

Pour couvrir aussi `prod`, il faut une affectation ordinaire en plus :
```bash
openstack role add --group acme-ops --group-domain acme --project prod --project-domain acme member
os_as carol acme project:prod:acme token issue      # OK
```

### 6.2 Héritage depuis un domaine

```bash
openstack role add --group acme-ops --group-domain acme --domain acme --inherited reader
```

Tests (carol) :
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as carol acme project:dev:acme token issue` | `OK` | `reader` hérité : carol entre dans `dev` sans affectation directe. |
| `os_as carol acme project:dev:acme network list` | `OK` | `reader` lit. |
| `os_as carol acme project:dev:acme network create net-carol` | `403` | `reader` n'écrit pas. Sur `web-prod` elle écrirait, car elle y est `member` par 6.1 : les rôles se cumulent. |
| `os_as carol acme domain:acme token issue` | `401` | L'héritage depuis un domaine couvre ses **projets**, pas le domaine lui-même. |

Le point fort de l'héritage, un projet créé après coup :
```bash
os_as alice acme domain:acme project create --domain acme sandbox
os_as carol acme project:sandbox:acme network list      # OK : couvert automatiquement, personne n'a rien ajouté
```

### Diagnostic
```bash
openstack role assignment list --user carol --user-domain acme --names             # affectations directes : aucune
openstack role assignment list --user carol --user-domain acme --names --effective # ce qu'elle a réellement, groupes et héritage résolus
```
La différence entre les deux sorties est la démonstration en elle-même : carol n'a aucune affectation directe, et pourtant des droits sur six projets.

### Limite / leçon
- `--inherited` = descendants uniquement. Pour couvrir la cible, ajouter une affectation normale.
- L'héritage et les groupes se combinent : c'est `--effective` qui dit la vérité.
- Préférer l'héritage depuis le domaine pour les rôles transverses (ops, audit), l'héritage depuis un projet pour une arborescence précise.

---

## 7. Affectations entre domaines — les objets sont cloisonnés, pas les droits

### Ce qu'on montre
Un groupe du domaine ACME reçoit un rôle sur un projet du domaine Globex. Puis on vérifie que seul l'admin cloud peut faire ce pont, pas le `manager` d'un domaine.

### Pourquoi c'est important
Cas réel : un prestataire (ACME) intervient en lecture sur un projet d'un client (Globex) ; une équipe transverse du fournisseur supervise plusieurs clients. Il faut comprendre que le domaine enferme les **objets** (users, groupes, projets) mais que les **affectations** traversent librement — et donc qui a le droit de les créer.

### Commandes
```bash
openstack role add --group acme-ops --group-domain acme --project shared --project-domain globex reader
```

### Tests
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as carol acme project:shared:globex token issue` | `OK` | Utilisateur ACME, token sur un projet Globex. Noter `OS_USER_DOMAIN_NAME=acme` et `OS_PROJECT_DOMAIN_NAME=globex` : deux domaines dans la même authentification. |
| `os_as carol acme project:shared:globex network list` | `OK` | `reader` lit. |
| `os_as carol acme project:shared:globex network create x` | `403` | `reader` n'écrit pas. |
| `os_as carol acme domain:globex token issue` | `401` | Un rôle sur un projet de Globex ne donne rien sur le domaine Globex. |
| `os_as alice acme domain:acme role add --group acme-ops --group-domain acme --project shared --project-domain globex member` | `403` | Le `manager` d'ACME ne peut pas affecter de rôles sur un projet Globex : seul l'admin cloud fait le pont entre domaines. |
| `os_as dave globex none project list` | `OK`, vide | dave, pourtant dans le domaine Globex, n'a rien sur `shared` : être dans le domaine d'un projet ne donne aucun droit dessus. |

### Limite / leçon
- Les affectations croisées sont possibles et utiles, mais elles cassent la lecture « un domaine = un client » : à documenter, et à réserver à l'admin cloud.
- Un groupe peut même contenir des utilisateurs d'un autre domaine (`group add user --user-domain globex`) ; techniquement permis, à éviter pour la même raison.

---

## 8. Scope système — l'infrastructure, pas les ressources

### Ce qu'on montre
La troisième portée : le système. Elle concerne le déploiement lui-même (catalogue de services, endpoints, domaines, régions). On teste qu'un `reader` système voit tout le cloud sans pouvoir rien y faire, ni y consommer.

### Pourquoi c'est important
Séparer l'administration de la plateforme de la consommation. Un auditeur ou un outil de supervision a besoin de lire tous les domaines et le catalogue sans avoir le moindre rôle projet. Et l'admin cloud devrait administrer Keystone depuis un scope système plutôt que depuis le projet `admin`.

### Commandes
```bash
openstack role add --user alice --user-domain acme --system all reader
```

### Tests (alice, scope système)
| Commande | Attendu | Ce que ça prouve |
|---|---|---|
| `os_as alice acme system token issue` | `OK` | Token sans projet ni domaine : `system: all`. |
| `os_as alice acme system domain list` | `OK`, tous les domaines | Le scope système voit au-delà de son propre domaine — alors que son `manager` sur `acme` ne lui montrait que `acme`. |
| `os_as alice acme system endpoint list` | `OK` | Lecture du catalogue de services. |
| `os_as alice acme system domain create foo` | `403` | `reader` ne crée rien. |
| `os_as alice acme system user create --domain globex --password "$PASS" eve` | `403` | `reader` système ≠ `manager` : voir n'est pas gérer. |
| `os_as alice acme system network list` | refus | Neutron n'a pas de notion de système : les ressources exigent un scope projet. |

### Limite / leçon
Trois portées, trois métiers : projet → ressources ; domaine → identités ; système → plateforme. Le même rôle `reader` change de sens selon la portée. Et aucune portée n'englobe les autres : alice, `manager` d'ACME et `reader` système, ne peut toujours pas créer un réseau sans un rôle projet.

Pour l'admin cloud : `openstack role add --user admin --user-domain admin_domain --system all admin` permet d'administrer Keystone avec `OS_SYSTEM_SCOPE=all` au lieu de passer par le projet `admin`.

---

## 9. Synthèse — ce que chaque combinaison a prouvé

| Qui | Rôle | Portée | Peut | Ne peut pas | Étape |
|---|---|---|---|---|---|
| bob | aucun | — | token non scopé | tout | 2 |
| bob | member (via acme-devs) | projet dev | ressources de dev | prod, domaine, identités | 4 |
| bob | member (direct, donné par alice) | projet prod | ressources de prod | web-prod, db-prod : pas d'héritage automatique | 5 |
| alice | manager | domaine acme | users, groupes, projets, affectations reader/member/manager dans acme | autre domaine, donner admin, créer des ressources | 5 |
| alice | member | projet prod | ressources de prod | identités, même en étant manager du domaine | 5 |
| alice | reader | système | lire catalogue, tous les domaines | écrire, consommer | 8 |
| carol | member hérité (acme-ops) | projet prod `--inherited` | web-prod, db-prod | prod lui-même, dev | 6.1 |
| carol | member (acme-ops) | projet prod | prod | — | 6.1 |
| carol | reader hérité (acme-ops) | domaine acme `--inherited` | lecture sur tous les projets d'acme, présents et futurs | le domaine lui-même, écrire | 6.2 |
| carol | reader (acme-ops) | projet shared (globex) | lecture d'un projet d'un autre domaine | domaine globex | 7 |
| erin | member (via acme-devs, ajoutée par alice) | projet dev | ressources de dev | — | 5 |
| dave | aucun | — | token non scopé | tout, y compris `shared` de son propre domaine | 7 |

Les six règles démontrées :
1. **Identité ≠ droit** : un utilisateur sans affectation ne peut rien faire (étape 2).
2. **Rôle × portée** : c'est le scope du token qui décide, pas la liste des rôles de la personne (étape 5, test frank).
3. **Projet → ressources, domaine → identités, système → plateforme** ; aucune portée n'englobe les autres (étapes 4, 5, 8).
4. **Hiérarchie ≠ héritage** : propager un rôle est explicite (`--inherited`) et exclut la cible (étapes 5, 6).
5. **Les affectations traversent les domaines, les objets non** ; seul l'admin cloud fait le pont (étape 7).
6. **Le groupe est l'unité d'affectation** ; `role assignment list --effective` est le seul moyen de voir la vérité (étapes 2, 6).

---

## 10. Nettoyage

Dans l'ordre inverse des dépendances. Seuls les objets réellement créés sont listés : `zoe`, `eve`, `frank`, `net-carol`, `x` étaient des échecs attendus.

```bash
source ~/admin-openrc

# Ressources Neutron
openstack network delete net-bob net-alice

# Sous-projets avant parents
openstack project delete --domain acme web-prod db-prod
openstack project delete --domain acme prod dev staging sandbox
openstack project delete --domain globex shared

# Utilisateurs et groupes (leurs affectations disparaissent avec eux)
openstack user delete --domain acme alice bob carol erin
openstack user delete --domain globex dave
openstack group delete --domain acme acme-devs acme-ops
openstack group delete --domain globex globex-users

# Un domaine doit être désactivé avant suppression
openstack domain set --disable acme   && openstack domain delete acme
openstack domain set --disable globex && openstack domain delete globex
```
