# Démo 1 : chiffrement des flux (TLS)

> **Statut : rejouée sur le lab le 18 octobre 2026** (Sunbeam 2024.1, snap rev 1101). Les sorties citées sont celles de ce jour. Retour arrière joué le même jour. Non joué : l’import de la CA dans Windows (étape 1.3, à faire à la main).

## Objectif

**Constater** que les API du cloud circulent en clair, **montrer** ce que cela expose (un jeton lisible sur le réseau), **activer** TLS sur les adresses publiques et internes, **gérer** les certificats, puis **durcir**.

⚠ **Avant de commencer : un instantané VirtualBox de Lab-Sunbeam.** L’activation de TLS change toutes les adresses du cloud (`http://` → `https://`) : les fichiers d’accès (`~/admin-openrc`, `~/demo-openrc`, `clouds.yaml`) et les guides qui utilisent `http://` ne fonctionneront plus tels quels. Le retour arrière est décrit en fin de démo, mais l’instantané est la sécurité.

## 1.1 Le constat : ce qui circule en clair

### Les adresses du catalogue

```bash
source ~/admin-openrc
openstack endpoint list -c "Service Name" -c Interface -c URL | grep -E "keystone|nova|neutron"
```

✅ **Attendu** (observé le 17 octobre) : des adresses `http://cloud.lab.test:80/…` (interface `public`), `http://internal.lab.test:80/…` (`internal`), `http://10.152.183.x:…` (`admin`). **Aucune** en `https://`.

### Voir un jeton passer en clair

**À quoi ça sert :** rendre le risque concret. Chaque appel à une API transporte un **jeton** dans l’en-tête `X-Auth-Token` ; ce jeton vaut un mot de passe pendant une heure.

Dans une **première** session SSH sur Lab-Sunbeam :

```bash
sudo timeout 60 tcpdump -l -i any -A -s 0 'tcp port 80' 2>/dev/null | grep -m 2 -o "X-Auth-Token: .\{20\}"
```

Dans une **seconde** session :

```bash
source ~/demo-openrc
openstack network list
```

**La commande, mot par mot :**

| Morceau | Rôle |
|---|---|
| `timeout 60` | Arrête la capture au bout de 60 secondes, même si rien n’a été vu |
| `tcpdump -l` | Écrit chaque paquet aussitôt. Sans `-l`, quand sa sortie va dans un tube (`\|`), tcpdump la garde en mémoire et `grep` ne voit rien |
| `-i any` | Écoute toutes les cartes réseau de la VM, y compris les cartes virtuelles des pods (`lxc…`) |
| `-A -s 0` | Affiche le **contenu** des paquets en texte, en entier |
| `'tcp port 80'` | Seulement le trafic HTTP |
| `grep -m 2 -o "X-Auth-Token: .\{20\}"` | Les 2 premières lignes de jeton, coupées à 20 caractères (pour ne pas projeter un jeton entier) |

✅ **Attendu** (observé le 18 octobre) :

```text
X-Auth-Token: gAAAAABq…
X-Auth-Token: gAAAAABq…
```

**Quiconque écoute le réseau** lit les jetons, et peut s’en servir (TP 1 des `labs-iam/`, § 1.4.5 : un jeton est un « porteur »).

**Pourquoi pas un filtre sur l’adresse `192.168.56.201` ?** Essayé le 18 octobre : `0 packets captured`. Depuis Lab-Sunbeam, le réseau de Kubernetes (Cilium) remplace l’adresse publique par celle du pod Traefik **avant** l’envoi du paquet. Sans le filtre d’adresse, on voit le vrai trajet, avec l’option `-n` pour garder les adresses numériques :

| Paquet observé | Ce que c’est |
|---|---|
| `10.1.0.196.49424 > 10.1.0.192.80 … GET /openstack-neutron/…` | Le client `openstack` vers le pod **Traefik** (le répartiteur qui répond pour `cloud.lab.test`) |
| `10.1.0.192.42672 > 10.1.0.226.9696` | Traefik vers le pod **Neutron**, qui reçoit le même jeton |

Un poste extérieur (Windows, par exemple) envoie, lui, ses paquets à `192.168.56.201` sur le réseau du lab : un ordinateur branché sur ce réseau les lirait de la même façon.

Révoquer aussitôt les jetons de la démonstration :

```bash
openstack token revoke "$(openstack token issue -f value -c id)"
```

