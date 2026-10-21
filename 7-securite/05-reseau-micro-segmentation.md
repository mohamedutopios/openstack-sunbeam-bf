# Démo 5 : réseau, isolation entre tenants et micro-segmentation

> **Statut : rejouée sur le lab le 18 octobre 2026**, en entier, nettoyage compris. Les sorties citées sont celles de ce jour ; les adresses et identifiants changent d’une installation à l’autre. Support : module 13.

## Objectif

Construire deux **tenants** (projets) étanches, avec chacun son réseau privé, puis découper l’un d’eux en **zones** (web, base de données) dont les échanges sont limités au strict nécessaire, et **prouver** chaque cloisonnement par un essai de connexion.

```text
                           external-network 192.168.57.0/24 (IP flottantes)
                     ┌───────────────┴─────────────────────┐
                 lab-sec-a-router                      lab-sec-b-router
                     │                                     │
 Tenant A  lab-sec-a-net 10.60.1.0/24          Tenant B  lab-sec-b-net 10.60.2.0/24
   ├── lab-sec-a-web  [sg-web]  + IP flottante     └── lab-sec-b-app [sg-b-app] + IP flottante
   └── lab-sec-a-db   [sg-db]   sans IP flottante

 Autorisé :  PC (192.168.57.1) → a-web (ping, SSH)     a-web → a-db (ping)     PC → b-app (ping)
 Interdit :  PC → a-db     b-app → a-web, a-db     a-web → b-app (privé ou flottant)
```

## 5.1 Comprendre : les quatre niveaux d’isolation

| Niveau | Mécanisme | Ce qu’il isole |
|---|---|---|
| **Visibilité** | Chaque ressource appartient à un projet | Un tenant ne **voit** pas les réseaux, VM, groupes de sécurité des autres |
| **Réseau privé** | Un réseau par projet, réalisé par OVN en réseau virtuel (*overlay*) distinct | Deux projets peuvent même utiliser les **mêmes** adresses : leurs paquets ne se mélangent pas |
| **Routage** | Un routeur par projet ; pas de route entre deux réseaux privés | Seule sortie : le réseau externe, par traduction d’adresse (SNAT) ou IP flottante |
| **Groupes de sécurité** | Pare-feu à **état**, appliqué à chaque **port** de VM | Qui peut parler à **chaque** VM, sur quel protocole : c’est la micro-segmentation |

### Réseau partagé ou réseau privé

```bash
source ~/admin-openrc
openstack network list --long -c Name -c Project -c Shared -c "Router Type" -c Subnets
```

✅ **Attendu** (18 octobre) :

```text
| Name             | Project                          | Shared | Subnets   | Router Type |
| demo-network     | acb0976350464f5baa07665d23aad177 | False  | 5b6488b5… | Internal    |
| external-network | 27b199c003b4440c9212c4e79eae8499 | False  | dea2ca3c… | External    |
```

**Comment le lire :** `external-network` est **externe** (`Router Type: External`) : il appartient au projet `admin` et n’est pas partagé (`Shared: False`), mais tous les projets peuvent y brancher un routeur ou y prendre une IP flottante. `demo-network` est privé au projet `demo`. Aucun réseau partagé à tous sur ce lab.

| Type | Créé par | Visible par | Usage |
|---|---|---|---|
| **Externe** | Plateforme | Tous (pour y brancher un routeur ou prendre une IP flottante) | Sortie vers l’extérieur |
| **Partagé** (`--share`) | Plateforme seulement (`create_network:shared` = `rule:admin_only`, TP 1 des `labs-iam/`, § 1.6.2) | **Tous** les projets | Rare : un réseau commun à tout le cloud. À éviter, il casse l’isolation |
| **Partagé à certains projets** (RBAC réseau) | Propriétaire ou plateforme | Les seuls projets désignés | Partage contrôlé (5.7) |
| **Privé** | Membre du projet | Le seul projet | Le cas normal |

## 5.2 Préparer les deux tenants (plateforme)

**À quoi ça sert :** un domaine dédié, deux projets, un compte par tenant, et des quotas bas. Tout porte le préfixe `lab-sec` pour le nettoyage.

