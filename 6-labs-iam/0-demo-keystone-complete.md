# Démo complète Keystone : domaines, projets, sous-projets, utilisateurs, groupes, rôles et jetons

> TP progressif pour OpenStack, notamment Sunbeam. Durée indicative : 1 h 30 à 2 h. Toutes les commandes sont expliquées. À exécuter dans **Bash**, sur une machine disposant du client `openstack` et d'un accès administrateur au cloud. Les résultats indiqués sont attendus ; ce document n'est pas le compte rendu d'une exécution sur votre infrastructure.

## 1. Le scénario : deux entreprises dans un même cloud

L'entreprise **ACME** développe une application. Le cabinet **AUDIT** contrôle son environnement de production.

| Objet | Nom dans le TP | Utilité |
|---|---|---|
| Domaine | `lab-acme` | Regrouper les identités et projets d'ACME |
| Domaine | `lab-audit` | Regrouper les identités du cabinet externe |
| Projet parent | `lab-app` | Organiser l'application et porter une attribution héritée |
| Sous-projet | `lab-dev` | Environnement de développement |
| Sous-projet | `lab-prod` | Environnement de production |
| Utilisatrice | `alice`, dans `lab-acme` | Développeuse, membre sur dev |
| Utilisateur | `bob`, dans `lab-acme` | Lecteur des deux sous-projets |
| Utilisatrice | `claire`, dans `lab-acme` | Lecture des identités du domaine, puis du système |
| Utilisateur | `david`, dans `lab-audit` | Auditeur externe de prod |
| Groupe | `lab-developpeurs`, dans `lab-acme` | Accorder les droits de développement |
| Groupe | `lab-exploitation`, dans `lab-acme` | Accorder la lecture par héritage |
| Groupe | `lab-auditeurs`, dans `lab-audit` | Donner accès à prod depuis un autre domaine |
| Rôle personnalisé | `lab-auditeur-securite` | Observer un rôle sans règle, puis l'implication de `reader` |

Un sous-projet est un projet normal doté d'un `parent_id`. Il ne devient pas automatiquement accessible aux utilisateurs du parent. Les projets parent et enfants restent des périmètres de ressources distincts.

**L'idée à retenir : une attribution relie un utilisateur ou un groupe, un rôle et une portée.** Exemple : « groupe lab-developpeurs → rôle member → projet lab-dev ».

## 2. Les concepts avant les commandes

| Concept | Explication concrète |
|---|---|
| Domaine | Espace de noms pour utilisateurs, groupes et projets ; ce n'est pas un réseau ni une frontière physique |
| Projet | Périmètre auquel sont rattachées de nombreuses ressources : VM, volumes, réseaux… |
| Sous-projet | Projet placé sous un autre projet pour organiser une hiérarchie |
| Utilisateur | Identité qui s'authentifie ; elle appartient à un domaine |
| Groupe | Ensemble d'utilisateurs auquel on attribue des rôles collectivement |
| Rôle | Nom porté par une attribution ; les règles des services lui donnent un effet |
| Attribution | Association utilisateur/groupe + rôle + projet/domaine/système |
| Jeton | Justificatif temporaire présenté aux API après authentification |
| Portée / scope | Contexte d'utilisation du jeton : un projet, un domaine ou le système |
| Policy | Règle d'autorisation évaluée par un service pour une opération |

**Authentification :** « Qui es-tu ? » Keystone vérifie par exemple un utilisateur et son mot de passe.

**Autorisation :** « Peux-tu effectuer cette opération dans ce contexte ? » Le service appelé vérifie le contexte, les rôles et ses policies.

Créer un rôle ne crée pas une liste de permissions. `reader`, `member` et `admin` ont un effet parce que les policies des services les reconnaissent. Leurs implications habituelles sont `admin → member → reader` ; nous les vérifierons.

Un rôle `member` sur un projet ne donne pas, à lui seul, le droit de créer des utilisateurs Keystone. Un droit de lecture de domaine ne donne pas un jeton utilisable comme lecteur de toutes ses VM.

## 3. Préparer le terminal administrateur

### 3.1. Charger les accès

Sur Sunbeam, depuis le compte qui administre le déploiement :

```bash
sunbeam openrc > ~/admin-openrc
chmod 600 ~/admin-openrc
source ~/admin-openrc
```

- `sunbeam openrc` produit les variables d'accès administrateur.
- `>` enregistre cette configuration dans un fichier.
- `chmod 600` réserve la lecture et l'écriture au propriétaire.
- `source` charge les variables dans le terminal actuel.

Sur un autre déploiement, charger son fichier administrateur fourni par l'exploitant. Ne pas remplacer celui-ci par des identifiants inventés.

```bash
openstack --version
openstack token issue -c user_id -c project_id -c expires
openstack domain list
openstack role list
openstack implied role list
```

Explications :

- `--version` identifie le client installé.
- `token issue` obtient un jeton ; `-c` choisit les colonnes affichées, ici sans exposer son identifiant secret.
- `domain list` vérifie que les accès permettent de lister les domaines.
- `role list` affiche les rôles existants.
- `implied role list` affiche les implications entre rôles.

**Précondition :** les rôles globaux `reader` et `member` existent. Ne pas modifier leurs implications globales dans ce TP. Si les opérations administratives sont refusées, vérifier les accès et les policies avant de poursuivre.