(Ceci révoque un nouveau jeton ; ceux capturés expirent dans l’heure. En formation, c’est l’occasion de rappeler pourquoi la durée de vie des jetons est courte.)

### Les flux internes

Les services s’appellent entre eux en permanence : nova-compute vers Neutron, et surtout chaque service vers Keystone pour **valider** le jeton qu’il reçoit. Sans rien lancer, compter pendant une minute les en-têtes de jetons qui passent en clair :

```bash
sudo timeout 60 tcpdump -l -i any -A -s 0 'tcp' 2>/dev/null | grep -o -E "^X-[A-Za-z-]*Token" | sort | uniq -c
```

✅ **Attendu** (observé le 18 octobre, sans aucune commande lancée par une personne) :

```text
     34 X-Auth-Token
      8 X-Subject-Token
```

**Comment le lire :** `X-Auth-Token`, le jeton de celui qui appelle : ici surtout les **comptes de service**, qui ont le rôle `admin` sur le projet `services`. `X-Subject-Token`, le jeton qu’un service demande à Keystone de **valider**. Le cloud fait circuler des jetons d’administration en clair même quand personne ne s’en sert.

### Ce qui est déjà protégé

TLS n’est pas absent partout (constaté le 18 octobre) :

| Flux | Constat | Vérification |
|---|---|---|
| Navigateur → Keycloak | **HTTPS** seulement (`sslRequired: all` dans `lab-sunbeam/keycloak/realm.json`, port 8443) | `curl -s -o /dev/null -w "%{http_code}\n" --cacert ~/ca.crt https://sso.lab.test:8443/realms/lab` : `200` (copie de `ca.crt` : démo 2, étape 0) |
| Réseau virtuel (OVN) | Certificats émis par l’application `certificate-authority` (charm `self-signed-certificates`) à `neutron`, `ovn-central`, `ovn-relay` | `juju status -m openstack --relations \| grep "^certificate-authority:certificates"` : trois lignes |
| API publiques et internes | **HTTP** | ci-dessus |
| Contrôleur Juju | Chiffré : l’API du contrôleur (`192.168.56.200:17070`) n’accepte que TLS, avec sa propre CA | `juju show-controller \| grep -E "api-endpoints\|ca-cert"` |

**Sécurité par défaut :** Sunbeam chiffre ses flux de **contrôle** (Juju, OVN) mais laisse les **API** en HTTP : c’est à l’exploitant d’activer TLS, avec ses propres certificats.

## 1.2 Choisir le mode de TLS

Sunbeam propose trois fonctionnalités (`sunbeam list-features`) :

| Fonctionnalité | Qui émet les certificats | Pour qui |
|---|---|---|
| `tls.self-signed` | La CA interne du cloud, `internal-ca` : l’application `certificate-authority`, déjà présente pour OVN (1.1) | Lab, démonstration : le plus simple |
| `tls.ca` | **Ta** CA d’entreprise : Sunbeam produit des demandes de certificat (CSR), tu les signes | Production avec une PKI existante |
| `tls.vault` | Vault, dont le certificat d’autorité intermédiaire est signé par ta CA | Production : renouvellement automatique (guide Keycloak, section 11) |

Et trois cibles (option `--endpoint`, répétable) : `public` (`cloud.lab.test`), `internal` (`internal.lab.test`), `rgw` (stockage objet).

Pour la démo : **`tls.self-signed`** sur `public` et `internal`. Le guide Keycloak (section 11) décrit la variante `tls.vault` avec la CA du lab, plus proche de la production.

**Conséquence à retenir pour la suite :** le lab aura alors **deux** autorités de certification.

| CA | Elle signe | Qui doit lui faire confiance |
|---|---|---|
| CA de **Sunbeam** (`CN = internal-ca`, application `certificate-authority`) | Les certificats du cloud : `cloud.lab.test`, `internal.lab.test` (et ceux d’OVN) | Le client `openstack` (`OS_CACERT`) et le navigateur de Windows (étape 1.3) |
| CA du **lab** (`ca.crt`, « Sunbeam Lab Root CA ») | Le certificat de Keycloak, `sso.lab.test` | Windows (déjà fait par `Configurer-Lab-Sunbeam.ps1`) et Keystone (démo 2, option `ca-chain`) |

Avec `tls.vault` (guide Keycloak), une seule CA, celle du lab, signe tout : c’est plus simple pour les clients, au prix d’une mise en place plus longue.

