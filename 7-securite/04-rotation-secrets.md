# Démo 4 : rotation des secrets et des clés de jetons

> **Statut : rejouée sur le lab le 18 octobre 2026**, rotation des clés Fernet observée en direct. Non joués : l’action `regenerate-password` sur `admin` (4.6, raison donnée sur place). Support : modules 11 et 12.

## Objectif

Savoir **quels** secrets protègent le cloud, **lesquels tournent tout seuls** et à quel rythme, le **vérifier**, et savoir quoi faire pour ceux qui ne tournent pas. C’est la suite logique de la démo 3 : les comptes de service ne relèvent pas d’une politique de mots de passe, mais d’une **gestion de secrets**.

## 4.1 Comprendre : quels secrets, pourquoi les faire tourner

| Secret | Ce qu’il protège | Si on le vole | Rotation |
|---|---|---|---|
| **Clés Fernet** de Keystone | Le chiffrement des jetons | On fabrique des jetons valides pour n’importe qui | Automatique, par le charm |
| **Clés de credentials** de Keystone | Le chiffrement des justificatifs stockés (secrets TOTP, clés EC2) | On déchiffre ces justificatifs | Automatique, par le charm |
| **Mots de passe des comptes de service** (`svc_nova-…`) | L’accès des services à Keystone | On agit comme un service, avec le rôle `admin` sur `services` | Automatique, par le charm |
| **Mots de passe des bases** (MySQL) et de RabbitMQ | Les données et la messagerie du cloud | Accès direct aux données de tous les projets | Pas de rotation automatique observée |
| **Mot de passe d’`admin`** | L’administration du cloud | Tout | Manuelle, avec précaution (4.6) |
| **Identifiants d’application** | Les scripts des utilisateurs | Les droits de leur propriétaire sur un projet | Par l’utilisateur, avec une expiration (4.7) |

**Pourquoi tourner :** un secret qui tourne limite la **durée** pendant laquelle un vol reste exploitable, sans qu’on ait besoin de détecter le vol. C’est aussi ce que demande la recommandation R26 de l’ANSSI en cas de compromission : renouveler sans délai.

## 4.2 Inventaire : les secrets gérés par Juju

**À quoi ça sert :** sur Sunbeam, les secrets des services ne sont pas dans des fichiers épars : ils sont rangés et distribués par **Juju** (guide `4-juju-cli/`, démo 7). On en dresse la liste, avec leur politique de rotation.

```bash
sunbeam utils juju-login
juju secrets -m openstack | head -3
juju secrets -m openstack --format json | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
print('total', len(d))
c = collections.Counter((v.get('owner'), v.get('rotation', 'never')) for v in d.values())
for (owner, rot), n in sorted(c.items()): print(f'{owner:32} {rot:8} {n}')
"
```

**La commande, mot par mot :** `juju secrets -m openstack` liste les secrets du modèle ; `--format json` les donne sous une forme lisible par un script ; le petit programme Python les **compte** par propriétaire et par politique de rotation.

✅ **Attendu** (18 octobre, extrait) :

```text
total 66
<model>                          never    1
certificate-authority            never    1
keystone                         daily    1
keystone                         monthly  8
keystone                         never    6
mysql                            never    13
neutron/0                        never    7
ovn-central/0                    never    7
ovn-relay/0                      never    8
…
```

**Comment le lire :**

| Colonne `Rotation` | Signification |
|---|---|
| `never` | Le charm ne renouvelle pas ce secret de lui-même |
| `daily`, `monthly` | Le charm le renouvelle à cette fréquence ; Juju le réveille à l’échéance |

Le seul propriétaire qui fait tourner ses secrets est **`keystone`**. Le `<model>` est le secret de la paire de clés SAML (démo 2, étape 2). Le nombre total varie avec les fonctionnalités activées.

Le détail des secrets de Keystone, **sans** leur contenu :

```bash
juju secrets -m openstack --format json | python3 -c '
import sys, json
for i, v in sorted(json.load(sys.stdin).items(), key=lambda x: x[1].get("label", "")):
    if v.get("owner") == "keystone":
        print(v.get("label", "-").ljust(34), v.get("rotation", "never").ljust(8), "rev", v.get("revision"),
              " cree", v.get("created", "")[:10], " prochaine", v.get("rotates", "-")[:16])
'
```