Les commandes de création ci-dessous sont prévues pour une première exécution. Un message de conflit sur un nom `lab-*` signifie qu'il faut reprendre un laboratoire existant ou le nettoyer, pas ignorer toutes les erreurs.

### 3.2. Conserver les paramètres utiles

```bash
export LAB_AUTH_URL="$OS_AUTH_URL"
export LAB_CACERT="${OS_CACERT:-}"
export LAB_REGION="${OS_REGION_NAME:-}"
umask 077
mkdir -p ~/tp-keystone
cd ~/tp-keystone
```

- `LAB_AUTH_URL` conserve l'URL Keystone fournie par le cloud, y compris son éventuel préfixe Sunbeam.
- `LAB_CACERT` conserve le certificat d'autorité s'il est configuré.
- `LAB_REGION` conserve la région du cloud.
- `umask 077` rend les nouveaux fichiers privés pour le propriétaire.
- Le dossier contiendra les fichiers de jetons de la démo. Ils sont secrets.

Installer `python3` et `jq` s'ils ne sont pas disponibles. `jq` sert uniquement à lire le JSON. Sur Ubuntu : `sudo apt install python3 jq`.

## 4. Créer les domaines et la hiérarchie de projets

**Contexte : administrateur.** Toutes les commandes `openstack` sans fonction d'encapsulation utilisent les accès administrateur du terminal.

```bash
openstack domain create --description "Entreprise ACME - TP" lab-acme
openstack domain create --description "Cabinet AUDIT - TP" lab-audit
```

`domain create` crée le domaine. `--description` ajoute un texte explicatif. Le dernier argument est le nom.

Récupérer les identifiants :

```bash
ACME_ID=$(openstack domain show lab-acme -f value -c id)
AUDIT_ID=$(openstack domain show lab-audit -f value -c id)
```

`domain show` affiche un domaine. `-f value -c id` renvoie uniquement son identifiant. `$(...)` récupère la sortie dans une variable Bash. Les ID évitent les ambiguïtés de noms.

```bash
APP_ID=$(openstack project create --domain "$ACME_ID" \
  --description "Application ACME" lab-app -f value -c id)

DEV_ID=$(openstack project create --domain "$ACME_ID" --parent "$APP_ID" \
  --description "Developpement" lab-dev -f value -c id)

PROD_ID=$(openstack project create --domain "$ACME_ID" --parent "$APP_ID" \
  --description "Production" lab-prod -f value -c id)
```

- `project create` crée un projet.
- `--domain` indique le domaine propriétaire du projet.
- `--parent` indique son projet parent. Ici, les enfants et leur parent appartiennent au même domaine.
- Les variables stockent les ID des trois projets.

Vérifier :

```bash
openstack project list --domain "$ACME_ID"
openstack project show "$APP_ID" -c id -c name -c domain_id -c parent_id
openstack project show "$DEV_ID" -c id -c name -c domain_id -c parent_id
openstack project show "$PROD_ID" -c id -c name -c domain_id -c parent_id
```

`project list --domain` filtre la liste par domaine. `project show` permet de comparer les relations. Les `parent_id` de dev et prod doivent être égaux à `APP_ID`. Le projet racine est rattaché à la représentation interne du domaine : ne pas exiger que son `parent_id` soit vide.

**Ce que la hiérarchie ne fait pas :** elle ne partage pas automatiquement les VM, les réseaux ni les droits, et ne garantit pas un quota agrégé parent/enfants. Les quotas dépendent du service et du mécanisme de limites configuré.

## 5. Créer utilisateurs et groupes

```bash
openstack user create --domain "$ACME_ID" --password-prompt alice
openstack user create --domain "$ACME_ID" --password-prompt bob
openstack user create --domain "$ACME_ID" --password-prompt claire
openstack user create --domain "$AUDIT_ID" --password-prompt david
```

`user create` crée une identité dans le domaine indiqué. `--password-prompt` demande son mot de passe sans le mettre dans la ligne de commande. Choisir et conserver les quatre mots de passe pour la durée du TP. Aucun projet par défaut n'est attribué.

```bash
ALICE_ID=$(openstack user show --domain "$ACME_ID" alice -f value -c id)
BOB_ID=$(openstack user show --domain "$ACME_ID" bob -f value -c id)
CLAIRE_ID=$(openstack user show --domain "$ACME_ID" claire -f value -c id)
DAVID_ID=$(openstack user show --domain "$AUDIT_ID" david -f value -c id)

DEVS_ID=$(openstack group create --domain "$ACME_ID" lab-developpeurs -f value -c id)
OPS_ID=$(openstack group create --domain "$ACME_ID" lab-exploitation -f value -c id)
AUDIT_GROUP_ID=$(openstack group create --domain "$AUDIT_ID" lab-auditeurs -f value -c id)
```

`user show --domain` résout l'utilisateur dans le bon domaine. `group create --domain` crée un groupe dans celui-ci. Les ID sont à nouveau stockés pour les commandes suivantes.

```bash
openstack group add user "$DEVS_ID" "$ALICE_ID"
openstack group add user "$OPS_ID" "$BOB_ID"
openstack group add user "$AUDIT_GROUP_ID" "$DAVID_ID"

openstack user list --group "$DEVS_ID"
openstack user list --group "$OPS_ID"
openstack user list --group "$AUDIT_GROUP_ID"
```