## 1.3 Activer TLS

D’abord, l’aide de la commande :

```bash
sunbeam enable tls self-signed --help
```

✅ **Attendu** (lu le 18 octobre) : une option `--endpoint [public|internal|rgw]`, à répéter pour chaque cible.

Garder une copie des fichiers d’accès actuels, puis activer :

```bash
cp ~/admin-openrc ~/admin-openrc.avant-tls
cp ~/demo-openrc ~/demo-openrc.avant-tls
time sunbeam enable tls self-signed --endpoint public --endpoint internal
```

**Ce qui se passe** (à suivre dans une seconde session avec `watch -n 15 "juju status -m openstack --format short | grep -v workload:active"`) : l’application `certificate-authority` signe un certificat pour chacun des deux répartiteurs Traefik (`traefik-public` pour `cloud.lab.test`, `traefik` pour `internal.lab.test`), qui servent alors en HTTPS. Les charms mettent ensuite à jour les adresses du **catalogue**. La charge de la VM monte (`load average` à 35 sur le lab) : c’est normal.

✅ **Attendu** (observé le 18 octobre) :

```text
OpenStack Tls Self-signed application enabled.
real	13m53.006s
```

Le message apparaît après 2 minutes, mais la commande attend encore une dizaine de minutes que tous les charms aient pris en compte les certificats : **ne pas l’interrompre**. Ensuite, `sunbeam list-features | grep tls` montre `tls.self-signed` coché (`X`).

### Mettre à jour les accès

L’ancien fichier d’accès ne fonctionne plus :

```bash
(source ~/admin-openrc.avant-tls; openstack token issue)
```

✅ **Attendu :** `SSL exception connecting to https://cloud.lab.test/… CERTIFICATE_VERIFY_FAILED … self-signed certificate in certificate chain`.

**Comment le lire :** l’adresse `http://` est redirigée vers `https://` (`curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://cloud.lab.test/openstack-keystone/v3` répond `301 -> https://…`). Le client suit la redirection, mais refuse le certificat : il ne connaît pas la CA qui l’a signé. C’est voulu : un client qui accepterait n’importe quel certificat ne serait plus protégé contre l’usurpation.

Régénérer le fichier d’accès administrateur :

```bash
sunbeam openrc > ~/admin-openrc
grep -E "OS_AUTH_URL|OS_CACERT" ~/admin-openrc
source ~/admin-openrc
openstack token issue -c expires
openstack endpoint list -c "Service Name" -c Interface -c URL | grep -E "keystone|nova"
```

✅ **Attendu** (observé le 18 octobre) :

```text
export OS_AUTH_URL=https://cloud.lab.test/openstack-keystone/v3
export OS_CACERT=/home/vagrant/.config/openstack/ca_bundle.pem
…
| nova         | public    | https://cloud.lab.test:443/openstack-nova/v2.1      |
| nova         | internal  | https://internal.lab.test:443/openstack-nova/v2.1   |
| nova         | admin     | http://10.152.183.142:8774/v2.1                     |
| keystone     | public    | https://cloud.lab.test/openstack-keystone/v3        |
```

**Comment le lire :** `OS_CACERT` dit au client **quelle CA** croire : le fichier `ca_bundle.pem` contient le certificat de `internal-ca`. Les adresses `public` et `internal` sont en `https://`. L’adresse `admin` (`10.152.183.x`) reste en HTTP : c’est une adresse de service Kubernetes, joignable seulement depuis l’intérieur du nœud, non concernée par `--endpoint`.

Mettre à jour `~/demo-openrc`, que `sunbeam openrc` ne génère pas : passer l’adresse en `https://` et ajouter la même CA.

```bash
sed -i "s|^export OS_AUTH_URL=http://|export OS_AUTH_URL=https://|" ~/demo-openrc
echo >> ~/demo-openrc
grep "OS_CACERT" ~/admin-openrc >> ~/demo-openrc
grep -E "AUTH_URL|CACERT" ~/demo-openrc
(source ~/demo-openrc; openstack network list -f value -c Name)
```

✅ **Attendu :** les deux lignes en `https://` et `OS_CACERT`, puis `demo-network` et `external-network`. Le `echo` ajoute un retour à la ligne : sur le lab, le fichier n’en avait pas à la fin, et la ligne `OS_CACERT` s’était collée à la précédente (`identity version 3export is not in supported versions`).