```bash
source ~/admin-openrc
read -rsp "Mot de passe des comptes de demo : " LAB_PW; echo
openstack domain create lab-sec --description "Demo micro-segmentation"
for t in a b; do
  openstack project create lab-sec-$t --domain lab-sec
  openstack user create lab-sec-$t-user --domain lab-sec --password "$LAB_PW"
  openstack role add --user lab-sec-$t-user --user-domain lab-sec --project lab-sec-$t --project-domain lab-sec member
  openstack quota set "$(openstack project show lab-sec-$t --domain lab-sec -f value -c id)" \
    --instances 2 --cores 2 --ram 1024 --floating-ips 1 --networks 1 --routers 1
done
openstack role assignment list --project lab-sec-a --project-domain lab-sec --names
```

✅ **Attendu :** `member | lab-sec-a-user@lab-sec | | lab-sec-a@lab-sec`. Le rôle est donné sur le **projet**, pas sur le domaine : le compte ne voit que son tenant.

Deux fonctions pour agir **en tant que** chaque tenant, sans toucher à la session administrateur :

```bash
A() { env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME -u OS_USERNAME -u OS_USER_DOMAIN_NAME -u OS_PASSWORD \
      openstack --os-username lab-sec-a-user --os-user-domain-name lab-sec --os-password "$LAB_PW" \
                --os-project-name lab-sec-a --os-project-domain-name lab-sec "$@"; }
B() { env -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME -u OS_USERNAME -u OS_USER_DOMAIN_NAME -u OS_PASSWORD \
      openstack --os-username lab-sec-b-user --os-user-domain-name lab-sec --os-password "$LAB_PW" \
                --os-project-name lab-sec-b --os-project-domain-name lab-sec "$@"; }
A token issue -c project_id -c expires
B token issue -c project_id -c expires
```

✅ **Attendu :** deux jetons, avec deux `project_id` différents.

⚠ Si le TLS a été activé (démo 1), `OS_AUTH_URL` et `OS_CACERT` viennent de `~/admin-openrc` et restent valables dans ces fonctions.

## 5.3 Le réseau de chaque tenant

**Tenant A :**

```bash
A network create lab-sec-a-net
A subnet create lab-sec-a-subnet --network lab-sec-a-net --subnet-range 10.60.1.0/24 --dns-nameserver 192.168.56.20
A router create lab-sec-a-router
A router set lab-sec-a-router --external-gateway external-network
A router add subnet lab-sec-a-router lab-sec-a-subnet
```

**Tenant B :**

```bash
B network create lab-sec-b-net
B subnet create lab-sec-b-subnet --network lab-sec-b-net --subnet-range 10.60.2.0/24 --dns-nameserver 192.168.56.20
B router create lab-sec-b-router
B router set lab-sec-b-router --external-gateway external-network
B router add subnet lab-sec-b-router lab-sec-b-subnet
```

| Commande | Rôle |
|---|---|
| `network create` | Un réseau virtuel privé au projet |
| `subnet create … --subnet-range` | La plage d’adresses ; `--dns-nameserver` : le DNS du lab, pour que les VM résolvent les noms |
| `router create` puis `router set --external-gateway external-network` | Un routeur, avec une patte sur le réseau externe : sortie vers l’extérieur |
| `router add subnet` | La seconde patte, sur le réseau privé : passerelle des VM |

**Vérifier la visibilité :**

```bash
A network list -c Name
B network list -c Name
```

✅ **Attendu** (18 octobre) : A voit `lab-sec-a-net` et `external-network`, **pas** `lab-sec-b-net` ; et réciproquement. Ni l’un ni l’autre ne voit `demo-network`.

## 5.4 Les groupes de sécurité : micro-segmentation du tenant A

### Le piège du groupe `default`

```bash
A security group rule list default -c Direction -c "IP Protocol" -c "IP Range" -c "Remote Security Group"
```

✅ **Attendu** (18 octobre) :

```text
+-------------+-----------+-----------+--------------------------------------+
| IP Protocol | IP Range  | Direction | Remote Security Group                |
+-------------+-----------+-----------+--------------------------------------+
| None        | None      | ingress   | e6757612-0664-4ab2-8262-6e61469e269d |
| None        | None      | ingress   | e6757612-0664-4ab2-8262-6e61469e269d |
| None        | 0.0.0.0/0 | egress    | None                                 |
| None        | ::/0      | egress    | None                                 |
+-------------+-----------+-----------+--------------------------------------+
```