`group add user GROUPE UTILISATEUR` ajoute un membre. `user list --group` vérifie la composition du groupe.

**À ce stade, appartenir à un domaine ou à un groupe ne donne encore aucun droit sur un projet.**

## 6. Tester un accès refusé avant toute attribution

Pour éviter qu'un test d'Alice utilise accidentellement le projet ou le mot de passe de l'administrateur, définir cette fonction une fois :

```bash
os_as() (
  local lab_user="$1" lab_user_domain="$2" lab_scope="$3" lab_target="$4"
  shift 4
  local lab_var
  for lab_var in ${!OS_@}; do unset "$lab_var"; done
  export OS_AUTH_URL="$LAB_AUTH_URL" OS_IDENTITY_API_VERSION=3
  export OS_AUTH_TYPE=password OS_USERNAME="$lab_user"
  export OS_USER_DOMAIN_NAME="$lab_user_domain"
  [ -z "$LAB_CACERT" ] || export OS_CACERT="$LAB_CACERT"
  [ -z "$LAB_REGION" ] || export OS_REGION_NAME="$LAB_REGION"
  case "$lab_scope" in
    project) export OS_PROJECT_ID="$lab_target" ;;
    domain)  export OS_DOMAIN_ID="$lab_target" ;;
    system)  export OS_SYSTEM_SCOPE=all ;;
    unscoped) ;;
    *) echo "Portee invalide" >&2; return 2 ;;
  esac
  read -rsp "Mot de passe de $lab_user : " OS_PASSWORD
  echo >&2
  export OS_PASSWORD
  openstack "$@"
)
```

Explications :

- `os_as` est une fonction **créée pour ce TP**, pas une commande OpenStack ni Sunbeam.
- Ses quatre premiers paramètres sont utilisateur, domaine de l'utilisateur, type de portée, cible de la portée. Le reste est la commande OpenStack.
- Les parenthèses exécutent le corps dans un sous-shell : les accès administrateur du terminal sont conservés.
- `shift 4` retire les quatre paramètres de contexte.
- La boucle efface les variables `OS_*` héritées, y compris projet, token, cloud et mot de passe.
- `case` définit une seule portée. Pour `system` et `unscoped`, utiliser `-` comme quatrième paramètre de convention.
- `read -rsp` demande le mot de passe sans l'afficher ; il sera redemandé à chaque appel.
- `openstack "$@"` exécute la commande demandée avec ce contexte.

Tester Alice sur dev :

```bash
os_as alice lab-acme project "$DEV_ID" token issue -c user_id -c project_id -c expires
```

**Résultat attendu : refus d'obtention du jeton de projet**, généralement HTTP 401/403. Alice existe, mais n'a encore aucun rôle sur dev.

Puis demander un jeton sans portée :

```bash
os_as alice lab-acme unscoped - token issue -c user_id -c expires
```

**Résultat attendu : succès.** Les identifiants sont valides. Cela ne donne pas de droit sur les ressources de dev. Aucun projet par défaut n'ayant été défini, le client ne doit pas obtenir implicitement un jeton de projet.

## 7. Donner les droits de développement par groupe

```bash
openstack role add --group "$DEVS_ID" --project "$DEV_ID" member

openstack role assignment list --group "$DEVS_ID" --project "$DEV_ID" --names
openstack role assignment list --user "$ALICE_ID" --project "$DEV_ID" --effective --names
```

- `role add` crée une attribution, pas un nouveau rôle.
- `--group` indique le bénéficiaire collectif.
- `--project` indique le périmètre.
- `member` est le rôle accordé.
- La première liste montre l'attribution portée par le groupe.
- `--effective` demande les attributions effectives, notamment celles obtenues via les groupes et l'héritage. Pour examiner les rôles réellement présents dans un jeton, utiliser également l'étape 13.

```bash
os_as alice lab-acme project "$DEV_ID" token issue -c user_id -c project_id -c expires
os_as alice lab-acme project "$DEV_ID" server list
os_as alice lab-acme project "$PROD_ID" token issue -c user_id -c project_id -c expires
```

Attendu :

1. Alice obtient un jeton pour dev.
2. `server list` liste les VM de dev ; un tableau vide est un succès si aucune VM n'existe.
3. Alice ne peut pas obtenir de jeton pour prod.

`server list` appelle Nova : ce test vérifie aussi le catalogue, la connectivité et les policies de Nova. Un HTTP 503 ou une erreur de connexion ne démontre pas un défaut de droits.

## 8. Comprendre l'héritage : parent et sous-projets

### 8.1. Attribution normale sur le parent

```bash
openstack role add --group "$OPS_ID" --project "$APP_ID" reader

os_as bob lab-acme project "$APP_ID" token issue -c project_id -c expires
os_as bob lab-acme project "$DEV_ID" token issue -c project_id -c expires
```

Attendu : jeton possible sur le parent ; refus sur dev. Un rôle attribué au parent **sans `--inherited` ne descend pas automatiquement** vers les enfants.

### 8.2. Remplacer par une attribution héritée

```bash
openstack role remove --group "$OPS_ID" --project "$APP_ID" reader
openstack role add --group "$OPS_ID" --project "$APP_ID" --inherited reader
```

