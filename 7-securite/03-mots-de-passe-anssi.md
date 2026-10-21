# Démo 3 : une politique de mots de passe conforme au référentiel ANSSI

> **Statut : rejouée sur le lab le 18 octobre 2026.** Les valeurs reprennent le support 11 (« Recommandations relatives à l’authentification multifacteur et aux mots de passe », ANSSI, v2.0, 8 octobre 2021). Les réglages de Keycloak ont été appliqués par son API, avec les valeurs des tableaux ; les sorties citées sont celles de ce jour. Le second facteur des comptes locaux de Keystone (3.4) est impossible sur ce lab : la partie TOTP n’a pas été jouée.

## Objectif

Traduire le guide de l’ANSSI en règles, les appliquer **là où elles peuvent l’être** sur un cloud Sunbeam, les vérifier par l’essai, et mesurer leur **impact sur les comptes de service**, qui ne doivent jamais être bloqués.

## 3.1 Le référentiel, traduit en règles

| Thème | Recommandation ANSSI | Règle proposée pour la journée |
|---|---|---|
| Longueur | Sensibilité moyenne à forte : 12 à 14 caractères ; forte à très forte : 15 et plus | **12** caractères pour un compte de travail, **15** pour un compte à privilèges ; plus de 20 pour un mot de passe non mémorisé (compte technique, gestionnaire de mots de passe) |
| Longueur maximale | R22 : ne pas en imposer, pour permettre les phrases de passe | Aucune, ou au moins 128 |
| Complexité | R23 : règles de complexité, avec le plus large jeu de caractères | Tous caractères autorisés ; au plus deux classes imposées, la longueur fait le reste |
| Historique | R27 : interdire la réutilisation des derniers mots de passe | **5** derniers interdits |
| Listes interdites | R27 : refuser les mots de passe courants ou compromis, l’identifiant, le nom de l’entreprise | Refus de l’identifiant et de l’adresse électronique ; liste de mots de passe compromis |
| Expiration, comptes ordinaires | R24 : pas d’expiration par défaut si la robustesse est imposée | **Aucune** |
| Expiration, comptes à privilèges | R25 : imposer une expiration, par exemple entre 1 et 3 ans | **365 jours** |
| Compromission | R26 : renouveler sans délai, ou désactiver | Procédure de réinitialisation forcée |
| Verrouillage | R10 : limiter les tentatives, blocage **temporaire** de quelques secondes ou minutes, linéaire ou exponentiel | **5** échecs, blocage croissant, **15 minutes** au plus ; pas de blocage définitif |
| Premier usage | R30 : changement imposé après création ou réinitialisation par l’administration | Mot de passe **temporaire** à la création |
| Multifacteur | R1 : privilégier deux facteurs de catégories différentes | Second facteur pour les comptes à privilèges |

Ces valeurs sont celles du support, à valider par l’analyse de risque de l’entreprise (R3).

## 3.2 Où s’applique la politique sur Sunbeam ?

C’est la question décisive de la démo. Il y a **trois** sortes de comptes :

| Comptes | Exemples sur le lab | Qui les authentifie | Où mettre la politique |
|---|---|---|---|
| **Personnes** | `alice` (démo 2) | Keycloak, par fédération | **Keycloak** |
| **Comptes locaux de Keystone** | `admin`, `demo` | Keystone | Options `[security_compliance]` de Keystone… non exposées par Sunbeam (3.4) |
| **Comptes de service** | `svc_nova-F8OChi`, `svc_neutron-Jbci5R`, `horizon`… | Keystone | **Aucune** politique de mot de passe : une gestion de secrets (démo 4) |

**Règle d’architecture du support :** la politique des **personnes** se règle à **un seul endroit**, l’autorité d’authentification. Keystone n’applique sa propre politique qu’aux quelques comptes locaux qui lui restent.

## 3.3 Appliquer la politique aux personnes, dans Keycloak

Console d’administration : **https://sso.lab.test:8443/admin/**, compte `kcadmin`, realm **lab** (démo 2, étape 1).

### Complexité, longueur, historique, expiration