### Faire confiance à la CA sur Windows

Le navigateur doit connaître la nouvelle CA pour ouvrir Horizon sans alerte.

1. Sur Lab-Sunbeam, afficher le certificat de la CA (fichier public, sans clé privée) :

   ```bash
   CA=$(grep -oP "OS_CACERT=\K.*" ~/admin-openrc); echo "$CA"; openssl x509 -in "$CA" -noout -subject -enddate
   cat "$CA"
   ```

   ✅ **Attendu** (18 octobre) : `subject=CN = internal-ca, x500UniqueIdentifier = …` et `notAfter=Oct  9 10:32:22 2027 GMT`. La CA date de l’installation du cloud (9 octobre 2026) : c’est la même que celle d’OVN, valable un an.

2. Copier le bloc `-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----` dans un fichier `sunbeam-ca.crt` sur Windows.
3. Double-cliquer sur `sunbeam-ca.crt` → **Installer le certificat** → **Ordinateur local** → **Placer tous les certificats dans le magasin suivant** → **Autorités de certification racines de confiance** → **Terminer**.
4. Ouvrir l’adresse donnée par `sunbeam dashboard url`.

✅ **Attendu :** Horizon en `https://cloud.lab.test/…`, cadenas fermé, sans avertissement.

## 1.4 Vérifier le chiffrement

Rejouer la capture de 1.1, sur le port **443** cette fois :

```bash
sudo timeout 30 tcpdump -l -i any -A -s 0 'tcp port 443' | grep -c "X-Auth-Token"
```

Dans une seconde session, pendant ces 30 secondes : `source ~/demo-openrc; openstack network list`.

✅ **Attendu** (18 octobre) : `133 packets captured`, puis `0`. Le trafic passe, mais son contenu est chiffré : plus aucun jeton lisible.

**Et le reste du trafic ?** Rejouer le comptage d’une minute de 1.1 :

```bash
sudo timeout 60 tcpdump -l -i any -A -s 0 'tcp' 2>/dev/null | grep -o -E "^X-[A-Za-z-]*Token" | sort | uniq -c
```

✅ **Attendu** (18 octobre) : `20 X-Auth-Token` (34 avant), et plus aucun `X-Subject-Token`. Il reste donc des jetons en clair. D’où viennent-ils ?

```bash
sudo timeout 60 tcpdump -l -n -i any -A -s 0 'tcp' 2>/dev/null \
  | awk '/ IP /{h=$0} /^X-Auth-Token/{print h}' \
  | awk '{sub(/\.[0-9]+$/, "", $5); sub(/:$/, "", $7); print $5, "->", $7}' | sort | uniq -c
sudo k8s kubectl -n openstack get pod -o custom-columns=NOM:.metadata.name,IP:.status.podIP --no-headers | grep -E "traefik|placement|keystone-0"
```

**La commande, mot par mot :** le premier `awk` retient la ligne d’en-tête du dernier paquet (` IP source > destination`) et l’affiche quand un jeton apparaît ; le second garde l’adresse source sans son port, et la destination avec son port.

✅ **Attendu** (18 octobre ; les adresses des pods changent d’une installation à l’autre) :

```text
     20 10.1.0.177 -> 10.1.0.57.8778
traefik-0                        10.1.0.177
placement-0                      10.1.0.57
```

Selon la minute capturée, on voit aussi `10.1.0.79.5000`, le pod `keystone-0`. Toutes les lignes partent de `traefik-0`.

**Comment le lire :** TLS **s’arrête au répartiteur** Traefik. Derrière lui, Traefik joint chaque service en HTTP, sur le réseau des pods, à l’intérieur du nœud. Sur ce lab à un seul nœud, ce trafic ne sort jamais de la VM. Sur un cloud à plusieurs nœuds, ce réseau des pods passe d’une machine à l’autre : c’est la limite de `tls.*`, à couvrir par le chiffrement du réseau des pods (Cilium sait le faire) et par l’isolement du réseau de gestion.

### Les versions de TLS acceptées

```bash
for v in tls1 tls1_1 tls1_2 tls1_3; do
  printf "%-7s " "$v"
  echo | openssl s_client -connect cloud.lab.test:443 -servername cloud.lab.test -$v -cipher "DEFAULT@SECLEVEL=0" 2>&1 \
    | grep -o -E "Protocol *: TLSv1\.[23]|alert protocol version" | head -1
done
```