- `role remove` supprime l'attribution normale.
- `role add ... --inherited reader` définit une attribution destinée aux projets descendants.
- Cette attribution héritée **ne donne pas, à elle seule, le rôle sur le projet parent**.

```bash
openstack role assignment list --group "$OPS_ID" --project "$APP_ID" --inherited --names
openstack role assignment list --user "$BOB_ID" --project "$DEV_ID" --effective --names
openstack role assignment list --user "$BOB_ID" --project "$PROD_ID" --effective --names

os_as bob lab-acme project "$DEV_ID" server list
os_as bob lab-acme project "$PROD_ID" server list
os_as bob lab-acme project "$APP_ID" token issue -c project_id -c expires
```

Attendu : lecture de dev et prod ; refus d'un nouveau jeton sur le parent. La liste avec `--inherited` montre l'attribution source, et les listes `--effective` montrent ses effets sur les enfants.

Si Bob devait aussi lire le parent, ajouter **en plus** l'attribution normale :

```bash
# Variante explicative : ne pas exécuter pour conserver les résultats du TP.
# openstack role add --group "$OPS_ID" --project "$APP_ID" reader
```

### 8.3. Héritage depuis un domaine

Variante équivalente pour tous les projets d'un domaine :

```bash
# Variante explicative : ne pas exécuter dans le scénario principal.
# openstack role add --group "$OPS_ID" --domain "$ACME_ID" --inherited reader
```

Cette fois, le rôle serait effectif sur les projets du domaine, dont le projet racine et ses descendants. Cela ne donne pas à lui seul un rôle de portée domaine. Attention à la différence avec `--domain ... reader` **sans** `--inherited`, utilisé à l'étape 11.

## 9. Un groupe d'un autre domaine peut accéder à prod

```bash
openstack role add --group "$AUDIT_GROUP_ID" --project "$PROD_ID" reader

openstack role assignment list --user "$DAVID_ID" --project "$PROD_ID" --effective --names
os_as david lab-audit project "$PROD_ID" server list
os_as david lab-audit project "$DEV_ID" token issue -c project_id -c expires
```

David appartient à `lab-audit`, mais le projet cible appartient à `lab-acme`. C'est autorisé par une attribution explicite ; le domaine de l'utilisateur n'a pas besoin d'être celui du projet.

Attendu : accès à prod, refus sur dev. L'attribution ne déplace ni David ni son groupe.

La même attribution, écrite avec des noms, serait :

```bash
# Même attribution, syntaxe alternative : inutile de l'exécuter à nouveau.
# openstack role add \
#   --group lab-auditeurs --group-domain lab-audit \
#   --project lab-prod --project-domain lab-acme reader
```

`--group-domain` résout le nom du groupe ; `--project-domain` résout le nom du projet. Ce sont deux espaces de noms différents.

## 10. Créer un rôle personnalisé et observer son effet réel

### 10.1. Retirer reader, puis attribuer le nouveau rôle

```bash
openstack role remove --group "$AUDIT_GROUP_ID" --project "$PROD_ID" reader
openstack role create lab-auditeur-securite
openstack role add --group "$AUDIT_GROUP_ID" --project "$PROD_ID" lab-auditeur-securite

os_as david lab-audit project "$PROD_ID" token issue -c user_id -c project_id -c expires
os_as david lab-audit project "$PROD_ID" server list
```

Attendu : David peut obtenir un jeton de projet portant `lab-auditeur-securite`. En revanche, la liste des VM doit être refusée si la policy Nova exige `reader` ou un rôle impliquant `reader`.

**Nuance : un rôle sans policy associée n'implique pas zéro accès à toutes les API.** Certaines opérations peuvent être autorisées au seul titre d'utilisateur authentifié ou de membre du projet selon les policies installées. Le rôle est « sans permission explicitement définie pour lui », et non une interdiction universelle.

Si `server list` réussit déjà, examiner la policy Nova de cette version ; ne pas conclure que Keystone transforme automatiquement le nouveau rôle en `reader`.

### 10.2. Faire impliquer reader par le rôle métier

```bash
openstack implied role create lab-auditeur-securite --implied-role reader
openstack implied role list

os_as david lab-audit project "$PROD_ID" server list
```

`implied role create RÔLE_SOURCE --implied-role RÔLE_IMPLIQUÉ` définit : si le rôle source est accordé, son rôle impliqué est aussi obtenu. Demander un nouveau jeton pour constater les rôles à jour ; l'appel `os_as` le fait.

Attendu : la lecture autorisée à `reader` fonctionne maintenant.

**Ce rôle métier a maintenant les droits de `reader` dans ce contexte.** Cela ne crée pas une permission fine « uniquement lire les VM et rien d'autre ». Pour ce dernier besoin, il faut écrire les policies des services concernés et les déployer par un mécanisme pris en charge par la version des charms Sunbeam. Ne pas modifier directement un conteneur éphémère et appeler cela une configuration persistante.

## 11. Jeton de domaine : lecture des identités

Attribuer à Claire le rôle `reader` directement sur le domaine :

```bash
openstack role add --user "$CLAIRE_ID" --domain "$ACME_ID" reader

os_as claire lab-acme domain "$ACME_ID" token issue -c user_id -c expires
os_as claire lab-acme domain "$ACME_ID" user list --domain "$ACME_ID"
```

