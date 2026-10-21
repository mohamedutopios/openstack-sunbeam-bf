# Démo 01 : cartographier Keystone

**Module 8 · 15 min · ne crée rien.**

Keystone répond à trois questions pour tout le cloud : qui es-tu, sur quoi agis-tu, où est le service. La quatrième (en as-tu le droit), chaque service y répond lui-même (démo 03).

```bash
source ~/demos-identite/demo-env.sh
K="sudo k8s kubectl -n openstack"
```

## 1. Où tourne Keystone

**Pourquoi.** Quand plus personne ne se connecte, il faut savoir où regarder. Sur Sunbeam, Keystone est une application Juju dans un pod Kubernetes.

```bash
juju status -m openstack keystone
$K get pod keystone-0
$K logs keystone-0 -c keystone --since=10m | grep auth/tokens | tail -3
```

✅ `keystone` est `active` ; le pod est `2/2` (conteneurs `charm` et `keystone`) ; des lignes `POST /openstack-keystone/v3/auth/tokens … 201`.

**À dire.**
- `201` sur `auth/tokens` = une connexion réussie. C'est la ligne à connaître.
- Tout l'état (comptes, projets, droits, catalogue) est dans MySQL ; le pod ne garde que les clés des jetons (démo 02).
- On ne modifie jamais `keystone.conf` à la main : le charm le réécrit.

## 2. Ce que Sunbeam a créé

**Pourquoi.** Premier réflexe sur un cloud qu'on reprend : l'inventaire.

```bash
openstack domain list -c Name -c Description
openstack project list --long -c Name -c "Domain ID"
openstack user list
openstack user list --domain service_domain -c Name
```

✅ Quatre domaines : `admin_domain` (l'administrateur), `service_domain` (un compte par service : `svc_nova-…`, `svc_neutron-…`), `users` (le compte `demo`), `Default`. Deux projets s'appellent `admin`.

⚠ `user list` sans `--domain` ne montre que `admin` : seulement le domaine du jeton.

**À dire.**
- Sunbeam sépare déjà plateforme, services et utilisateurs. Ne jamais créer de compte humain dans `service_domain`.
- Un nom n'est unique que dans son domaine : on précise **toujours** le domaine.

## 3. Un droit, c'est une affectation

❓ Le compte `demo` est-il administrateur ? Comment le prouver ?

```bash
openstack role assignment list --names --user demo --user-domain users
openstack implied role list
openstack role assignment list --names --user demo --user-domain users --effective
```

✅ `demo` a `member` sur le projet `demo`. La chaîne `admin → manager → member → reader`. Avec `--effective`, `demo` a `member` **et** `reader`.

**À dire.**
- Seule phrase à retenir de Keystone : **tel acteur détient tel rôle sur telle cible** (projet, domaine ou système).
- `--effective` montre ce qui sera réellement dans le jeton : rôles impliqués, groupes, héritages. Réflexe d'audit.

## 4. Le catalogue

**Pourquoi.** Le client ne connaît qu'une adresse, celle de Keystone. Comment trouve-t-il Neutron ?

```bash
echo "$OS_AUTH_URL"
openstack endpoint list --service network -c Interface -c URL
openstack --debug network list 2>&1 | grep "^REQ: curl" | cut -c1-100
```

✅ Trois adresses pour Neutron : `public` (`cloud.lab.test`), `internal` (`internal.lab.test`), `admin` (interne à Kubernetes). Le client appelle d'abord Keystone, puis `http://cloud.lab.test:80/openstack-neutron/…`.

**À dire.**
- Le catalogue arrive **avec le jeton** : le client y lit l'adresse du service.
- `endpoint not found` n'est jamais une panne du service : c'est une ligne qui manque au catalogue.
- ⚠ Si Lab-Services est éteinte, `internal.lab.test` ne se résout plus : les services répondent `503 Keystone unavailable` alors que Keystone va bien.