**Authentication → Policies → Password policy → Add policy**, puis ajouter une à une :

| Règle Keycloak (*Add policy*) | Valeur | Recommandation |
|---|---|---|
| *Minimum length* | `12` | Longueur |
| *Maximum length* | `128` | R22 |
| *Not username* | — | R27 |
| *Not email* | — | R27 |
| *Not recently used* | `5` | R27 |
| *Uppercase characters* | `1` | R23 (une classe) |
| *Digits* | `1` | R23 (deuxième classe) |

**Save**. Pas d’*Expire password* pour les comptes ordinaires (R24). ⚠ La politique d’un realm s’applique à **tous** ses comptes : pour imposer 15 caractères et une expiration aux comptes à privilèges (R25), les placer dans un realm distinct, ou imposer un second facteur à leur groupe.

**Liste de mots de passe compromis** (*Password blacklist*) : la règle attend un fichier de mots de passe interdits présent dans le conteneur Keycloak (⚠ **à vérifier** dans la documentation de Keycloak 26 : emplacement du fichier et redémarrage nécessaire). Hors démo, sauf si le temps le permet.

### Verrouillage après échecs

**Realm settings → Security defenses → Brute force detection** :

| Champ | Valeur | Signification |
|---|---|---|
| *Brute Force Mode* | *Lockout temporarily* | Blocage **temporaire** (R10), jamais définitif |
| *Max login failures* | `5` | Blocage après 5 échecs consécutifs |
| *Wait increment* | `1 minute` | Durée du premier blocage, augmentée à chaque nouvel échec : blocage croissant |
| *Max wait* | `15 minutes` | Plafond du blocage |
| *Failure reset time* | `12 hours` | Le compteur d’échecs revient à zéro après cette durée sans échec |

**Save**.

Laisser les deux champs *Quick login check milliseconds* (`1000`) et *Minimum quick login wait* (`1 minute`) à leur valeur par défaut : deux échecs à moins d’une seconde d’intervalle (un robot) bloquent aussitôt une minute.

**Avant la démo, sur le lab** (relevé le 18 octobre) : aucune politique (*Password policy* vide), *Brute force detection* désactivée, événements non enregistrés. Tout ce qui suit est donc ajouté par la démo.

### Vérifier par l’essai

**1. Un mot de passe trop court est refusé.** **Users → alice → Credentials → Reset password** : essayer `Court1`, puis `PhraseSansChif` (14 caractères, sans chiffre).

✅ **Attendu** (18 octobre) : deux refus, `Invalid password: minimum length 12.` puis `Invalid password: must contain at least 1 numerical digits.` Le mot de passe actuel d’`alice` n’est pas touché : une politique s’applique au **prochain changement**, pas aux mots de passe existants.

**2. Le verrouillage fonctionne.** Le test se fait sur la page de connexion de Keycloak, par la fédération : dans une fenêtre privée, l’adresse de la démo 2, étape 7a (ou, sur Lab-Sunbeam, `python3 ~/test-sso-saml.py alice`). Saisir 5 fois un mauvais mot de passe pour `alice`, puis le bon.

✅ **Attendu** (18 octobre, avec le script) :

```text
essai 1 : 2. Keycloak refuse : Invalid username or password.
…
essai 5 : 2. Keycloak refuse : Invalid username or password.
6e essai, bon mot de passe :
2. Keycloak refuse : Invalid username or password.
apres 65 s, bon mot de passe :
3. Réponse de Keystone : 201
```

**Comment le lire :** au 6ᵉ essai, le **bon** mot de passe est refusé, avec le **même** message que les autres. Keycloak ne dit pas que le compte est bloqué : un attaquant n’apprend rien. Une minute plus tard (*Wait increment*), la connexion repasse.

**3. Le verrouillage est tracé.** **Realm settings → Events → User events settings** : activer *Save events*, **Save** (à faire **avant** le test 2). Puis **Events** (menu de gauche).

✅ **Attendu** (18 octobre, du plus récent au plus ancien) :