✅ **Attendu** (18 octobre) :

```text
tls1    alert protocol version
tls1_1  alert protocol version
tls1_2  Protocol  : TLSv1.2
tls1_3  Protocol  : TLSv1.3
```

**Comment le lire :** le **serveur** refuse TLS 1.0 et 1.1 (`alert protocol version`), et accepte TLS 1.2 et 1.3. C’est la sécurité par défaut de Traefik : rien à durcir de ce côté.

**La commande, mot par mot :** `-cipher "DEFAULT@SECLEVEL=0"` abaisse les exigences du **client**. Sans cette option, OpenSSL 3 refuse lui-même de proposer TLS 1.0 (`no protocols available`) : on ne testerait que le client, pas le serveur.

### Le certificat servi

Lire le certificat servi. La variable `CA` (chemin du certificat de la CA de Sunbeam) a été définie à l’étape 1.3 ; dans une nouvelle session, la redéfinir d’abord :

```bash
CA=$(grep -oP "OS_CACERT=\K.*" ~/admin-openrc)
echo | openssl s_client -connect cloud.lab.test:443 -servername cloud.lab.test -CAfile "$CA" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

✅ **Attendu** (18 octobre) :

```text
subject=CN = cloud.lab.test, x500UniqueIdentifier = …
issuer=CN = internal-ca, x500UniqueIdentifier = …
notBefore=Oct 18 08:58:50 2026 GMT
notAfter=Jan 16 08:58:50 2027 GMT
X509v3 Subject Alternative Name:
    DNS:cloud.lab.test
```

| Champ | Ce qu’on vérifie |
|---|---|
| `subject`, `subjectAltName` | Le nom `cloud.lab.test` y figure : sinon, alerte du navigateur |
| `issuer` | `internal-ca`, la CA du cloud |
| `notBefore`, `notAfter` | Émis à l’activation, valable **90 jours** : la date d’expiration est à **surveiller** (1.5) |

Et la chaîne complète : `echo | openssl s_client -connect cloud.lab.test:443 -servername cloud.lab.test -CAfile "$CA" 2>/dev/null | grep "Verify return code"` répond `0 (ok)`.

## 1.5 Gérer les certificats

Les durées de la CA du cloud se lisent dans la configuration de son charm :

```bash
juju config -m openstack certificate-authority certificate-validity
juju config -m openstack certificate-authority root-ca-validity
juju actions -m openstack certificate-authority
```

✅ **Attendu** (18 octobre) : `90d`, `365d`, et trois actions : `get-ca-certificate` (affiche la CA, sans clé), `get-issued-certificates` (la liste des certificats émis), `rotate-private-key` (nouvelle clé et nouvelle CA, **tous** les certificats émis sont révoqués et refaits).

| Certificat | Émis par | Durée | Renouvellement |
|---|---|---|---|
| API publiques et internes (`tls.self-signed`) | `internal-ca` | **90 jours** (`certificate-validity`) | Demandé par les charms Traefik avant l’échéance (⚠ non observé sur le lab : surveiller la date) |
| CA du cloud `internal-ca` | Elle-même | **365 jours** (`root-ca-validity`) : 9 octobre 2027 sur le lab | ⚠ L’échéance qui compte : une nouvelle CA oblige à redistribuer `OS_CACERT` et à réimporter la CA sur les postes |
| API (`tls.ca`) | CA de l’entreprise | Selon la PKI | **Manuel** : nouvelles CSR, signature, réinjection |
| API (`tls.vault`) | Vault | Courte | Automatique, tant que le certificat intermédiaire de Vault est valide (1 an, `sign-vault.sh`) |
| Keycloak | CA du lab (`init-keycloak.sh`) | **365 jours** | Manuel : nouveau certificat signé par la CA du lab, redémarrage du conteneur |
| CA du lab | Elle-même | Jusqu’en **2031** | Prévoir le remplacement bien avant |

**Surveiller l’expiration :** un certificat expiré coupe tout le cloud d’un coup. Une vérification simple, à planifier chaque semaine :

```bash
for h in cloud.lab.test:443 internal.lab.test:443 sso.lab.test:8443; do
  printf "%-24s " "$h"
  echo | openssl s_client -connect "$h" -servername "${h%:*}" 2>/dev/null | openssl x509 -noout -enddate