- `--domain` dans `role add` définit une attribution de portée domaine.
- Dans `os_as`, `domain` sélectionne cette portée pour le jeton.
- `user list --domain` demande la liste des utilisateurs du domaine ciblé.

Avec les policies Keystone récentes prenant en charge la lecture de domaine, Claire peut lire ses identités. Si la dernière commande est refusée, noter la différence de policy/version ; l'émission d'un jeton domaine ne garantit pas l'autorisation de chaque API.

```bash
os_as claire lab-acme project "$DEV_ID" token issue -c project_id -c expires
```

Attendu : refus. Un `reader` de domaine sans héritage n'est pas automatiquement `reader` sur les projets de ce domaine.

**Qui peut créer des utilisateurs ?** Un acteur auquel les policies Keystone donnent ce droit. Cela peut être un administrateur du cloud ou une administration déléguée de domaine ; ce n'est pas nécessairement le seul utilisateur nommé `admin`. Ce TP n'accorde aucun rôle `admin` aux nouveaux utilisateurs.

## 12. Jeton système : lecture à l'échelle Keystone

```bash
openstack role add --user "$CLAIRE_ID" --system all reader

os_as claire lab-acme system - token issue -c user_id -c expires
os_as claire lab-acme system - domain list
```

- `--system all` crée une attribution au niveau du déploiement.
- Le jeton système obtenu par Claire est distinct de son jeton de domaine.
- `domain list` constitue ici un test de lecture système Keystone, sous réserve des policies actives.

Ne pas généraliser ce succès à toutes les API Nova, Neutron ou Cinder : la prise en charge des portées système varie selon le service, sa version et ses policies. Un jeton système n'est pas un jeton de projet cumulant tous les projets.

## 13. Voir le détail des jetons avec l'API Keystone

### 13.1. Pourquoi passer par l'API ?

`openstack token issue` affiche quelques champs, mais ne détaille pas tous les rôles ni le catalogue. L'API fournit un document JSON à inspecter : identité, portée, rôles, expiration et catalogue selon le type de jeton.

L'identifiant secret est retourné dans l'en-tête HTTP **`X-Subject-Token`**. Il n'est pas le JSON descriptif. Avec Fernet, fournisseur par défaut de Keystone, traiter cet identifiant comme opaque : ce n'est pas un JWT à décoder dans un site web. Le type réellement configuré doit être vérifié dans le déploiement.

Le petit outil ci-dessous utilise uniquement la bibliothèque standard Python. Il ne modifie ni les policies ni la configuration du cloud. Il rend explicites l'authentification, le changement de portée, la validation et la révocation.

### 13.2. Créer l'outil d'observation

Copier tout le bloc :

```bash
cat > token_lab.py <<'PY'
import getpass
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

base = os.environ['LAB_AUTH_URL'].rstrip('/')
if not base.endswith('/v3'):
    base += '/v3'
context = ssl.create_default_context(cafile=os.environ.get('LAB_CACERT') or None)

def load(path):
    return json.loads(Path(path).read_text())

def api(method, path, data=None, headers=None):
    h = {'Content-Type': 'application/json', **(headers or {})}
    request = urllib.request.Request(base + path,
        data=None if data is None else json.dumps(data).encode(),
        headers=h, method=method)
    try:
        with urllib.request.urlopen(request, context=context, timeout=30) as r:
            raw = r.read()
            return r.status, r.headers, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f'HTTP {e.code}: {e.read().decode()}', file=sys.stderr)
        raise SystemExit(1)

def emit_token(auth):
    status, headers, body = api('POST', '/auth/tokens', {'auth': auth})
    print(json.dumps({'id': headers['X-Subject-Token'], **body}, indent=2))

args = sys.argv[1:]
if not args:
    raise SystemExit('Usage : issue USER DOMAIN SCOPE [TARGET_ID] | '
                     'rescope FILE PROJECT_ID | validate FILE ADMIN_FILE | '
                     'revoke FILE ADMIN_FILE')
cmd = args[0]
if cmd == 'issue':
    _, user, domain, scope, *target = args
    auth = {'identity': {'methods': ['password'], 'password': {'user': {
        'name': user, 'domain': {'name': domain},
        'password': getpass.getpass(f'Mot de passe de {user} : ')}}}}
    if scope == 'project':
        auth['scope'] = {'project': {'id': target[0]}}
    elif scope == 'domain':
        auth['scope'] = {'domain': {'id': target[0]}}
    elif scope == 'system':
        auth['scope'] = {'system': {'all': True}}
    elif scope != 'unscoped':
        raise SystemExit('Portee inconnue')
    emit_token(auth)
elif cmd == 'rescope':
    _, filename, project_id = args
    emit_token({'identity': {'methods': ['token'], 'token': {'id': load(filename)['id']}},
                'scope': {'project': {'id': project_id}}})
elif cmd in ('validate', 'revoke'):
    _, filename, adminfile = args
    headers = {'X-Auth-Token': Path(adminfile).read_text().strip(),
               'X-Subject-Token': load(filename)['id']}
    status, _, body = api('GET' if cmd == 'validate' else 'DELETE',
                          '/auth/tokens', headers=headers)
    print(json.dumps({'http_status': status, **body}, indent=2))
else:
    raise SystemExit('Commande inconnue')
PY
```

Lecture de l'outil :