| Heure | Type | Erreur |
|---|---|---|
| 10:12:18 | `LOGIN` | |
| 10:11:10 | `LOGIN_ERROR` | `user_temporarily_disabled` |
| 10:11:05 | `USER_DISABLED_BY_TEMPORARY_LOCKOUT` | |
| 10:11:05 | `LOGIN_ERROR` | `invalid_user_credentials` |
| 10:10:44 à 10:11:00 | `LOGIN_ERROR` (4 lignes) | `invalid_user_credentials` |

Chaque ligne donne aussi l’utilisateur, l’adresse IP d’origine (`192.168.56.10` pour le script lancé sur Lab-Sunbeam) et le client (`urn:saml2:keycloak`, Keystone). Ce que l’utilisateur ne voit pas, l’administrateur le lit ici : c’est une source de la démo 6.

⚠ **Le revers du verrouillage** (support, R10) : un attaquant qui connaît un identifiant peut bloquer son titulaire en multipliant les échecs. D’où un blocage **temporaire** et **croissant**, et non définitif.

## 3.4 Les comptes locaux de Keystone

### Le constat sur le lab

```bash
juju config -m openstack keystone | grep -E "^  [a-z-]+:$"
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- grep -c "^\[security_compliance\]" /etc/keystone/keystone.conf
```

✅ **Attendu** (18 octobre) : les options du charm Keystone (`catalog-cache-expiration`, `debug`, `dogpile-cache-expiration`, `enable-telemetry-notifications`, `identity-backend`, `log-level`, `region`, `saml-x509-keypair`) : **aucune** ne porte sur les mots de passe. Puis `0` et `command terminated with exit code 1` : la section `[security_compliance]` est absente de `keystone.conf` (`grep -c` compte 0 ligne, et le signale par son code de sortie).

**Comment le lire :** Keystone **sait** appliquer une politique (verrouillage, expiration, historique, complexité), mais le charm de Sunbeam ne permet pas de la régler.

### Ce que serait la configuration, si le charm l’exposait

Pour la culture, et pour le jour où une version du charm l’exposera (support, module 11) :

```ini
[security_compliance]
lockout_failure_attempts = 5
lockout_duration = 900
unique_last_password_count = 5
minimum_password_age = 1
password_regex = ^.{15,256}$
password_regex_description = Au moins 15 caractères.
password_expires_days = 365
change_password_upon_first_use = True
disable_user_account_days_inactive = 90
```

| Option | Effet | Recommandation |
|---|---|---|
| `lockout_failure_attempts`, `lockout_duration` | 5 échecs, puis 900 s (15 min) de blocage ; sans durée, blocage jusqu’à réactivation | R10 |
| `unique_last_password_count`, `minimum_password_age` | 5 derniers interdits ; 1 jour minimum entre deux changements, pour ne pas épuiser l’historique d’un coup | R27 |
| `password_regex` | Au moins 15 caractères (compte à privilèges) ; borne haute large, 256, pour laisser passer les phrases de passe | Longueur, R22 |
| `password_expires_days` | Expiration à 365 jours | R25 |
| `change_password_upon_first_use` | Changement imposé après création par l’administration | R30 |
| `disable_user_account_days_inactive` | Désactivation après 90 jours d’inactivité | Hygiène des comptes |

⚠ **Ne pas l’écrire à la main dans le pod `keystone-0`** : le charm réécrit sa configuration, la modification disparaîtrait au prochain redémarrage ou à la prochaine reconfiguration (guide `4-juju-cli/DEMOS-PANNES.md`, partie 5).

⚠ Ces options sont **globales** : elles s’appliqueraient aussi aux comptes de service. D’où l’étape 3.5.

### Ce qu’on fait à la place

| Mesure | Comment |
|---|---|
| Réduire les comptes locaux | Les personnes passent par Keycloak (démo 2) ; il ne reste que `admin` et les comptes de service |
| `admin` = compte de **secours** | Mot de passe généré, plus de 20 caractères, rangé dans un coffre ; usage tracé (démo 6) |
| Second facteur sur le compte de secours | Impossible dans Keystone sur ce lab (méthode `totp` absente, ci-dessous) : compenser par l’accès restreint à Lab-Sunbeam et la traçabilité |
| Supprimer ou désactiver les comptes de démonstration | `demo` n’a pas sa place en production |