✅ **Attendu** (18 octobre) :

```text
credential-keys                    monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials__charm-keystone-admin  never    rev 1  cree 2026-10-09  prochaine -
credentials_admin                  never    rev 1  cree 2026-10-09  prochaine -
credentials_cinder-volume          never    rev 1  cree 2026-10-09  prochaine -
credentials_horizon                never    rev 1  cree 2026-10-09  prochaine -
credentials_openstack-hypervisor   never    rev 1  cree 2026-10-09  prochaine -
credentials_svc_cinder             monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials_svc_glance             monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials_svc_heat               monthly  rev 1  cree 2026-10-16  prochaine 2026-11-16T14:36
credentials_svc_neutron            monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials_svc_nova               monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials_svc_placement          monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T10:41
credentials_svc_remote_1da7…       monthly  rev 1  cree 2026-10-09  prochaine 2026-11-09T11:34
fernet-keys                        daily    rev 9  cree 2026-10-09  prochaine 2026-10-18T10:41
oidc-crypto-passphrase             never    rev 1  cree 2026-10-09  prochaine -
```

**Comment le lire :**

| Secret | Ce qu’on en déduit |
|---|---|
| `fernet-keys`, `daily`, révision 9 | Les clés de jetons, renouvelées chaque jour : 8 rotations depuis l’installation du 9 octobre. La prochaine est indiquée par `prochaine` |
| `credential-keys`, `monthly` | Les clés qui chiffrent les justificatifs stockés : première rotation un mois après l’installation |
| `credentials_svc_<service>`, `monthly` | Le mot de passe de chaque compte de service (`svc_nova-…`), renouvelé chaque mois ; révision 1 : pas encore renouvelé |
| `credentials_admin`, `credentials_horizon`, `credentials_cinder-volume`, `credentials_openstack-hypervisor`, `never` | Comptes **sans** rotation automatique : l’administrateur, et les comptes de Horizon et des services de la machine |
| `credentials_svc_heat` | Reste d’un compte de Heat, activé puis retiré le 16 octobre (guide `3-sunbeam-cli/`) : le secret survit au service |

## 4.3 Les clés de jetons (Fernet)

### Observer les clés

```bash
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- sh -c '
  grep -A2 "^\[fernet_tokens\]" /etc/keystone/keystone.conf
  ls -l --time-style=+%F_%H:%M /etc/keystone/fernet-keys/ /etc/keystone/credential-keys/ 2>/dev/null'
```

✅ **Attendu** (relevé le 18 octobre à 10:14) :

```text
[fernet_tokens]
max_active_keys = 4

/etc/keystone/credential-keys/:
-rw------- 1 keystone keystone    44 2026-10-09_10:40 0
-rw------- 1 keystone keystone    44 2026-10-09_10:40 1
drwx------ 2 root     root     16384 2026-10-09_10:35 lost+found

/etc/keystone/fernet-keys/:
-rw------- 1 keystone keystone    44 2026-10-17_17:10 0
-rw------- 1 keystone keystone    44 2026-10-15_14:10 7
-rw------- 1 keystone keystone    44 2026-10-15_14:10 8
-rw------- 1 keystone keystone    44 2026-10-16_12:45 9
drwx------ 2 root     root     16384 2026-10-09_10:35 lost+found
```

**Comment le lire :** Keystone tient **4** clés de jetons au plus (`max_active_keys`), qui jouent trois rôles :

| Clé | Rôle |
|---|---|
| `0` | **En attente** (*staged*) : la prochaine clé primaire. Elle est déjà connue de tous, pour qu’aucun jeton ne soit refusé au moment de la bascule |
| La plus grande, `9` | **Primaire** : elle chiffre les **nouveaux** jetons |
| Les autres, `7` et `8` | **Secondaires** : elles ne chiffrent plus, mais **déchiffrent** encore les jetons émis avant la dernière rotation |

Les `credential-keys` (`0` et `1`) chiffrent les justificatifs stockés : elles datent de l’installation, leur rotation est mensuelle (4.2). `lost+found` est un répertoire du système de fichiers : chaque répertoire de clés est un volume à part.