| Partie | Fonction |
|---|---|
| `LAB_AUTH_URL` | Réutilise le vrai point d'entrée, y compris un préfixe éventuel |
| `ssl.create_default_context` | Vérifie TLS et utilise l'autorité du cloud si fournie |
| `getpass` | Saisit le mot de passe sans l'afficher |
| `POST /auth/tokens` | Demande l'émission d'un jeton |
| `identity.methods` | Choisit l'authentification par mot de passe ou par jeton |
| `scope` | Demande une portée précise ; absent pour le cas sans portée |
| `GET /auth/tokens` | Valide un jeton et retourne sa description |
| `DELETE /auth/tokens` | Révoque le jeton ciblé |
| `X-Auth-Token` | Authentifie l'acteur qui demande validation/révocation |
| `X-Subject-Token` | Désigne le jeton à examiner ou à révoquer |

L'outil écrit les jetons dans la sortie standard ; on la redirige vers des fichiers privés. **Ne pas afficher leur champ `id` dans une capture publique.**

### 13.3. Émettre les quatre types de jetons

```bash
python3 token_lab.py issue alice lab-acme unscoped > alice-sans-portee.json
python3 token_lab.py issue alice lab-acme project "$DEV_ID" > alice-dev.json
python3 token_lab.py issue claire lab-acme domain "$ACME_ID" > claire-domaine.json
python3 token_lab.py issue claire lab-acme system > claire-systeme.json
python3 token_lab.py issue david lab-audit project "$PROD_ID" > david-prod.json
```

Chaque `issue` effectue une véritable requête d'authentification. Chaque fichier contient l'identifiant secret `id` et le document descriptif `token`. Les fichiers ne sont valables que jusqu'à expiration ou invalidation.

Inspecter sans afficher le secret :

```bash
jq '.token | {methods,user,project,domain,system,roles,issued_at,expires_at}' alice-dev.json
jq '.token | {user,project,domain,system,roles}' claire-domaine.json
jq '.token | {user,project,domain,system,roles}' claire-systeme.json
jq '.token.roles | map(.name)' david-prod.json
jq '.token | {project,domain,system,roles,catalog}' alice-sans-portee.json
```

`jq` sélectionne les champs demandés. Un champ absent sélectionné ainsi apparaît comme `null`.

| Fichier | Observation attendue |
|---|---|
| `alice-sans-portee.json` | Identité, pas de portée ni rôles ni catalogue |
| `alice-dev.json` | Projet dev ; `member` et normalement `reader` si l'implication existe |
| `claire-domaine.json` | Domaine ACME ; `reader` ; pas de portée projet ni système |
| `claire-systeme.json` | `system: {"all": true}` ; `reader` ; pas de portée projet |
| `david-prod.json` | Projet prod ; `lab-auditeur-securite` et `reader` |

Dans `user.domain`, le domaine décrit toujours l'identité de l'utilisateur. Ce champ ne signifie pas que le jeton a une portée domaine. Pour David, `user.domain` est AUDIT alors que `project.domain` est ACME.

### 13.4. Consulter le catalogue

```bash
jq '.token.catalog[] | {name,type,endpoints}' alice-dev.json
```

Le catalogue indique où joindre les services. `name` est le nom du service, `type` son type (`compute`, `network`…), `endpoints` ses adresses et interfaces. **Un service présent au catalogue n'implique pas l'autorisation de toutes ses opérations.**

### 13.5. Échanger un jeton sans portée contre un jeton de projet

```bash
python3 token_lab.py rescope alice-sans-portee.json "$DEV_ID" > alice-dev-echange.json
jq '.token | {methods,project,roles,expires_at}' alice-dev-echange.json
```

Cette commande utilise le premier jeton comme preuve d'identité et demande un **nouveau** jeton pour dev. Elle ne modifie pas le jeton initial et ne redemande pas le mot de passe. Keystone vérifie toujours les attributions d'Alice sur le projet cible.

```bash
python3 token_lab.py rescope alice-sans-portee.json "$PROD_ID"
```

Attendu : refus. Un jeton sans portée ne permet pas de contourner les droits de prod.

## 14. Utiliser exactement un jeton pour appeler Nova

Les appels précédents à `os_as` s'authentifient avec un mot de passe. Ici, on force l'utilisation du jeton déjà enregistré, sans authentification de remplacement.

```bash
with_alice_token() (
  local lab_var
  for lab_var in ${!OS_@}; do unset "$lab_var"; done
  export OS_AUTH_TYPE=token OS_AUTH_URL="$LAB_AUTH_URL"
  export OS_IDENTITY_API_VERSION=3 OS_PROJECT_ID="$DEV_ID"
  export OS_TOKEN="$(jq -r '.id' alice-dev.json)"
  [ -z "$LAB_CACERT" ] || export OS_CACERT="$LAB_CACERT"
  [ -z "$LAB_REGION" ] || export OS_REGION_NAME="$LAB_REGION"
  openstack "$@"
)

with_alice_token server list
```

- `OS_AUTH_TYPE=token` sélectionne l'authentification par jeton.
- `OS_TOKEN` contient le jeton existant, sans mot de passe disponible pour en demander un autre par authentification password.
- `OS_PROJECT_ID` indique sa portée projet.
- Le client peut effectuer une validation ou un échange de jeton nécessaire à sa session selon sa version. Pour contrôler strictement l'identifiant original, l'étape suivante valide directement celui du fichier auprès de Keystone.