### Second facteur sur un compte local (TOTP)

Démonstration sur un compte de test, **jamais** directement sur `admin` : une erreur bloquerait l’accès d’urgence.

```bash
source ~/admin-openrc
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- sh -c 'sed -n "/^\[auth\]/,/^\[/p" /etc/keystone/keystone.conf'
```

✅ **Attendu** (18 octobre) :

```text
[auth]
methods = external,password,token,oauth1,openid,saml2,mapped,application_credential
```

**Comment le lire :** la méthode `totp` n’y figure **pas**. Keystone refusera donc tout code à 6 chiffres, et le charm ne permet pas de l’ajouter. **Sur ce lab, le second facteur des comptes locaux de Keystone est impossible : on s’arrête ici.** Le second facteur se met dans l’autorité d’authentification (Keycloak : **Authentication → Required actions → Configure OTP**), pour les personnes fédérées.

Pour la culture, sur un Keystone dont `methods` contiendrait `totp`, la procédure serait la suivante (non jouée sur le lab) :

```bash
read -rsp "Mot de passe du compte de test : " LAB_PW; echo
openstack user create lab-sec-secours --domain admin_domain --password "$LAB_PW"
openstack role add --user lab-sec-secours --user-domain admin_domain --project admin --project-domain admin_domain reader
SECRET=$(head -c 20 /dev/urandom | base32 | tr -d '=')
openstack credential create --type totp lab-sec-secours "$SECRET"
openstack user set lab-sec-secours --domain admin_domain \
  --enable-multi-factor-auth --multi-factor-auth-rule password,totp
echo "otpauth://totp/OpenStack:lab-sec-secours?secret=$SECRET&issuer=OpenStack"
```

| Ligne | Rôle |
|---|---|
| `SECRET=…` | 20 octets aléatoires, en base32 : le secret partagé du TOTP |
| `credential create --type totp` | Enregistre ce secret comme justificatif du compte |
| `user set … --multi-factor-auth-rule password,totp` | Impose **mot de passe + code à 6 chiffres** pour obtenir un jeton |
| `otpauth://…` | À transformer en QR code (`qrencode -t ansiutf8 "…"`, si installé) et à scanner avec une application d’authentification |

Se connecter avec les deux facteurs, dans une **nouvelle** session :

```bash
export OS_AUTH_URL=$(grep -oP "OS_AUTH_URL=\K.*" ~/admin-openrc)
export OS_AUTH_TYPE=v3multifactor OS_AUTH_METHODS=v3password,v3totp
export OS_USERNAME=lab-sec-secours OS_USER_DOMAIN_NAME=admin_domain
export OS_PROJECT_NAME=admin OS_PROJECT_DOMAIN_NAME=admin_domain OS_IDENTITY_API_VERSION=3
read -rsp "Mot de passe : " OS_PASSWORD; echo; export OS_PASSWORD
read -rp "Code a 6 chiffres : " OS_PASSCODE; export OS_PASSCODE
openstack token issue -c expires
```

✅ **Attendu :** un jeton avec le bon code ; avec le mot de passe seul (`OS_AUTH_TYPE=password`), un refus `401` indiquant qu’une autre méthode est exigée.

## 3.5 L’impact sur les comptes de service

**Le risque.** Les comptes de service (`svc_nova-…`, `svc_neutron-…`) s’authentifient en permanence auprès de Keystone, avec un mot de passe stocké par Juju. Si une politique de verrouillage ou d’expiration s’appliquait à eux :

| Politique | Effet sur un compte de service |
|---|---|
| Verrouillage après 5 échecs | Un service mal configuré (ou un attaquant qui connaît son nom) le bloque : **plus aucun** jeton validé, `503` sur tout le cloud |
| Expiration à 365 jours | Un an après l’installation, les services ne s’authentifient plus : panne générale à date fixe |
| Changement au premier usage | Le service ne sait pas changer son mot de passe : il ne démarre jamais |

