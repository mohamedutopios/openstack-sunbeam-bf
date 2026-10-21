# Démo 03 : politiques et refus

**Module 8 · 15 min · ne crée rien.**

Keystone certifie l'identité et les rôles. Chaque service décide ensuite, avec **ses** règles. Face à un refus : `401` ou `403` ? quelle règle ? quels rôles et quelle portée ?

```bash
source ~/demos-identite/demo-env.sh
K="sudo k8s kubectl -n openstack"
```

## 1. 401 ou 403

```bash
openstack --os-password faux token issue
source ~/demo-openrc; openstack user list; source ~/demos-identite/demo-env.sh
```

⛔ `HTTP 401` pour le mauvais mot de passe. ⛔ `403 … identity:list_users` pour `demo`.

**À dire.**
- `401` : on ne sait pas qui vous êtes (mot de passe, compte désactivé, jeton expiré, portée impossible).
- `403` : on le sait, et la règle dit non. Le message **nomme la règle**.

## 2. Lire la règle

```bash
$K exec keystone-0 -c keystone -- oslopolicy-policy-generator --namespace keystone 2>/dev/null \
  | grep -E '"identity:(list_users|create_user|create_project)"'
```

`oslopolicy-policy-generator` donne les règles **effectives** du service.

✅
```text
"identity:create_project": "rule:admin_required"
"identity:list_users": "(rule:admin_required) or (role:reader and system_scope:all) or (role:reader and domain_id:%(target.domain_id)s)"
"identity:create_user": "rule:admin_required"
```

**À dire.**
- Une règle est une suite de « ou ». `list_users` : un `admin`, ou un `reader` système, ou un `reader` du domaine visé. `demo` est `reader` sur un **projet** : refusé.
- `admin_required` ne regarde aucune portée : `admin` n'importe où suffit (démo 05).
- Aucune règle ne cite `manager` : sur ce cloud, un gestionnaire de domaine ne crée rien (démo 05).

## 3. Pourquoi ces règles diffèrent du support

```bash
for pc in keystone-0/keystone:/etc/keystone/keystone.conf nova-0/nova-api:/etc/nova/nova.conf neutron-0/neutron-server:/etc/neutron/neutron.conf; do
  pod=${pc%%/*}; r=${pc#*/}; c=${r%%:*}; f=${r#*:}
  echo "== $c"; $K exec "$pod" -c "$c" -- sh -c "grep -A6 '^\[oslo_policy\]' $f | grep -E 'enforce_(scope|new_defaults)' || echo '  défaut (false)'"
done
```

✅ `défaut (false)` pour les trois services.

**À dire.** `enforce_new_defaults` (rôles gradués) et `enforce_scope` (portée vérifiée) sont inactifs : ce sont les **anciennes règles**. Le support décrit le modèle récent (Secure RBAC). Situation courante en production sur cette génération.

## 4. Chaque service a ses règles

❓ `demo` peut-il créer un réseau ? un réseau partagé ? lister les hyperviseurs ?

```bash
source ~/demo-openrc
openstack network create demo-essai -f value -c name && openstack network delete demo-essai
openstack network create demo-partage --share
openstack hypervisor list
source ~/demos-identite/demo-env.sh
```

✅ Réseau créé puis supprimé. ⛔ `403 … create_network:shared is disallowed by policy`. ⛔ `403 … os-hypervisors:list-detail`.

**À dire.**
- Neutron : `member` **du projet** crée un réseau ; le partager à tous est réservé à l'administration.
- Nova : les hyperviseurs sont réservés à `admin`.
- La décision est locale à chaque service ; Keystone n'est consulté que pour valider le jeton.

## 5. Retrouver la requête dans le journal

```bash
source ~/demo-openrc
openstack --debug user list 2>&1 | grep -io "x-openstack-request-id: req-[0-9a-f-]*" | head -1
source ~/demos-identite/demo-env.sh
$K logs keystone-0 -c keystone --since=2m | grep ForbiddenAction | tail -1
```

✅ Le même `req-…` côté client et dans la ligne `ForbiddenAction … identity:list_users` du journal.

**À dire.** Pour un utilisateur qui « s'est fait refuser » : lui demander `--debug` et l'identifiant `req-…`. C'est le fil qui relie son écran au journal.