Dans le flux courant, le client présente un jeton à l'API Nova. Le middleware d'authentification le valide auprès de Keystone ou utilise son cache ; Nova évalue ensuite ses policies. Keystone ne démarre pas lui-même la VM.

## 15. Expiration, validation et révocation

### 15.1. Lire la durée sans supposer une valeur fixe

```bash
jq '.token | {issued_at,expires_at}' alice-dev.json
```

`issued_at` est la date d'émission, `expires_at` celle d'expiration. La durée est configurée côté Keystone ; ne pas supposer qu'elle vaut toujours une heure.

Un jeton expiré ne peut plus servir normalement. Un utilisateur encore autorisé peut demander un nouveau jeton avec ses identifiants. Un jeton n'est donc pas un mot de passe permanent.

### 15.2. Valider avec l'administrateur

```bash
openstack token issue -f value -c id > admin-token.txt
python3 token_lab.py validate alice-dev.json admin-token.txt \
  | jq '{http_status,token: (.token | {user,project,roles,expires_at})}'
```

- La première commande enregistre un jeton administrateur dans un fichier privé.
- `validate` envoie le jeton admin dans `X-Auth-Token` et celui d'Alice dans `X-Subject-Token`.
- Attendu : HTTP 200 et description du jeton d'Alice, si l'admin a la permission de validation.

### 15.3. Révoquer puis vérifier

```bash
python3 token_lab.py revoke alice-dev.json admin-token.txt
python3 token_lab.py validate alice-dev.json admin-token.txt
```

Attendu : HTTP 204 lors de la révocation ; puis jeton invalide, généralement HTTP 404 lors de la validation. Un 401/403 peut aussi signaler un problème avec le jeton ou les droits de l'acteur admin : lire le message.

```bash
os_as alice lab-acme project "$DEV_ID" token issue -c project_id -c expires
```

Attendu : succès. La révocation du jeton ciblé ne retire ni le mot de passe d'Alice, ni son appartenance au groupe. Elle peut se reconnecter.

**À distinguer :** retirer une attribution change les droits ; révoquer invalide un jeton ; désactiver un utilisateur bloque son usage selon les mécanismes Keystone. Pour des jetons déjà émis et des appels à d'autres services, tenir compte des invalidations et caches : ne pas promettre un effet instantané identique sur toutes les API.

## 16. Retirer un membre de groupe : effet sur les nouveaux jetons

```bash
openstack group remove user "$DEVS_ID" "$ALICE_ID"

openstack role assignment list --user "$ALICE_ID" --project "$DEV_ID" --effective --names
os_as alice lab-acme project "$DEV_ID" token issue -c project_id -c expires
```

`group remove user` retire l'appartenance. Puisqu'Alice n'avait que ce chemin d'accès, la liste ne doit plus montrer de droit effectif sur dev et une nouvelle authentification pour ce projet doit être refusée.

Restaurer pour revenir au scénario nominal :

```bash
openstack group add user "$DEVS_ID" "$ALICE_ID"
os_as alice lab-acme project "$DEV_ID" token issue -c project_id -c expires
```

Attendu : succès. Cette étape démontre l'intérêt des groupes : gérer les membres sans réécrire chaque attribution de projet.

## 17. Bilan à faire expliquer par les participants

| Question | Réponse attendue |
|---|---|
| Alice existe mais n'a aucun rôle projet : son mot de passe peut-il être valide ? | Oui ; authentification sans portée possible, accès projet refusé |
| Le domaine d'Alice suffit-il à lui donner accès à dev ? | Non, il faut une attribution effective |
| Un rôle normal sur le parent descend-il aux enfants ? | Non |
| Un rôle hérité depuis le parent s'applique-t-il au parent lui-même ? | Non, il faut une attribution normale supplémentaire pour celui-ci |
| Bob peut-il utiliser un seul jeton de projet pour dev et prod ? | Il doit demander le jeton correspondant à chaque projet |
| David peut-il accéder à un projet d'un autre domaine ? | Oui, par attribution explicite |
| Un nouveau nom de rôle crée-t-il des permissions ? | Non, il faut une policy qui le reconnaît ou une implication |
| Le rôle métier impliquant reader est-il plus fin que reader ? | Non, il récupère les autorisations de reader dans ce contexte |
| Un reader de domaine est-il automatiquement reader de ses projets ? | Non ; distinguer attribution directe et héritée |
| Un jeton système est-il un jeton projet universel ? | Non |
| Le JSON du jeton est-il son identifiant secret ? | Non ; l'identifiant est délivré dans X-Subject-Token |
| Révoquer un jeton interdit-il définitivement la reconnexion ? | Non, il faut agir sur l'identité ou ses droits pour cela |

À l'état nominal final : Alice est membre de dev ; Bob lit dev et prod par héritage ; David lit prod via son groupe externe et son rôle métier impliquant reader ; Claire dispose de deux attributions de lecture distinctes, domaine et système.

## 18. Dépannage rapide