**Une rotation :** la clé `0` devient primaire sous un nouveau numéro (`10`), une nouvelle clé `0` est créée, et la plus ancienne secondaire (`7`) est détruite.

### Pourquoi une rotation ne casse pas les jetons en cours

Un jeton est valable **une heure** (`expiration = 3600`, TP 1 des `labs-iam/`, § 1.4.7). Avec 4 clés et une rotation par jour, une clé reste secondaire pendant deux rotations après avoir été primaire : un jeton reste donc déchiffrable environ **deux jours** après sa création, bien plus que sa durée de vie.

⚠ **Piège :** `allow_expired_window = 169200` (47 heures, même paragraphe du TP 1) permet aux services de faire accepter un jeton **expiré** pour terminer une opération longue. Si les clés tournaient trop vite, ces jetons deviendraient indéchiffrables. Le réglage du nombre de clés et de la fréquence se fait **ensemble**.

### Voir une rotation

Le charm n’a **pas** d’action de rotation (constaté : `juju actions -m openstack keystone` liste `add-ca-certs`, `get-admin-account`, `get-admin-password`, `get-service-account`, `list-ca-certs`, `regenerate-password`, `remove-ca-certs`). C’est Juju qui déclenche la rotation, à l’heure indiquée par `prochaine` dans l’inventaire de 4.2 (pour `fernet-keys`). On garde donc la liste des clés **avant** cette heure, et on compare **après** :

```bash
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- ls /etc/keystone/fernet-keys/ > ~/lab-sec-cles-j1.txt
```

Après l’heure prévue (le lendemain au plus tard) :

```bash
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- ls -l --time-style=+%F_%H:%M /etc/keystone/fernet-keys/
sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- ls /etc/keystone/fernet-keys/ | diff ~/lab-sec-cles-j1.txt -
source ~/admin-openrc; openstack token issue -c expires
```

✅ **Attendu** (18 octobre, rotation prévue à 10:41:50, relevé à 10:42) :

```text
-rw------- 1 keystone keystone    44 2026-10-18_10:41 0
-rw------- 1 keystone keystone    44 2026-10-17_17:10 10
-rw------- 1 keystone keystone    44 2026-10-15_14:10 8
-rw------- 1 keystone keystone    44 2026-10-16_12:45 9
2c2
< 7
---
> 10
```

**Comment le lire :** exactement la rotation décrite plus haut. La nouvelle primaire `10` porte la date de l’ancienne `0` (17 octobre, 17:10) : c’est le **même** fichier, renommé. Une nouvelle `0` date de 10:41, et `7` a disparu. Le jeton est délivré normalement : aucune interruption. Dans l’inventaire de 4.2, `fernet-keys` est passé en révision 10, prochaine rotation le lendemain à la même heure.

Si la VM était éteinte ou en veille à l’heure prévue, la rotation a lieu au réveil : constaté sur le lab, où la clé `0` du 17 octobre n’avait pas tourné le 18 au matin.

## 4.4 Les mots de passe des comptes de service

**À quoi ça sert :** montrer que ces mots de passe ne sont **jamais** saisis par une personne, et qu’ils tournent.

L’inventaire de 4.2 les montre : un secret `credentials_svc_<service>` par compte de service, en `monthly`. Et dans Keystone :

```bash
source ~/admin-openrc
openstack user list --domain service_domain
```

✅ **Attendu** (18 octobre) : `svc_neutron-Jbci5R`, `svc_cinder-Pu4Ylk`, `svc_nova-F8OChi`, `svc_glance-6hmlyS`, `svc_placement-RsdQHG`, `svc_remote_…`, et trois comptes **sans** suffixe : `horizon`, `cinder-volume`, `openstack-hypervisor` (leurs secrets sont en `never`, 4.2).

**Comment le lire :** chaque mois, le charm Keystone génère un nouveau mot de passe, le met dans Keystone, publie la nouvelle révision du secret, et Juju prévient le service concerné, qui l’utilise aussitôt. Personne ne voit ce mot de passe. C’est la « gestion de secrets » de la démo 3 : génération, stockage, rotation.

**Suivre une rotation dans les journaux du charm :**

```bash
juju debug-log -m openstack --replay --no-tail --include keystone/0 | grep -E "secret-rotate|Rotating|secret-remove" | tail -5
```