done
```

✅ **Attendu** (18 octobre) :

```text
cloud.lab.test:443       notAfter=Jan 16 08:58:50 2027 GMT
internal.lab.test:443    notAfter=Jan 16 08:58:50 2027 GMT
sso.lab.test:8443        notAfter=Oct  9 09:00:01 2027 GMT
```

En production, la même vérification alimente la supervision (alerte à 30 jours de l’échéance).

## 1.6 Durcir

| Mesure | Pourquoi | Vérification |
|---|---|---|
| Ne jamais utiliser `--insecure` ni `curl -k` comme solution | Ces options acceptent **n’importe quel** certificat : TLS ne protège plus de l’usurpation | `grep -r "insecure" ~/*.sh ~/.config/openstack/ 2>/dev/null` |
| Chiffrer aussi l’interface **interne** | Les jetons des comptes de service y circulent (1.1) | `--endpoint internal` (1.3) |
| Refuser les versions anciennes de TLS | TLS 1.0 et 1.1 sont obsolètes | Déjà fait par Traefik : test de 1.4, `alert protocol version` |
| Couvrir le trafic derrière le répartiteur | TLS s’arrête à Traefik ; derrière, HTTP sur le réseau des pods (1.4) | Plusieurs nœuds : chiffrement du réseau des pods, réseau de gestion isolé |
| Protéger la clé de la CA | Avec elle, on fabrique des certificats acceptés partout | Clé de la CA du lab : `~/lab/keycloak/pki/ca.key` sur Lab-Services, droits `600`, hors des sauvegardes non chiffrées |
| Une CA d’entreprise plutôt qu’auto-signée en production | Les postes font déjà confiance à la CA de l’entreprise ; révocation possible | `tls.ca` ou `tls.vault` |

## Retour arrière

À faire seulement **après** la démo 2, qui a besoin de HTTPS. Joué le 18 octobre.

```bash
time sunbeam disable tls self-signed
sunbeam openrc > ~/admin-openrc
cp ~/demo-openrc.avant-tls ~/demo-openrc
```

✅ **Attendu** (18 octobre) : `OpenStack Tls Self-signed application disabled.` en 2 min 40 s ; `tls.self-signed` n’est plus coché dans `sunbeam list-features`. Le nouvel `admin-openrc` est identique à celui d’avant la démo (`diff` avec `~/admin-openrc.avant-tls` : aucune différence, mot de passe compris).

⚠ **Le cloud n’est pas tout de suite utilisable.** La commande rend la main avant que les charms aient fini. Constaté pendant **une dizaine de minutes** :

| Symptôme | Durée constatée |
|---|---|
| `openstack network list` : `503 … The Keystone service is temporarily unavailable` | 9 minutes |
| Adresses `admin` et `internal` de Keystone encore en `https://` dans `openstack endpoint list` | 5 minutes |
| `nova-compute` `down` (`DiscoveryFailure` dans son journal : il cherchait Keystone en HTTPS), puis relancé tout seul | jusqu’à 10 minutes |
| `traefik-public/0` en `maintenance` | quelques minutes |

Attendre que tout soit revenu avant de rendre le cloud :

```bash
source ~/admin-openrc
openstack endpoint list -c URL -f value | grep -c https          # attendu : 0
(source ~/demo-openrc; openstack network list -c Name)           # attendu : demo-network, external-network
openstack compute service list -c Binary -c State                # attendu : trois services up
juju status -m openstack --format short | grep -v "workload:active"   # attendu : aucune ligne
rm -f ~/admin-openrc.avant-tls ~/demo-openrc.avant-tls
```

Sur Windows, retirer la CA de Sunbeam si elle a été importée : `certlm.msc` → **Autorités de certification racines de confiance** → **Certificats** → supprimer `internal-ca`. En cas de doute, restaurer l’instantané VirtualBox.

## À retenir

- Par défaut, Sunbeam chiffre ses flux de **contrôle** (Juju, OVN), mais laisse les **API** en HTTP : jetons et mots de passe circulent en clair, y compris ceux des comptes de service sur l’interface interne.
- TLS s’active par une **fonctionnalité** de Sunbeam (`tls.self-signed`, `tls.ca`, `tls.vault`), sur les adresses `public`, `internal` et `rgw`.
- Activer TLS, c’est aussi **gérer** : distribuer la CA aux clients, surveiller les dates d’expiration, renouveler.
- Durcir : jamais de `--insecure`, l’interne aussi, une CA d’entreprise en production.