| Symptôme | Vérification utile |
|---|---|
| Mauvais utilisateur/projet dans un test | Utiliser `os_as` et inspecter le vrai JSON du jeton |
| 401 en demandant un jeton projet | Vérifier mot de passe, domaine utilisateur, portée, attributions et activation des objets |
| 403 sur une API après émission réussie | Vérifier policy de cette API, portée du jeton et rôles présents |
| 503 ou connexion refusée | Vérifier état du service, point d'entrée et réseau ; ce n'est pas un refus RBAC |
| Tableau de VM vide | Peut être normal : aucune VM dans ce projet |
| Groupe attribué mais utilisateur sans accès | Vérifier l'appartenance avec `user list --group`, puis `--effective` |
| Parent accessible mais enfant refusé | Vérifier la présence de `--inherited` sur l'attribution source |
| Nouveau rôle sans effet attendu | Inspecter les rôles du jeton et les implications ; créer le rôle seul ne suffit pas |
| Certificat non reconnu | Fournir la bonne autorité via `OS_CACERT` avant l'étape 3.2 ; ne pas désactiver TLS |
| Token révoqué mais accès temporairement encore possible ailleurs | Vérifier les caches middleware et refaire une validation directe Keystone |
| Variable `DEV_ID` vide après réouverture du terminal | Recharger les accès et récupérer les ID ; les variables Bash ne persistent pas entre terminaux |

Les commandes `help` donnent les options du client réellement installé :

```bash
openstack help role add
openstack help role assignment list
openstack help project create
openstack help token issue
```

## 19. Nettoyage optionnel, limité aux objets de ce TP

Exécuter uniquement après la démonstration, dans le terminal administrateur où les variables ID existent. Le TP n'a créé aucune VM, aucun volume ni aucun réseau. Si des ressources ont été ajoutées dans les projets, les supprimer d'abord avec leur service ; supprimer un projet Keystone ne nettoie pas automatiquement toutes ses ressources.

```bash
openstack role remove --user "$CLAIRE_ID" --system all reader
openstack role remove --user "$CLAIRE_ID" --domain "$ACME_ID" reader
openstack role remove --group "$OPS_ID" --project "$APP_ID" --inherited reader
openstack role remove --group "$DEVS_ID" --project "$DEV_ID" member
openstack role remove --group "$AUDIT_GROUP_ID" --project "$PROD_ID" lab-auditeur-securite

openstack implied role delete lab-auditeur-securite --implied-role reader
openstack role delete lab-auditeur-securite

openstack group delete "$DEVS_ID" "$OPS_ID" "$AUDIT_GROUP_ID"
openstack user delete "$ALICE_ID" "$BOB_ID" "$CLAIRE_ID" "$DAVID_ID"

openstack project set --disable "$DEV_ID"
openstack project set --disable "$PROD_ID"
openstack project delete "$DEV_ID" "$PROD_ID"
openstack project set --disable "$APP_ID"
openstack project delete "$APP_ID"

openstack domain set --disable "$ACME_ID"
openstack domain set --disable "$AUDIT_ID"
openstack domain delete "$ACME_ID" "$AUDIT_ID"
```

Ordre : retirer les attributions et l'implication, supprimer groupes/utilisateurs, supprimer enfants puis parent, désactiver et supprimer les domaines. La suppression d'un groupe retire également ses appartenances.

Supprimer les fichiers secrets du dossier de travail :

```bash
rm -f alice-sans-portee.json alice-dev.json alice-dev-echange.json \
  claire-domaine.json claire-systeme.json david-prod.json admin-token.txt
unset -f os_as with_alice_token
unset LAB_AUTH_URL LAB_CACERT LAB_REGION
unset ACME_ID AUDIT_ID APP_ID DEV_ID PROD_ID ALICE_ID BOB_ID CLAIRE_ID DAVID_ID
unset DEVS_ID OPS_ID AUDIT_GROUP_ID
```

`rm -f` supprime uniquement ces fichiers nommés. `unset -f` retire les fonctions ; `unset` retire les variables du TP. Le fichier `token_lab.py` peut être conservé : il ne contient aucun identifiant secret.

## 20. Références officielles

Consultées le 20 octobre 2026. Les pages `latest` peuvent décrire une version plus récente que celle de votre cloud : les policies réellement déployées et l'aide du client installé restent déterminantes.

- [Concepts Identity : domaines, projets, utilisateurs, groupes et rôles](https://docs.openstack.org/keystone/latest/admin/identity-concepts.html)
- [Jetons Keystone : portées et fournisseurs](https://docs.openstack.org/keystone/latest/admin/tokens-overview.html)
- [Rôles par défaut et implications](https://docs.openstack.org/keystone/latest/admin/service-api-protection.html)
- [Référence API Identity v3 : authentification, validation, révocation et attributions](https://docs.openstack.org/api-ref/identity/v3/index.html)
- [Commandes Identity v3 du client : project, user, group, role, implied role, token](https://docs.openstack.org/python-openstackclient/latest/cli/command-objects/identity/v3/index.html)
- [FAQ Fernet : fonctionnement et validation](https://docs.openstack.org/keystone/latest/admin/fernet-token-faq.html)
- [Canonical OpenStack : utiliser le client OpenStack](https://canonical-openstack.readthedocs-hosted.com/en/latest/how-to/misc/using-the-openstack-cli/)

Ce support propose un scénario original de TP fondé sur ces interfaces officielles. Les commandes sont destinées à être exécutées séquentiellement ; les refus explicitement annoncés font partie de la démonstration.