Deux règles **entrantes** (IPv4 et IPv6), tous protocoles (`None`), dont la source est le groupe `default` lui-même (son identifiant dans `Remote Security Group`), et deux règles **sortantes** vers tout. Dans ce client (7.5.0), la colonne de l’adresse source s’appelle `IP Range`.

**Comment le lire :** toutes les VM placées dans `default` peuvent se joindre librement **entre elles**, sur tous les ports. C’est pratique, mais c’est l’inverse de la micro-segmentation : on n’utilise pas `default` pour les VM de la démo.

### Le groupe des serveurs web

```bash
A security group create sg-web --description "Serveurs web : SSH et ping depuis le poste d'administration"
A security group rule create sg-web --ingress --protocol icmp --remote-ip 192.168.57.1/32
A security group rule create sg-web --ingress --protocol tcp --dst-port 22 --remote-ip 192.168.57.1/32
```

**Comment le lire :** entrées autorisées : le **ping** et le **SSH**, depuis la **seule** adresse `192.168.57.1`, le PC Windows sur le réseau externe. Tout le reste entrant est refusé : un groupe de sécurité **refuse par défaut**.

### Le groupe des bases de données

```bash
A security group create sg-db --description "Base : joignable seulement depuis sg-web"
A security group rule create sg-db --ingress --protocol icmp --remote-group sg-web
A security group rule create sg-db --ingress --protocol tcp --dst-port 5432 --remote-group sg-web
A security group rule list sg-db -c Direction -c "IP Protocol" -c "Port Range" -c "Remote Security Group"
```

✅ **Attendu** (18 octobre) : deux règles `ingress` (`icmp`, et `tcp` `5432:5432`) dont le `Remote Security Group` est l’identifiant de `sg-web`, plus deux règles `egress` créées d’office avec tout nouveau groupe (sortie libre).

**La commande, mot par mot :** `--remote-group sg-web` = la source autorisée n’est pas une plage d’adresses, mais **toute VM membre du groupe `sg-web`**, quelle que soit son adresse. Le port `5432` est celui de PostgreSQL : l’essai de connexion se fera au ping, mais la règle montre ce qu’on ouvrirait en vrai.

**Pourquoi c’est de la micro-segmentation :** la règle suit le **rôle** de la VM, pas son adresse. Une nouvelle VM web hérite du droit en entrant dans `sg-web` ; une VM retirée du groupe le perd aussitôt.

### Le groupe du tenant B

```bash
B security group create sg-b-app --description "Appli B : ping depuis le poste d'administration"
B security group rule create sg-b-app --ingress --protocol icmp --remote-ip 192.168.57.1/32
```

## 5.5 Les VM et les IP flottantes

Une clé SSH par tenant, gardée sur Lab-Sunbeam :

```bash
A keypair create lab-sec-a-key --private-key ~/lab-sec-a.pem
chmod 600 ~/lab-sec-a.pem
```

Les VM, chacune **seulement** dans son groupe (pas dans `default`) :

```bash
A server create lab-sec-a-web --image ubuntu --flavor m1.tiny --network lab-sec-a-net --security-group sg-web --key-name lab-sec-a-key --wait -c status -f value
A server create lab-sec-a-db  --image ubuntu --flavor m1.tiny --network lab-sec-a-net --security-group sg-db  --key-name lab-sec-a-key --wait -c status -f value
B server create lab-sec-b-app --image ubuntu --flavor m1.tiny --network lab-sec-b-net --security-group sg-b-app --wait -c status -f value
```

Une IP flottante pour `a-web` et pour `b-app`, **pas** pour `a-db` :

```bash
FIP_A=$(A floating ip create external-network -f value -c floating_ip_address)
A server add floating ip lab-sec-a-web "$FIP_A"
FIP_B=$(B floating ip create external-network -f value -c floating_ip_address)
B server add floating ip lab-sec-b-app "$FIP_B"
DB_IP=$(A server show lab-sec-a-db -f json -c addresses | python3 -c "import sys,json; print(list(json.load(sys.stdin)['addresses'].values())[0][0])")
B_IP=$(B server show lab-sec-b-app -f json -c addresses | python3 -c "import sys,json; print(list(json.load(sys.stdin)['addresses'].values())[0][0])")
echo "a-web=$FIP_A  a-db=$DB_IP  b-app=$FIP_B (prive $B_IP)"
```

✅ **Attendu** (18 octobre, 2 minutes pour les trois VM) : trois `ACTIVE` (chacun précédé d’une ligne vide, laissée par l’indicateur d’attente), puis :