✅ **Attendu** (18 octobre ; la rotation mensuelle n’avait pas encore eu lieu, les lignes sont celles d’une rotation des clés Fernet) :

```text
unit-keystone-0: 12:44:19 INFO unit.keystone/0.juju-log secret-rotate event: Rotating the fernet keys
unit-keystone-0: 12:45:28 INFO juju.worker.uniter.operation ran "secret-rotate" hook (via hook dispatching script: dispatch)
unit-keystone-0: 12:48:23 INFO unit.keystone/0.juju-log secret-remove triggered for label fernet-keys
unit-keystone-0: 12:48:26 INFO juju.worker.uniter.operation ran "secret-remove" hook (via hook dispatching script: dispatch)
```

**Comment le lire :** Juju réveille le charm (`secret-rotate`) à l’échéance ; le charm fait tourner les clés et publie une nouvelle révision du secret ; quand plus personne n’utilise l’ancienne révision, Juju la supprime (`secret-remove`). Les lignes de `debug-log` n’ont que l’**heure**, pas la date : ces lignes-ci datent du 16 octobre (12:45, comme la date du fichier de la clé `9`).

⚠ **Longueur des mots de passe générés.** Lu dans le code du charm (`src/charm.py`, `pwgen.pwgen(12)`) : le charm génère les mots de passe de **tous** ses comptes sur **12 caractères** alphanumériques. C’est en dessous de la longueur que la démo 3 retient pour un mot de passe non mémorisé (plus de 20). La rotation mensuelle compense en partie ; à signaler dans l’analyse de risque.

## 4.5 Les secrets qui ne tournent pas

Les secrets en `never` (bases MySQL, RabbitMQ, certificats internes) ne sont pas renouvelés automatiquement.

| Question | Réponse |
|---|---|
| Est-ce grave ? | Ils ne sortent pas du cluster : ils sont échangés entre charms par les relations Juju, chiffrés au repos par Juju. Le risque principal est l’accès à la machine ou au contrôleur Juju |
| Comment les protéger ? | Limiter l’accès à Lab-Sunbeam et au contrôleur, protéger les sauvegardes, auditer les lectures (`juju show-secret --reveal` est tracé par Juju) |
| Et en cas de compromission (R26) ? | Le renouvellement passe par les charms (recréer les relations concernées) : c’est une **opération de maintenance lourde**, à préparer avec la documentation de Canonical, pas à improviser |

## 4.6 Le mot de passe d’`admin`

Son secret, `credentials_admin`, est en `never` (4.2) : il ne tourne pas tout seul.

⚠ **Ne pas le changer avec `openstack user set admin --password …`.** Sunbeam fournit ce mot de passe à la demande (`sunbeam openrc`, qui lit le compte via l’action `get-admin-account` du charm, guide `4-juju-cli/`, démo 6), à partir de ce secret. Un changement fait à la main laisserait l’**ancien** mot de passe dans le secret : `sunbeam openrc` distribuerait alors des accès invalides.

**L’outil prévu : l’action `regenerate-password` du charm Keystone.**

```bash
juju show-action -m openstack keystone regenerate-password
```

✅ **Attendu** (18 octobre) : `Regenerate password for the given user.`, avec un seul argument, `username`.

Ce que fait l’action, lu dans le code du charm (`src/charm.py`, `_regenerate_password_action`) :

| Étape | Effet |
|---|---|
| 1 | Retrouve le secret `credentials_<username>` du compte |
| 2 | Génère un mot de passe de **12** caractères (`pwgen.pwgen(12)`) |
| 3 | L’applique au compte dans Keystone |
| 4 | Écrit une nouvelle révision du secret : `sunbeam openrc` et les services qui lisent ce secret reçoivent le nouveau mot de passe |
| 5 | **Affiche** le nouveau mot de passe dans le résultat de l’action |

Usage, à préparer comme une opération planifiée :

```bash
juju run -m openstack keystone/leader regenerate-password username=admin
sunbeam openrc > ~/admin-openrc
```