**La parade de Keystone : les exemptions par compte.** Chaque compte peut être exempté d’une règle :

Le client `openstack` 7.5.0 n’affiche pas ces options (`openstack user show … -c options` répond `No recognized column names in ['options']`, constaté le 18 octobre). On les lit dans l’API de Keystone :

```bash
source ~/admin-openrc
T=$(openstack token issue -f value -c id)
SD=$(openstack domain show service_domain -f value -c id)
curl -s --cacert "$OS_CACERT" -H "X-Auth-Token: $T" "https://cloud.lab.test/openstack-keystone/v3/users?domain_id=$SD" \
  | python3 -c 'import sys,json; [print(u["name"].ljust(52), "options =", u.get("options"), "| password_expires_at =", u.get("password_expires_at")) for u in json.load(sys.stdin)["users"]]'
openstack token revoke "$T"
```

**La commande, mot par mot :** un jeton administrateur (`T`), l’identifiant du domaine des services (`SD`), puis la liste des utilisateurs de ce domaine demandée directement à l’API (`/v3/users?domain_id=…`), dont on affiche le nom, les options et la date d’expiration du mot de passe. Le jeton est révoqué à la fin.

✅ **Attendu** (18 octobre) :

```text
svc_neutron-Jbci5R                                   options = {} | password_expires_at = None
svc_cinder-Pu4Ylk                                    options = {} | password_expires_at = None
svc_nova-F8OChi                                      options = {} | password_expires_at = None
svc_glance-6hmlyS                                    options = {} | password_expires_at = None
svc_placement-RsdQHG                                 options = {} | password_expires_at = None
horizon                                              options = {} | password_expires_at = None
svc_remote_1da729f5ab1d44c6886524409d1f415d-vIAaQ1   options = {} | password_expires_at = None
cinder-volume                                        options = {} | password_expires_at = None
openstack-hypervisor                                 options = {} | password_expires_at = None
```

**Comment le lire :** `options = {}` : aucune exemption ; `password_expires_at = None` : pas d’expiration. Sans conséquence **tant qu’aucune politique n’est active** (cas de ce lab).

Avant d’activer une politique, on exempterait chaque compte de service :

```bash
openstack user set svc_nova-F8OChi --domain service_domain \
  --ignore-lockout-failure-attempts --ignore-password-expiry --ignore-change-password-upon-first-use
```

🔁 **À adapter :** le suffixe des comptes de service change à chaque installation (`openstack user list --domain service_domain`). ⚠ Sur ce lab, **ne pas** le lancer : inutile sans politique active, et ces comptes appartiennent aux charms.

**La vraie réponse : ces comptes ne relèvent pas d’une politique de mots de passe**, mais d’une **gestion de secrets** : mots de passe longs générés par Juju, jamais saisis par une personne, rangés dans les secrets Juju, renouvelés automatiquement. C’est la démo 4.

## Nettoyage

Rien à supprimer côté OpenStack : le compte de test `lab-sec-secours` n’est créé que si le TOTP est possible (3.4). S’il l’a été : `openstack user delete lab-sec-secours --domain admin_domain`.

Dans Keycloak, garder la politique pour la suite de la journée, ou revenir à l’état d’avant la démo : **Authentication → Policies → Password policy** (supprimer chaque règle), **Realm settings → Security defenses** (*Brute Force Mode* : *Disabled*), **Realm settings → Events → User events settings** (*Save events* désactivé).

## À retenir

- Le guide de l’ANSSI de 2021 privilégie la **longueur** à la complexité, renonce à l’**expiration systématique** des comptes ordinaires, et impose un **verrouillage temporaire** et le **multifacteur** pour les comptes sensibles.
- Sur Sunbeam, la politique des **personnes** s’applique dans l’**autorité d’authentification** (Keycloak) : le charm Keystone n’expose pas `[security_compliance]`.
- Les **comptes locaux** restants se réduisent au strict minimum, protégés par la longueur, un coffre et le second facteur.
- Les **comptes de service** ne doivent jamais être verrouillés ni expirer : exemptions si une politique est active, et surtout gestion de secrets (démo 4).