```text
a-web=192.168.57.130  a-db=10.60.1.113  b-app=192.168.57.121 (prive 10.60.2.84)
```

⚠ **Attendre que les VM finissent de démarrer** : `A console log show lab-sec-a-web | grep "Cloud-init .* finished"` indique quand `a-web` est prête (même chose pour `a-db` et, avec `B`, pour `b-app`). Constaté le 18 octobre : 3 à 4 minutes après `ACTIVE`.

## 5.6 Prouver le cloisonnement

Chaque essai a un résultat attendu. Les essais depuis Lab-Sunbeam passent par le NAT de VirtualBox, donc par le PC : ils arrivent avec l’adresse `192.168.57.1` (constaté le 17 octobre, guide `3-sunbeam-cli/DEMOS-ENTREPRISE.md`, démo 5).

| # | Essai | Commande (sur Lab-Sunbeam) | Attendu | Ce qui le décide |
|---|---|---|---|---|
| 1 | PC → a-web, ping | `ping -c 2 $FIP_A` | ✅ répond | `sg-web` autorise l’ICMP depuis `192.168.57.1` |
| 2 | PC → a-web, SSH | `ssh -i ~/lab-sec-a.pem -o StrictHostKeyChecking=accept-new ubuntu@$FIP_A hostname` | ✅ `lab-sec-a-web` | `sg-web` autorise le port 22 |
| 3 | a-web → a-db, ping | `ssh -i ~/lab-sec-a.pem ubuntu@$FIP_A "ping -c 2 -W 2 $DB_IP"` | ✅ répond | `sg-db` autorise l’ICMP depuis le groupe `sg-web` |
| 4 | PC → a-db | — | ⛔ impossible | `a-db` n’a **pas** d’IP flottante : rien ne mène à elle depuis l’extérieur |
| 5 | a-web → b-app, adresse privée | `ssh -i ~/lab-sec-a.pem ubuntu@$FIP_A "ping -c 2 -W 2 $B_IP"` | ⛔ pas de réponse | Aucune route entre `10.60.1.0/24` et `10.60.2.0/24` : réseaux de deux projets |
| 6 | a-web → b-app, IP flottante | `ssh -i ~/lab-sec-a.pem ubuntu@$FIP_A "ping -c 2 -W 2 $FIP_B"` | ⛔ pas de réponse | Le paquet sort par le routeur de A avec l’adresse externe de ce routeur, qui n’est pas `192.168.57.1` : `sg-b-app` le refuse |
| 7 | PC → b-app | `ping -c 2 $FIP_B` | ✅ répond | `sg-b-app` autorise le PC |
| 8 | PC → b-app, SSH | `ssh -o ConnectTimeout=10 ubuntu@$FIP_B hostname` | ⛔ `Connection timed out` | `sg-b-app` n’autorise que le ping : le reste est refusé par défaut |

**Constaté le 18 octobre :** les huit résultats attendus. Les « ✅ » répondent en `0% packet loss` (ou affichent `lab-sec-a-web`), les « ⛔ » en `100% packet loss` ou `Connection timed out`. Pour l’essai 4, `ping -c 2 $DB_IP` depuis Lab-Sunbeam donne `100% packet loss` : l’adresse privée n’est pas joignable de l’extérieur. Le chemin vers les IP flottantes passe bien par le NAT de VirtualBox : `ip route get $FIP_A` affiche `via 10.0.2.2 dev eth0`.

Les variables `FIP_A`, `DB_IP`, `FIP_B` et `B_IP` viennent de l’étape 5.5 : dans une nouvelle session, les redéfinir (mêmes commandes) avant les essais.

**Retirer un droit et le voir disparaître.** Supprimer la règle ICMP de `sg-db`, puis rejouer l’essai 3 :

```bash
RULE=$(A security group rule list sg-db --protocol icmp -f value -c ID)
A security group rule delete "$RULE"
ssh -i ~/lab-sec-a.pem ubuntu@$FIP_A "ping -c 2 -W 2 $DB_IP"
```

✅ **Attendu** (18 octobre) : `100% packet loss`. Le changement s’applique **immédiatement**, sans redémarrer la VM. Remettre la règle (`A security group rule create sg-db --ingress --protocol icmp --remote-group sg-web`) : le ping revient (`0% packet loss`) trois secondes plus tard.