⚠ **Non joué sur le lab** : il aurait invalidé le mot de passe d’`admin` déjà utilisé ailleurs (Horizon, profil `lab-admin` de `clouds.yaml` du guide `3-sunbeam-cli/`). À prévoir dans la procédure : régénérer tous les fichiers d’accès qui contiennent ce mot de passe, et lancer l’action **hors** écran projeté, puisqu’elle affiche le mot de passe.

À défaut de rotation régulière, traiter `admin` comme un **compte de secours** (démo 3) : rarement utilisé, tracé, et protégé par l’accès restreint à Lab-Sunbeam.

## 4.7 Les identifiants d’application : la rotation côté utilisateur

**À quoi ça sert :** les scripts des utilisateurs utilisent des identifiants d’application (démo 2, étape 10). Leur rotation est simple, et sans interruption : on crée le nouveau **avant** de supprimer l’ancien.

```bash
source ~/demo-openrc
openstack application credential create lab-sec-script-v1 --role member --role reader \
  --expiration "$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%S)" -f value -c id
```

Trois mois plus tard (ou en cas de doute sur sa confidentialité) :

```bash
openstack application credential create lab-sec-script-v2 --role member --role reader \
  --expiration "$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%S)" -f json > ~/lab-sec-ac-v2.json
chmod 600 ~/lab-sec-ac-v2.json
```

1. Mettre le nouvel identifiant et son secret dans le script (ou dans son `clouds.yaml`), vérifier que le script fonctionne :

   ```bash
   ACID=$(python3 -c 'import json; print(json.load(open("/home/vagrant/lab-sec-ac-v2.json"))["id"])')
   ACS=$(python3 -c 'import json; print(json.load(open("/home/vagrant/lab-sec-ac-v2.json"))["secret"])')
   env -u OS_USERNAME -u OS_PASSWORD -u OS_USER_DOMAIN_NAME -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME \
     openstack --os-auth-type v3applicationcredential \
     --os-application-credential-id "$ACID" --os-application-credential-secret "$ACS" network list -c Name
   ```

2. Supprimer l’ancien :

   ```bash
   openstack application credential delete lab-sec-script-v1
   openstack application credential list -c Name -c "Expires At"
   ```

✅ **Attendu** (18 octobre) : `demo-network` et `external-network` avec l’identifiant v2 ; puis seul `lab-sec-script-v2` reste, avec sa date d’expiration (`2027-01-16T10:15:24.000000`, 90 jours plus tard).

⚠ **Pourquoi `--role member --role reader` ?** Essayé le 18 octobre avec `--role member` seul : l’identifiant ne voyait que `external-network`, pas `demo-network`. Sur ce cloud, `member` implique bien `reader` (`openstack implied role list`), et la lecture des réseaux du projet demande `reader`. Mais le jeton d’un identifiant d’application ne reçoit que les rôles **nommés** à sa création. Toujours tester le script avec le nouvel identifiant avant de supprimer l’ancien.

| Règle | Pourquoi |
|---|---|
| Toujours une **expiration** | Un identifiant oublié finit par mourir de lui-même |
| Le **moindre rôle** nécessaire (`reader` seul si le script ne fait que lire) | Un vol donne moins de droits |
| Créer le nouveau **avant** de supprimer l’ancien | Pas d’interruption du script |
| Le **secret** n’est affiché qu’une fois | Keystone n’en garde qu’une empreinte : le ranger aussitôt dans un coffre |

## Nettoyage

```bash
source ~/demo-openrc
openstack application credential delete lab-sec-script-v2 2>/dev/null
openstack application credential delete lab-sec-script-v1 2>/dev/null
rm -f ~/lab-sec-ac-v2.json ~/lab-sec-cles-j1.txt
```

## À retenir

- Sur Sunbeam, les secrets des services sont **générés, rangés et distribués par Juju** : on les inventorie avec `juju secrets`, sans jamais les révéler.
- Les **clés Fernet** (chaque jour) et les **mots de passe des comptes de service** (chaque mois) tournent **automatiquement**, sans interruption, grâce aux clés en attente et secondaires : constaté en direct sur le lab.
- Les secrets en `never` (dont `admin`) se protègent par l’**accès** au nœud et au contrôleur ; leur renouvellement (`regenerate-password`) est une opération planifiée.
- Côté utilisateurs : des **identifiants d’application** à durée limitée, avec des rôles nommés explicitement, renouvelés en recouvrement.
