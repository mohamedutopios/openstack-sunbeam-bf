# Démo 02 : les jetons

**Module 8 · 20 min · utilise le compte `demo` de Sunbeam, ne crée rien.**

Un jeton est une preuve datée de « qui, sur quoi, avec quels rôles », présentée à chaque service à la place du mot de passe.

```bash
source ~/demos-identite/demo-env.sh
K="sudo k8s kubectl -n openstack"
DEMO_MDP=$(sed -n 's/^export OS_PASSWORD=//p' ~/demo-openrc | tr -d "\"'")
```

La dernière ligne lit le mot de passe de `demo` sans l'afficher. ⚠ Ne pas l'afficher devant la salle.

## 1. Fabriquer un jeton à la main

**Pourquoi.** Le client cache ce qu'il envoie. Pour comprendre un refus, il faut voir la vraie demande.

```bash
cat > /tmp/jeton.json <<EOF
{"auth": {
  "identity": {"methods": ["password"],
    "password": {"user": {"name": "demo", "domain": {"name": "users"}, "password": "$DEMO_MDP"}}},
  "scope": {"project": {"name": "demo", "domain": {"name": "users"}}}}}
EOF
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" \
  -d @/tmp/jeton.json -o /tmp/corps.json -D /tmp/entetes.txt
JETON=$(grep -i "^X-Subject-Token" /tmp/entetes.txt | cut -d' ' -f2 | tr -d '\r')
python3 -c "import json; t=json.load(open('/tmp/corps.json'))['token']; print(t['methods'], [r['name'] for r in t['roles']], len(t['catalog']), 'services', t['expires_at'])"
```

`identity` dit **qui** (compte + domaine), `scope` dit **sur quoi** (projet + domaine). `-o` garde le corps, `-D` les en-têtes.

✅ Le jeton (`gAAAAA…`) est dans l'en-tête `X-Subject-Token`. Le corps : `['password']`, rôles `member` et `reader`, 9 services, expiration dans une heure.

**À dire.**
- `reader` n'a jamais été donné : c'est le rôle impliqué, ajouté à l'émission.
- Le catalogue arrive avec le jeton (démo 01).
- `methods` dit comment l'identité a été prouvée : `password`, identifiant d'application, fédération.

## 2. Les portées

❓ Sans `scope` dans la demande, le jeton aura-t-il des droits ?

```bash
python3 -c "import json; d=json.load(open('/tmp/jeton.json')); del d['auth']['scope']; json.dump(d,open('/tmp/sans.json','w'))"
curl -s -X POST "$OS_AUTH_URL/auth/tokens" -H "Content-Type: application/json" -d @/tmp/sans.json \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['token']; print('projet :', t.get('project',{}).get('name'))"
```

✅ `projet : demo` : Keystone applique le **projet par défaut** du compte. Un script qui oublie la portée a quand même des droits.

Avec l'administrateur, portée domaine puis système :

```bash
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-domain-name admin_domain token issue -c domain_id
env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME openstack --os-system-scope all token issue
```

`env -u` retire le projet de la session : le client refuse de mélanger deux portées.

✅ Un jeton de domaine. ⛔ `HTTP 401` pour le système : `admin` n'y a aucun rôle.

**À dire.**
- On ne peut demander une portée que si l'on y détient un rôle.
- `401` ne veut pas forcément dire « mauvais mot de passe » : ici c'est la portée qui est impossible.
- Quatre portées : aucune (découvrir ses projets), projet (ressources), domaine (identités), système (le cloud entier).

## 3. Un jeton est un porteur

```bash
curl -s "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $JETON" \
  | python3 -c "import sys,json; print([n['name'] for n in json.load(sys.stdin)['networks']])"
```

✅ `['demo-network', 'external-network']`, sans aucun mot de passe.

**À dire.** Qui détient le jeton agit à votre place pendant une heure. Jamais dans un journal, un ticket, une capture. Sur ce lab l'API est en HTTP : il passe en clair.

## 4. Valider, puis révoquer

**Pourquoi.** Neutron ne sait pas lire le jeton : il demande à Keystone. Et un jeton volé doit pouvoir être coupé.

```bash
JADMIN=$(openstack token issue -f value -c id)
valider() { curl -s -o /dev/null -w "Keystone : %{http_code}\n" -I "$OS_AUTH_URL/auth/tokens" -H "X-Auth-Token: $JADMIN" -H "X-Subject-Token: $JETON"; }
neutron() { curl -s -o /dev/null -w "Neutron  : %{http_code}\n" "http://cloud.lab.test/openstack-neutron/v2.0/networks" -H "X-Auth-Token: $JETON"; }
valider
openstack token revoke "$JETON"
valider; neutron
```

❓ Après la révocation, Neutron refusera-t-il tout de suite ?

✅ `Keystone : 200` avant. Après : `Keystone : 404` immédiatement ; `Neutron : 200` encore quelques secondes, puis `401` (relancer `neutron` après 30 secondes).

**À dire.**
- C'est ce que fait chaque service : faire valider le jeton par Keystone, puis garder la réponse **en cache**.
- Une révocation met donc quelques secondes à atteindre les services.
- Incident réel : révoquer ne suffit pas. Changer le mot de passe, voire désactiver le compte : cela révoque tous ses jetons.

## 5. Durée de vie et clés Fernet

```bash
$K exec keystone-0 -c keystone -- sh -c 'awk "/^\[/{p=(\$0==\"[token]\" || \$0==\"[fernet_tokens]\")} p && NF" /etc/keystone/keystone.conf'
$K exec keystone-0 -c keystone -- ls /etc/keystone/fernet-keys/
```

⚠ N'afficher que ces sections : `[database]` contient le mot de passe MySQL.

✅ `expiration = 3600`, `allow_expired_window = 169200`, `max_active_keys = 4` ; quatre fichiers : `0` et trois numéros consécutifs.

**À dire.**
- Un jeton vit une heure. Il n'est stocké nulle part : la clé suffit à le vérifier.
- `0` = clé en attente, plus grand numéro = primaire (chiffre), les autres déchiffrent les jetons encore valides. Une rotation ne déconnecte personne.
- Sur Sunbeam, le charm fait tourner et distribue les clés. Qui lit ces fichiers peut fabriquer n'importe quel jeton.

```bash
rm -f /tmp/jeton.json /tmp/sans.json /tmp/corps.json /tmp/entetes.txt; unset DEMO_MDP JETON JADMIN
```