**L’isolation, vue de l’administrateur :**

```bash
openstack server list --all-projects -c Name -c Networks --name lab-sec
openstack security group list --all-projects -c Name -c Project | grep -E "sg-|default"
```

✅ **Attendu** (18 octobre) : les trois VM, et pour chaque projet ses groupes de sécurité **et** son propre groupe `default` : un `default` par projet (ici cinq : `lab-sec-a`, `lab-sec-b`, `demo`, `admin` et un projet de service). Neutron crée le `default` d’un projet à sa première utilisation du réseau.

## 5.7 Partager volontairement, sans tout ouvrir : le RBAC réseau

**Situation :** A doit offrir un réseau à B (un réseau de service commun, par exemple), sans le partager avec **tout** le cloud.

Le quota de réseaux du tenant A est à 1 (5.2) : le relever d’abord, sinon la création est refusée (`Quota exceeded`) :

```bash
openstack quota set "$(openstack project show lab-sec-a --domain lab-sec -f value -c id)" --networks 2
```

Puis :

```bash
A network create lab-sec-a-partage
A subnet create lab-sec-a-partage-subnet --network lab-sec-a-partage --subnet-range 10.60.9.0/24
B_PROJECT=$(openstack project show lab-sec-b --domain lab-sec -f value -c id)
A network rbac create --target-project "$B_PROJECT" --action access_as_shared --type network lab-sec-a-partage
B network list -c Name
A network rbac list
```

| Morceau | Rôle |
|---|---|
| `network rbac create` | Une règle de partage d’un objet réseau |
| `--target-project` | Le **seul** projet bénéficiaire (identifiant, ici celui de B) |
| `--action access_as_shared` | B peut **brancher** des VM sur ce réseau, sans pouvoir le modifier |

✅ **Attendu** (18 octobre) : B voit maintenant `lab-sec-b-net`, `external-network` **et** `lab-sec-a-partage` ; la règle apparaît dans `network rbac list` (`Object Type: network`). Aucun autre projet ne le voit. Pour s’en convaincre, depuis le compte `demo`, dans un sous-shell pour ne pas quitter la session administrateur : `(source ~/demo-openrc; openstack network list -c Name)`.

Retirer le partage :

```bash
A network rbac delete "$(A network rbac list -f value -c ID | head -1)"
A subnet delete lab-sec-a-partage-subnet
A network delete lab-sec-a-partage
```

## 5.8 La protection des ports (anti-usurpation)

```bash
PORT=$(A port list --server lab-sec-a-web -f value -c ID)
A port show "$PORT" -c port_security_enabled -c allowed_address_pairs -c fixed_ips -c security_group_ids
```

✅ **Attendu** (18 octobre) : `port_security_enabled | True`, `allowed_address_pairs` vide, l’adresse `10.60.1.x` de la VM et l’identifiant de `sg-web`.

**Comment le lire :** avec la sécurité de port, une VM ne peut émettre qu’avec **son** adresse et **son** adresse MAC : elle ne peut pas usurper l’adresse d’une autre VM. Les groupes de sécurité ne s’appliquent que si elle est active. Une adresse supplémentaire (adresse virtuelle d’une grappe, par exemple) se déclare explicitement avec `--allowed-address`, plutôt que de désactiver la protection.

### Repérer les ports sans protection, en audit

Piège constaté le 18 octobre : `openstack port list --long` n’a **pas** de colonne pour la sécurité de port (colonnes : `Device Owner`, `Fixed IP Addresses`, `ID`, `MAC Address`, `Name`, `Security Groups`, `Status`, `Tags`, `Trunk subports`). Un filtre sur une colonne absente ne trouve jamais rien : l’audit dirait « tout va bien », à tort. Et l’API de Neutron refuse de filtrer sur ce champ (`['port_security_enabled'] is invalid attribute for filtering`). On lit donc tous les ports par l’API, et on trie soi-même :

```bash
T=$(openstack token issue -f value -c id)
N=$(openstack endpoint list --service network --interface public -f value -c URL)
curl -s --cacert "$OS_CACERT" -H "X-Auth-Token: $T" "$N/v2.0/ports?fields=id&fields=device_owner&fields=port_security_enabled" \
  | python3 -c '
import sys, json, collections
ports = json.load(sys.stdin)["ports"]
c = collections.Counter((p["device_owner"] or "(aucun)", p["port_security_enabled"]) for p in ports)
for (owner, ps), n in sorted(c.items()): print(f"  {owner:28} protection={ps!s:5} {n}")
vm = [p["id"] for p in ports if p["device_owner"].startswith("compute:") and not p["port_security_enabled"]]
print(len(vm), "port(s) de VM sans protection :", vm)'
openstack token revoke "$T"
```

**La commande, mot par mot :** un jeton administrateur (`T`) et l’adresse de Neutron lue dans le catalogue (`N`) ; la liste de **tous** les ports, réduite à trois champs (`fields=`) ; le programme Python compte les ports par propriétaire (`device_owner`) et par état de la protection, puis liste les ports de **VM** (`compute:…`) sans protection.

✅ **Attendu** (18 octobre, avec les trois VM de la démo) :

```text
  compute:nova                 protection=True  3
  network:distributed          protection=False 4
  network:floatingip           protection=False 2
  network:router_gateway       protection=False 3
  network:router_interface     protection=False 3
0 port(s) de VM sans protection : []
```

**Comment le lire :** les ports des routeurs, des IP flottantes et les ports `distributed` d’OVN (service de métadonnées) sont sans protection : c’est normal, aucune VM ne s’en sert. Seule la ligne finale compte.

**Prouver que l’audit détecte un écart.** Un simple `member` peut créer un port sans protection :

```bash
A port create lab-sec-test-port --network lab-sec-a-net --disable-port-security --no-security-group --device-owner compute:nova
```

Rejouer l’audit : ✅ `1 port(s) de VM sans protection : ['…']` (constaté). Puis `A port delete lab-sec-test-port`.

## Nettoyage

Dans l’ordre : VM, IP flottantes, routeurs, réseaux, groupes (y compris les `default`), clés, puis l’identité.

```bash
A server delete lab-sec-a-web lab-sec-a-db --wait
B server delete lab-sec-b-app --wait
A floating ip delete "$FIP_A"; B floating ip delete "$FIP_B"
A router remove subnet lab-sec-a-router lab-sec-a-subnet; A router delete lab-sec-a-router
B router remove subnet lab-sec-b-router lab-sec-b-subnet; B router delete lab-sec-b-router
A network delete lab-sec-a-net; B network delete lab-sec-b-net
A security group delete sg-web sg-db; B security group delete sg-b-app
for t in a b; do
  P=$(openstack project show lab-sec-$t --domain lab-sec -f value -c id)
  openstack security group list --project "$P" -f value -c ID | xargs -r openstack security group delete
done
A keypair delete lab-sec-a-key; rm -f ~/lab-sec-a.pem
for t in a b; do openstack project delete lab-sec-$t --domain lab-sec; openstack user delete lab-sec-$t-user --domain lab-sec; done
openstack domain set --disable lab-sec; openstack domain delete lab-sec
openstack server list --all-projects --name lab-sec
openstack floating ip list -c "Floating IP Address" -c Project
openstack security group list --all-projects -c Name -c Project
```

✅ **Attendu** (18 octobre) : plus aucune VM `lab-sec`, aucune IP flottante des projets supprimés, et seulement les groupes `default` des projets qui restent.

⚠ **Supprimer les ressources avant les projets** : une ressource survit à son projet et devient orpheline. Constaté le 18 octobre : sans la boucle sur les groupes, les deux groupes `default` des projets `lab-sec` restent après la suppression des projets. Ils ne se suppriment plus alors avec `--project` (le projet n’existe plus dans Keystone : `No project with a name or ID of '…' exists`), mais par leur identifiant : `openstack security group list --all-projects -f value -c ID -c Project`, puis `openstack security group delete <ID>`.

## À retenir

- L’isolation entre tenants tient à **quatre** niveaux : visibilité par projet, réseaux privés distincts, routage par projet, groupes de sécurité.
- Un réseau **partagé à tous** casse l’isolation : on lui préfère le **RBAC réseau**, qui partage avec un projet désigné.
- La **micro-segmentation** se fait par groupes de sécurité chaînés (`--remote-group`) : les droits suivent le **rôle** de la VM, pas son adresse.
- Ne pas mettre les VM dans le groupe `default`, qui laisse ses membres se joindre librement.
- Chaque règle se **prouve** par un essai, et chaque retrait de règle aussi. Un audit aussi : un contrôle qui ne trouve jamais rien est peut-être un contrôle qui ne regarde pas.
