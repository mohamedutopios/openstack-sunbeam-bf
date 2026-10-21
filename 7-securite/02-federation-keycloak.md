# Démo 2 : fédération d’identité, une autorité d’authentification externe

> **Statut : rejouée sur le lab les 18 et 20 octobre 2026** (le 20 : étapes 0a à 7b, TLS compris, à partir d’un cloud en HTTP) (Sunbeam 2024.1, snap rev 1101 ; charms `keystone-k8s` rev 440, `keystone-saml-k8s` rev 134). Réorganisée le 20 octobre 2026 en un enchaînement **sans essai infructueux**, avec, pour chaque étape, ce qu’on cherche à obtenir, et, pour **chaque commande**, ce qu’elle fait et pourquoi on la tape. Les sorties citées sont celles du 18 octobre. Support : module 11.

**Comment lire cette démo.** Chaque étape a quatre parties : *Pourquoi maintenant* (ce qui manque, ce qu’on va obtenir), les commandes, un tableau *Ligne par ligne* qui explique chaque commande et chaque option, puis *Ce qu’on a maintenant*. Les commandes se tapent **dans Lab-Sunbeam** (`ssh vagrant@192.168.56.10`), sauf quand l’étape dit Lab-Services, Windows ou Keycloak.

## Ce qu’on veut obtenir

Aujourd’hui, pour entrer dans le cloud, il faut un compte **dans Keystone**, avec un mot de passe **stocké dans Keystone**. Chaque application de l’entreprise fait pareil : un compte ici, un compte là, un mot de passe partout. Quand une personne arrive, part, ou perd son mot de passe, il faut passer sur chaque application.

À la fin de la démo, `alice`, une salariée, entre dans le cloud **avec son compte d’entreprise** (Keycloak), **sans qu’OpenStack connaisse son mot de passe**, et avec **exactement** les droits qu’on a décidés : `member` sur un projet, rien de plus. Et quand on la désactive dans Keycloak, elle ne peut plus entrer nulle part.

## 2.1 Comprendre avant de faire

### Deux métiers qu’on sépare

Keystone fait aujourd’hui deux choses à la fois :

| Métier | Question à laquelle il répond | Aujourd’hui | Après la démo |
|---|---|---|---|
| **Authentification** | « Es-tu bien alice ? » | Keystone compare le mot de passe à celui qu’il stocke | **Keycloak** vérifie le mot de passe ; Keystone ne le voit jamais |
| **Autorisation** | « Qu’est-ce qu’alice a le droit de faire ? » | Keystone : rôles, projets | **Keystone**, toujours : la fédération ne change rien aux droits |

C’est le point à retenir avant tout : **la fédération déplace l’authentification, pas l’autorisation**. Keycloak dit *qui* ; Keystone dit *quoi*.

### L’image à garder : le passeport et la douane

- **Keycloak est l’État qui délivre les passeports.** Il connaît les personnes, vérifie leur mot de passe, peut suspendre un passeport.
- **Keystone est la douane du cloud.** Elle ne connaît pas les gens. Elle accepte un passeport **si elle reconnaît le tampon de l’État qui l’a émis**, puis décide, selon ses règles, où la personne peut aller.
- **L’assertion SAML est le passeport** : un document signé par Keycloak qui dit « cette personne est alice ».
- **Le mapping est la règle de la douane** : « un passeport de cet État donne accès à telle zone ».

Toute la démo consiste à établir la confiance entre l’État et la douane, **dans les deux sens**, puis à écrire la règle de la douane.

### Le trajet d’une connexion (SAML 2)

```text
 Navigateur            Keystone (douane)                        Keycloak (État)
     │  1. alice demande à entrer                │                      │
     │──────────────────────────────────────────►│                      │
     │  2. « va chercher ton passeport » : redirection, demande signée  │
     │◄──────────────────────────────────────────│                      │
     │  3. alice saisit son mot de passe ──────────────────────────────►│  politique de mots de passe,
     │                                                                   │  verrouillage, MFA : ICI
     │  4. Keycloak renvoie le passeport : assertion SAML signée        │
     │◄──────────────────────────────────────────────────────────────── │
     │  5. le navigateur le présente à Keystone ─►│                      │
     │                                           │ 6. Keystone vérifie le tampon (signature),
     │                                           │    applique la règle (MAPPING) : alice entre
     │  7. jeton Keystone                        │    dans le groupe lab_members → member sur formation
     │◄──────────────────────────────────────────│                      │
```

Le mot de passe d’`alice` passe entre le navigateur et Keycloak (flèche 3), **jamais** par OpenStack. Keystone ne reçoit que le passeport (flèche 5), et il ne peut l’accepter que s’il reconnaît la signature de Keycloak.

### Ce qu’il faut construire, et dans quel ordre

Pour que le trajet ci-dessus fonctionne, il manque aujourd’hui six choses. L’ordre n’est pas arbitraire : chaque étape produit ce dont la suivante a besoin.

| Il manque… | Étape | Ce qu’elle produit, et qui le consomme |
|---|---|---|
| La personne | 1 | `alice` dans Keycloak ; utilisée à l’étape 7 |
| Un moyen pour Keystone de **signer** ses demandes (flèche 2) | 2 | Une paire de clés ; son certificat sera dans les métadonnées de Keystone (étape 5) |
| La **carte d’identité de Keycloak** : son nom, ses adresses, sa clé de signature | 3 | Le fichier `keycloak-idp.xml` ; lu par le charm (étape 4) et par Keystone (étape 6) |
| Que **Keystone reconnaisse Keycloak** (sens 1 de la confiance) | 4 | Le module SAML de Keystone configuré ; Keystone publie alors **sa** carte d’identité |
| Que **Keycloak reconnaisse Keystone** (sens 2) | 5 | Un « client » dans Keycloak, créé à partir de la carte d’identité de Keystone |
| La **règle de la douane** et la zone où elle mène | 6 | Domaine, groupe, projet, fournisseur, mapping |

Puis on teste (7), on montre le gain (8), on affine la règle comme en entreprise (9), on traite le cas des scripts (10), et on accueille un deuxième utilisateur sans toucher à OpenStack (11).

### Pourquoi on passe par Juju, et pas par `sunbeam identity provider add`

Sunbeam prévoit une commande pour l’étape 4 : `sunbeam identity provider add generic saml2 …`. Sur ce lab (snap rev 1101), elle ne sait pas prendre une **CA privée** comme celle du lab, et Keycloak est signé par cette CA. On fait donc directement ce que Sunbeam ferait (lu dans son plan Terraform, ressource `sso-saml2-providers`) : déployer le charm `keystone-saml-k8s` et l’intégrer à Keystone. Conséquence : `sunbeam identity provider list` ne connaîtra pas ce fournisseur, et le retour arrière se fera aussi avec Juju.

## Le plan de la démo

| Étape | Où | Ce qu’on obtient | Durée |
|---|---|---|---|
| 0 | Lab-Sunbeam, Lab-Services, Windows | Le cloud est en HTTPS (activé ici si la démo 1 n’a pas été jouée), les deux VM peuvent se parler en vérifiant leurs certificats | 5 min, ou 20 min avec le TLS |
| 1 | Keycloak (navigateur) | La personne existe, dans Keycloak seulement | 3 min |
| 2 | Lab-Sunbeam | Keystone peut signer ses demandes | 2 min |
| 3 | Lab-Sunbeam | On a la carte d’identité de Keycloak | 1 min |
| 4 | Lab-Sunbeam (Juju) | Keystone reconnaît Keycloak, et publie sa propre carte d’identité | 10 min d’attente |
| 5 | Lab-Sunbeam, puis Keycloak | Keycloak reconnaît Keystone : la confiance est réciproque | 5 min |
| 6 | Lab-Sunbeam | La règle de la douane : qui entre, et où | 3 min |
| 7 | Navigateur et Lab-Sunbeam | `alice` entre, avec les droits prévus et pas plus | 5 min |
| 8 | Keycloak et Lab-Sunbeam | Un seul interrupteur pour la couper de tout | 3 min |
| 9 | Lab-Sunbeam | Seule son équipe entre, pas toute l’entreprise | 3 min |
| 10 | Lab-Sunbeam | Ses scripts tournent sans son mot de passe | 3 min |
| 11 | Keycloak, puis Lab-Sunbeam | Un deuxième utilisateur arrive : zéro commande OpenStack | 5 min |
| — | Lab-Sunbeam, Keycloak | Retour arrière | 10 min |

## Étape 0 · Prérequis : les deux VM doivent pouvoir se faire confiance

**Pourquoi maintenant.** Tout ce qui suit fait dialoguer Lab-Sunbeam et Keycloak en HTTPS. Or chacun a un certificat signé par une autorité **privée** : la CA du lab pour Keycloak, la CA de Sunbeam pour le cloud. Sans la CA de l’autre, chaque côté refuserait de parler (« certificat inconnu »). Et le cloud lui-même doit être en HTTPS : à l’étape 7, le passeport transite par le navigateur ; en HTTP, il serait lisible et rejouable par quiconque écoute le réseau. Cette démo se joue **sans avoir fait la démo 1** : l’activation du TLS est reprise en 0a.

### 0a · Le cloud doit être en HTTPS : l’activer si ce n’est pas fait

**Pourquoi c’est obligatoire.** À l’étape 7, le passeport d’`alice` (l’assertion SAML) sera posté par son navigateur vers Keystone. En HTTP, il passerait **en clair** sur le réseau : quiconque écoute pourrait le copier et le rejouer, et entrer à la place d’`alice`. En HTTPS, le navigateur chiffre tout vers `cloud.lab.test`. De plus, Keycloak refuse de renvoyer une assertion vers une adresse `http://` : il exige une adresse de retour sûre.

Vérifier d’abord :

```bash
sunbeam dashboard url
```

| Réponse | Situation |
|---|---|
| `https://cloud.lab.test/openstack-horizon` | Le TLS est actif (démo 1 déjà jouée) : passer à 0b |
| `http://cloud.lab.test:80/openstack-horizon` | Le cloud est en HTTP : faire ce qui suit |

**Activer le TLS** (c’est l’étape 1.3 de la démo 1, reprise ici pour que la démo 2 se joue seule) :

```bash
cp ~/admin-openrc ~/admin-openrc.avant-tls
cp ~/demo-openrc ~/demo-openrc.avant-tls
time sunbeam enable tls self-signed --endpoint public --endpoint internal
```

| Ligne | Ce qu’elle fait | Pourquoi |
|---|---|---|
| `cp ~/admin-openrc ~/admin-openrc.avant-tls` | Garde une copie du fichier d’accès administrateur | Après le TLS, l’ancien ne marchera plus ; la copie sert au retour arrière de la démo 1 |
| `cp ~/demo-openrc …` | Idem pour le compte `demo` | |
| `time` | Mesure la durée | Pour montrer que c’est long, et que c’est normal |
| `sunbeam enable tls self-signed` | Active la fonctionnalité TLS de Sunbeam en mode **auto-signé** : Sunbeam crée sa propre autorité de certification (`internal-ca`, dans le charm `certificate-authority`) et émet les certificats | La solution sans infrastructure : pas besoin d’une CA d’entreprise ni de Vault. En production, on utiliserait `tls ca` (CA de l’entreprise) ou `tls vault` |
| `--endpoint public --endpoint internal` | Les deux adresses à passer en HTTPS : `cloud.lab.test` (clients, Horizon, navigateur d’`alice`) et `internal.lab.test` (les services entre eux) | On laisse `rgw` (stockage objet) en HTTP : pas utilisé dans ces démos |

**Ce qui se passe pendant l’attente** (observé le 18 octobre, 14 minutes) : `certificate-authority` signe un certificat pour chacun des deux Traefik, qui se mettent à servir en HTTPS ; puis **tous** les charms OpenStack mettent à jour leurs adresses dans le catalogue Keystone (`http://` → `https://`) et redémarrent. La charge de la VM monte fortement. Le message `OpenStack Tls Self-signed application enabled.` apparaît après 2 minutes, mais la commande continue d’attendre que tout soit stable : **ne pas l’interrompre**. À suivre dans une seconde session :

```bash
watch -n 15 "juju status -m openstack --format short | grep -v workload:active"
```

(`--format short` : une ligne par unité ; `grep -v workload:active` : n’afficher que celles qui ne sont **pas** encore `active`. L’écran se vide quand tout est prêt.)

✅ **Attendu :** `OpenStack Tls Self-signed application enabled.`, puis `Waiting for the applications to settle … waiting for services to come online (0/3)`, un compteur qui **monte et redescend** (`2/3`, `1/3`, `2/3`…), et enfin `real 13m53…`.

**Comment lire le compteur.** Les « 3 » sont `certificate-authority`, `traefik-public` et `traefik`. Un Traefik compte comme en ligne, reçoit son certificat, redémarre, repasse hors ligne, revient : le compteur oscille. Sunbeam attend que les trois soient **stables en même temps**. Observé le 20 octobre : `0/3 → 2/3 → 1/3 → 2/3 → 2/3`, puis fin.

#### Pendant l’attente : ce qui est normal, et ce qui ne l’est pas

| Durée depuis le lancement | Normal | À vérifier |
|---|---|---|
| 0 à 2 min | Rien ne s’affiche, puis `application enabled` | — |
| 2 à 15 min | Compteur qui oscille ; `watch` montre des unités en `maintenance` ou `waiting` qui changent ; `uptime` donne une charge de 20 à 30 | — |
| 15 à 25 min | Encore possible sur un PC chargé | Lancer les trois contrôles ci-dessous |
| Plus de 25 min, ou compteur figé sur la même valeur depuis 10 min | Pas normal | Les trois contrôles, puis le tableau des causes |

**Les trois contrôles, dans une seconde session** (ne pas interrompre la commande `sunbeam`) :

```bash
uptime
juju status -m openstack certificate-authority traefik-public traefik
juju status -m openstack --format short | grep -v workload:active
```

| Commande | Ce qu’elle dit | Bon signe | Mauvais signe |
|---|---|---|---|
| `uptime` | La charge de la VM (trois moyennes : 1, 5, 15 minutes) | Première valeur qui **baisse** d’un contrôle à l’autre, même si elle est à 20 | Première valeur qui monte sans fin, ou au-dessus de 40 : la VM est saturée (hôte en manque de mémoire, voir guide apprenant, étape 1) |
| `juju status … certificate-authority traefik-public traefik` | Les trois applications que Sunbeam attend | Les trois en `active idle`, Traefik avec `Serving at https://…` : le TLS est **fait**, Sunbeam termine | Une unité en `error`, ou en `maintenance` avec le même message depuis 10 min |
| `juju status --format short \| grep -v workload:active` | Tout ce qui n’est pas encore stable dans le modèle | La liste **raccourcit** d’un contrôle à l’autre | Les mêmes unités depuis 10 min, ou une unité `error` |

**Ce que fait la commande `sunbeam` entre-temps :** une fois les trois applications stables, elle rend la main. Si `juju status` montre les trois en `active idle` et `Serving at https://` depuis plusieurs minutes alors que `sunbeam` affiche toujours `Waiting`, elle est en train de terminer : encore une ou deux minutes.

| Ce que montre le contrôle | Cause | Que faire |
|---|---|---|
| Un `*-mysql-router` en `error` (`hook failed`) | Un routeur a tenté de joindre la base pendant un redémarrage | `juju resolved -m openstack <unité>` (DEPANNAGE-SERVICES.md) ; la commande `sunbeam` reprend seule |
| `traefik-public` ou `traefik` en `maintenance` depuis 10 min, charge qui baisse | Le charm attend un certificat que `certificate-authority` n’a pas encore émis | `juju status -m openstack certificate-authority` ; si `error` : `juju resolved` ; sinon attendre encore 5 min |
| Charge qui ne baisse pas, tout reste en `maintenance` | VM saturée : l’hôte manque de mémoire ou de CPU | Fermer ce qui tourne sur le PC ; ne rien relancer ; attendre. Un `Ctrl+C` ne ferait que laisser le cloud à moitié configuré |
| La commande `sunbeam` se termine sur `Error: … timed out` | Sunbeam a cessé d’attendre, mais les charms continuent | Attendre que `grep -v workload:active` soit vide, puis vérifier avec `sunbeam list-features \| grep tls` (doit montrer `X`) et `sunbeam dashboard url` (doit être en `https://`). Si c’est bon, continuer ; sinon relancer la même commande `sunbeam enable tls …`, qui reprend où elle en était |

**Si on a interrompu par `Ctrl+C`** (à ne pas faire, mais ça arrive) : les charms continuent leur travail indépendamment de la commande. Attendre que `grep -v workload:active` soit vide, puis faire les deux vérifications ci-dessus (`list-features`, `dashboard url`). Si le TLS est actif, continuer normalement ; sinon, relancer la commande `sunbeam enable tls …`.

**Régénérer les fichiers d’accès.** Les adresses du catalogue ont changé, et il faut dire au client quelle CA croire : l’ancien `admin-openrc` donne maintenant `CERTIFICATE_VERIFY_FAILED`.

```bash
sunbeam openrc > ~/admin-openrc.new && mv ~/admin-openrc.new ~/admin-openrc && grep -c "^export OS_" ~/admin-openrc
source ~/admin-openrc
echo "$OS_AUTH_URL"; echo "$OS_CACERT"
openstack token issue -c expires
```

| Ligne | Ce qu’elle fait |
|---|---|
| `sunbeam openrc > ~/admin-openrc.new` | Sunbeam régénère le fichier d’accès administrateur, maintenant avec `https://` et la ligne `OS_CACERT` (le chemin de la CA de Sunbeam, `ca_bundle.pem`). Il interroge Juju pour cela : **30 secondes à 2 minutes** juste après le TLS, la VM étant encore chargée. On écrit dans un fichier temporaire, pas directement dans `~/admin-openrc` |
| `&& mv ~/admin-openrc.new ~/admin-openrc` | **Seulement si** la commande précédente a réussi (`&&`), remplacer l’ancien fichier. Si `sunbeam openrc` échoue ou est interrompu par `Ctrl+C`, l’ancien fichier reste intact. Constaté : avec un simple `>`, une interruption laisse un `admin-openrc` vide |
| `&& grep -c "^export OS_" ~/admin-openrc` | Compter les lignes `export OS_…` du nouveau fichier |
| `source ~/admin-openrc` | Recharge les variables dans la session |
| `echo …` | Vérifier les deux valeurs qui comptent pour la suite |
| `openstack token issue -c expires` | Prouver que le client parle au cloud en HTTPS et accepte son certificat. Le premier appel après le TLS peut prendre 30 secondes : laisser finir |

✅ **Attendu :** `10` (les 9 lignes d’avant plus `OS_CACERT`), puis `https://cloud.lab.test/openstack-keystone/v3`, `/home/vagrant/.config/openstack/ca_bundle.pem`, puis une date d’expiration.

⚠ Ne pas enchaîner ces commandes avec `;` sur une seule ligne, et ne pas interrompre : `uptime` montre une charge de 20 à 30 pendant un quart d’heure après le TLS (constaté), et chaque commande est lente. Une par une, en attendant le résultat.

**Si ça traîne ou si ça échoue :**

| Symptôme | Cause | Que faire |
|---|---|---|
| `sunbeam openrc` ne répond pas après 2 min | Juju est lent : la VM est encore chargée | `uptime` ; attendre que la première valeur passe sous 15, puis relancer |
| `grep -c` affiche `0` ou moins de `10` | `sunbeam openrc` a été interrompu avec un simple `>` : fichier vide ou tronqué | Relancer la ligne 1 telle qu’écrite ici (forme `.new && mv`) |
| `echo "$OS_AUTH_URL"` affiche encore `http://` | Le `source` a chargé un ancien fichier, ou le TLS n’est pas actif | `sunbeam dashboard url` : si `http://`, revenir à l’activation ; si `https://`, refaire `sunbeam openrc` et `source` |
| `echo "$OS_CACERT"` vide | Même cause | Idem |
| `openstack token issue` : `CERTIFICATE_VERIFY_FAILED` | Le client ne connaît pas la CA : `OS_CACERT` absent de la session | `source ~/admin-openrc` à nouveau, puis réessayer |
| `openstack token issue` : `HTTP 500` ou `503` | Keystone ou un routeur MySQL redémarre encore | `juju status -m openstack keystone keystone-mysql-router` ; `juju resolved` si `error` ; sinon attendre 2 min |
| Le client reste muet 30 s puis répond | Premier chargement de Python et des greffons sur une VM chargée | Normal, laisser finir |

`sunbeam openrc` ne génère que le fichier administrateur. Mettre à jour `~/demo-openrc` à la main (utile pour la démo 5, pas pour celle-ci) :

```bash
sed -i "s|^export OS_AUTH_URL=http://|export OS_AUTH_URL=https://|" ~/demo-openrc
echo >> ~/demo-openrc
grep "OS_CACERT" ~/admin-openrc >> ~/demo-openrc
```

| Ligne | Ce qu’elle fait |
|---|---|
| `sed -i "s\|…http://\|…https://\|" ~/demo-openrc` | Remplace (`s`), **dans le fichier** (`-i`), `http://` par `https://` sur la ligne `OS_AUTH_URL`. Le `\|` sert de séparateur parce que le motif contient des `/` |
| `echo >> ~/demo-openrc` | Ajoute une ligne vide à la fin (`>>` : ajouter sans écraser). Constaté : le fichier n’avait pas de retour à la ligne final, et la ligne suivante se collait à la précédente |
| `grep "OS_CACERT" ~/admin-openrc >> ~/demo-openrc` | Copie la ligne `OS_CACERT` du fichier admin à la fin du fichier demo |

**Ce qu’on a maintenant :** un cloud en HTTPS, signé par la CA de Sunbeam (`internal-ca`), et un `admin-openrc` qui sait la vérifier. C’est cette CA, `$OS_CACERT`, qu’on utilisera à chaque `curl` vers `cloud.lab.test`.

### 0b · Deux autres vérifications

| Prérequis | Où | Commande | Attendu | Si non |
|---|---|---|---|---|
| Keycloak tourne | Lab-Services | `cd ~/lab/keycloak && docker compose ps` | deux lignes, `keycloak` et `postgres`, état `Up` | `docker compose up -d` |
| Le **pod** Keystone résout `sso.lab.test` | Lab-Sunbeam | `sudo k8s kubectl -n openstack exec keystone-0 -c keystone -- getent hosts sso.lab.test` | `192.168.56.20   sso.lab.test` | Guide Keycloak, section 10 |

**Ligne par ligne, la troisième commande :**

| Morceau | Ce qu’il fait |
|---|---|
| `sudo k8s kubectl` | La commande Kubernetes du snap `k8s`, qui exige `sudo` |
| `-n openstack` | Dans l’espace de noms `openstack`, celui où Juju a mis tous les services |
| `exec keystone-0` | Exécute une commande **dans** le pod `keystone-0` |
| `-c keystone` | Dans son conteneur `keystone` (le pod en a deux : `charm` et `keystone`) |
| `--` | Tout ce qui suit est la commande à exécuter dans le pod, pas une option de `kubectl` |
| `getent hosts sso.lab.test` | Demande au DNS **du pod** l’adresse de `sso.lab.test` |

**Pourquoi tester dans le pod et pas dans la VM :** c’est le charm, qui tourne dans le pod, qui ira télécharger les métadonnées de Keycloak à l’étape 4. Le pod a son propre DNS (CoreDNS), différent de celui de la VM. Si la VM résout le nom mais pas le pod, l’étape 4 restera bloquée sur `Failed to get IDP metadata`.

### 0c · Copier les fichiers

Depuis Windows, dans le dossier du dépôt (PowerShell), **en une fois** :

```powershell
scp .\ca.crt .\lab-sunbeam\mapping.json .\lab-sunbeam\scripts\extract-sp.py .\7-securite\outils\test-sso-saml.py vagrant@192.168.56.10:~/
```

| Morceau | Ce qu’il fait |
|---|---|
| `scp` | Copie des fichiers par SSH (*secure copy*) |
| `.\ca.crt …` (quatre chemins) | Les fichiers à copier, dans le dépôt sur Windows |
| `vagrant@192.168.56.10:~/` | La destination : le dossier personnel du compte `vagrant` sur Lab-Sunbeam. Le `:` sépare la machine du chemin |

| Fichier | À quoi il servira |
|---|---|
| `ca.crt` | La CA du **lab**, qui a signé le certificat de Keycloak. C’est elle qui permet à Lab-Sunbeam de vérifier qu’il parle au vrai Keycloak (étapes 3 et 4) |
| `mapping.json` | La règle de la douane (étape 6) |
| `extract-sp.py` | Lit la carte d’identité de Keystone pour la recopier dans Keycloak (étape 5) |
| `test-sso-saml.py` | Joue la connexion d’`alice` sans navigateur, en affichant chaque flèche du schéma (étape 7) |

### 0d · Vérifier la CA et l’accès à Keycloak

Sur **Lab-Sunbeam** :

```bash
tr -d '\r' < ~/ca.crt > ~/ca-lf.crt
openssl x509 -in ~/ca-lf.crt -noout -subject
curl -s --fail --cacert ~/ca-lf.crt https://sso.lab.test:8443/realms/lab -o /dev/null && echo OK
```

**Ligne 1 : nettoyer le fichier.** `ca.crt` a traversé Windows et le dépôt git, qui ont pu lui mettre des fins de ligne Windows (`\r\n`, retour chariot + saut de ligne) à la place des fins de ligne Linux (`\n`). Les outils de certificats, dont le charm de l’étape 4, refusent un certificat avec des `\r` : « certificat invalide », sans plus de détail. On fabrique donc une copie propre.

| Morceau | Ce qu’il fait |
|---|---|
| `tr -d '\r'` | `tr` transforme des caractères ; `-d` (*delete*) les supprime ; `'\r'` est le retour chariot. Donc : supprime tous les retours chariot |
| `< ~/ca.crt` | Lit le fichier d’origine comme entrée |
| `> ~/ca-lf.crt` | Écrit le résultat dans un nouveau fichier (`lf` pour *line feed*, fin de ligne Linux). On ne modifie pas l’original |

**Ligne 2 : s’assurer qu’on a le bon certificat.** Un fichier `ca.crt` peut être n’importe quoi : une vieille copie, un autre lab. On lui demande de dire qui il est.

| Morceau | Ce qu’il fait |
|---|---|
| `openssl x509` | L’outil `openssl`, sous-commande `x509` : lire et manipuler un certificat (le format des certificats s’appelle X.509) |
| `-in ~/ca-lf.crt` | Le certificat à lire |
| `-noout` | Ne pas réafficher le certificat lui-même (un gros bloc en base64, inutile ici) |
| `-subject` | Afficher seulement son **sujet** : le nom inscrit dedans |

✅ **Attendu :** `subject=CN = Sunbeam Lab Root CA`. `CN` (*Common Name*) est le nom de l’autorité. C’est le nom donné à la CA quand le lab a été construit (`init-keycloak.sh`) : on a le bon fichier.

**Ligne 3 : prouver que cette CA permet de joindre Keycloak.** C’est exactement ce que le charm fera à l’étape 4 : une requête HTTPS vers Keycloak, en vérifiant son certificat avec cette CA. Si ça échoue ici, ça échouera là-bas.

| Morceau | Ce qu’il fait |
|---|---|
| `curl` | Fait une requête HTTP ou HTTPS |
| `-s` | *silent* : pas de barre de progression |
| `--fail` | Si le serveur répond une erreur (404, 500…), `curl` échoue au lieu d’afficher la page d’erreur. Indispensable pour le `&&` qui suit |
| `--cacert ~/ca-lf.crt` | **Le point clé** : vérifier le certificat du serveur avec **cette** CA, et non avec celles du système, qui ne connaissent pas le lab. Sans cette option, `curl` refuserait : `SSL certificate problem: unable to get local issuer certificate` |
| `https://sso.lab.test:8443/realms/lab` | L’adresse du realm `lab` de Keycloak : une page qui existe toujours quand Keycloak tourne |
| `-o /dev/null` | Jeter la réponse (on ne veut pas lire la page, juste savoir qu’elle arrive) |
| `&& echo OK` | `&&` : « et si ça a réussi » ; alors afficher `OK`. Si `curl` échoue, rien ne s’affiche |

✅ **Attendu :** `OK`.

**Ce que ça prouve :** Lab-Sunbeam sait résoudre `sso.lab.test`, Keycloak répond, et **son certificat est vérifié** par la CA du lab, sans `-k` (l’option qui désactiverait la vérification : à ne jamais utiliser ici, elle masquerait précisément ce qu’on veut tester).

**Rappel (démo 1) :** deux CA coexistent. La CA du **lab** (`~/ca-lf.crt`) signe le certificat de Keycloak ; la CA de **Sunbeam** (`$OS_CACERT`, dans `~/admin-openrc`) signe celui du cloud. Chaque `curl` de cette démo utilise la bonne : vers `sso.lab.test`, la première ; vers `cloud.lab.test`, la seconde.

**Ce qu’on a maintenant :** Lab-Sunbeam peut parler à Keycloak en vérifiant son identité. Rien n’est encore configuré.

## Étape 1 · Keycloak : la personne existe, et seulement là

**Pourquoi maintenant.** Le but de la fédération est que la personne n’existe **que** dans l’annuaire de l’entreprise. On commence donc par là, et on ne créera jamais `alice` dans Keystone. En entreprise, Keycloak serait lui-même relié à l’Active Directory ; ici, on crée la personne dans le realm `lab`.

On crée aussi son **équipe**, le groupe `openstack-formation`. Il ne sert pas tout de suite : à l’étape 9, on s’en servira pour n’admettre dans le cloud que cette équipe, et pas toute l’entreprise. Le créer maintenant évite de revenir dans Keycloak plus tard.

### 1a · Le mot de passe de l’administrateur de Keycloak

Sur **Lab-Services** :

```bash
grep KEYCLOAK_ADMIN_PASSWORD ~/lab/keycloak/.env
```

| Morceau | Ce qu’il fait |
|---|---|
| `grep KEYCLOAK_ADMIN_PASSWORD` | Affiche les lignes qui contiennent ce texte |
| `~/lab/keycloak/.env` | Le fichier où `init-keycloak.sh` a écrit les mots de passe générés à la construction du lab (celui de PostgreSQL et celui de l’administrateur Keycloak) |

Ce mot de passe a été tiré au hasard à la construction du lab ; personne ne le connaît par cœur, d’où cette lecture. **Ne pas le projeter** : c’est le compte qui contrôle toutes les identités.

### 1b · Dans la console Keycloak

Sur Windows, ouvrir **https://sso.lab.test:8443/admin/** et se connecter avec `kcadmin` et ce mot de passe. Pas d’alerte de certificat : la CA du lab est approuvée sur Windows.

1. En haut à gauche, choisir le realm **lab**, et non `master`. Un **realm** est un espace d’identité indépendant, avec ses utilisateurs, ses groupes, ses clients : l’équivalent d’un domaine Keystone. `master` est le realm qui administre Keycloak lui-même ; on n’y met jamais d’utilisateurs applicatifs.
2. **Groups → Create group** : *Name* `openstack-formation` → **Create**. C’est l’équipe qui aura le droit d’entrer dans le cloud (étape 9).
3. **Users → Add user** : *Username* `alice`, *Email* `alice@lab.test`, *First name* `Alice`, ***Last name*** `Martin`, *Email verified* activé → **Create**.
4. Onglet **Credentials → Set password** : un mot de passe d’au moins 12 caractères, *Temporary* **désactivé** → **Save**.
5. Onglet **Groups → Join Group** : cocher `openstack-formation` → **Join**.

✅ **Attendu :** `alice` apparaît dans **Users**, `Enabled`, et son onglet *Groups* affiche `openstack-formation`.

**Deux réglages à ne pas sauter, et pourquoi :**

| Réglage | Pourquoi |
|---|---|
| *Last name* renseigné | Keycloak 26 exige un profil complet. Sans nom de famille, après le mot de passe, Keycloak affiche *Update Account Information* au lieu de renvoyer `alice` vers OpenStack : la démo s’arrête sur une page inattendue |
| *Email verified* activé | Sinon, Keycloak peut demander une vérification d’adresse avant de délivrer le passeport |
| *Temporary* désactivé | Activé, il obligerait `alice` à changer son mot de passe à la première connexion : c’est la bonne pratique en production (ANSSI R30, démo 3), désactivée ici pour que la démo reste courte |

**Ce qu’on a maintenant :** une personne qui peut s’authentifier auprès de Keycloak, et rien d’autre. Keystone ignore son existence, et c’est voulu.

## Étape 2 · Keystone obtient de quoi signer ses demandes

**Pourquoi maintenant.** Regardons la flèche 2 du schéma : Keystone renvoie le navigateur vers Keycloak avec une *demande* d’authentification. Si cette demande n’était pas signée, n’importe quel site pourrait en fabriquer une (« je suis Keystone, envoie-moi le passeport d’alice ») et récupérer l’assertion. Keycloak ne répondra donc qu’aux demandes **signées par une clé qu’il connaît**. Il faut cette clé **avant** tout le reste, parce que son certificat fera partie de la carte d’identité de Keystone (étape 5) : c’est par lui que Keycloak apprendra à reconnaître Keystone.

Signer, en cryptographie, c’est avoir une **clé privée** (gardée secrète, elle signe) et un **certificat** (public, il contient la clé qui permet de vérifier la signature). On fabrique les deux, puis on les confie à Keystone.

```bash
umask 077
mkdir -p ~/saml
openssl req -x509 -newkey rsa:3072 -nodes -days 365 \
  -keyout ~/saml/sp.key -out ~/saml/sp.crt -subj '/CN=Keystone SAML Lab'
time sunbeam identity set-saml-x509 ~/saml/sp.crt ~/saml/sp.key
juju config -m openstack keystone saml-x509-keypair
```

**Ligne 1 : `umask 077`.** Avant de créer une clé privée, on règle les droits par défaut des fichiers à venir : `077` signifie « lisible et modifiable par moi seul, rien pour les autres ». Sans cela, `sp.key` serait lisible par tout utilisateur de la VM, et qui lit cette clé peut se faire passer pour Keystone auprès de Keycloak. L’effet dure jusqu’à la fin de la session SSH.

**Ligne 2 : `mkdir -p ~/saml`.** Un dossier pour ranger la paire. `-p` : ne pas se plaindre s’il existe déjà.

**Ligne 3 : fabriquer la clé et le certificat.**

| Morceau | Ce qu’il fait |
|---|---|
| `openssl req` | Sous-commande qui fabrique des demandes de certificat et, avec `-x509`, des certificats directement |
| `-x509` | Produire un certificat **auto-signé** (signé par sa propre clé), et non une demande à faire signer par une autorité. Auto-signé suffit ici : à l’étape 5, Keycloak recevra ce certificat **directement**, dans les métadonnées de Keystone ; il n’a pas besoin d’une CA pour lui faire confiance |
| `-newkey rsa:3072` | Fabriquer en même temps une nouvelle clé RSA de 3 072 bits (la taille recommandée aujourd’hui ; 2 048 est le minimum) |
| `-nodes` | *no DES* : ne pas protéger la clé par une phrase secrète. Keystone doit pouvoir l’utiliser sans qu’un humain tape quelque chose |
| `-days 365` | Certificat valable un an. Après, il faudra refaire cette étape et l’étape 5 |
| `-keyout ~/saml/sp.key` | Où écrire la **clé privée** |
| `-out ~/saml/sp.crt` | Où écrire le **certificat** (public) |
| `-subj '/CN=Keystone SAML Lab'` | Le nom inscrit dans le certificat. Sans `-subj`, `openssl` poserait six questions interactives (pays, ville…) ; on y répond d’un coup, avec le seul champ utile, `CN` |

`sp` signifie *Service Provider* : c’est le nom de Keystone dans le vocabulaire SAML (voir 2.1).

**Ligne 4 : confier la paire à Keystone.**

| Morceau | Ce qu’il fait |
|---|---|
| `time` | Mesure la durée de la commande qui suit. Simple curiosité : on voit combien de temps prend une reconfiguration de Keystone |
| `sunbeam identity set-saml-x509` | Commande de Sunbeam prévue pour ça : donner à Keystone sa paire de clés SAML |
| `~/saml/sp.crt ~/saml/sp.key` | Le certificat, puis la clé, dans cet ordre |

Ce que fait Sunbeam derrière : il range les deux fichiers dans un **secret Juju** (un coffre : la clé n’apparaît pas en clair dans la configuration) et règle l’option `saml-x509-keypair` du charm Keystone pour pointer dessus. Le charm réécrit alors la configuration du module SAML dans le pod.

**Ligne 5 : vérifier.**

| Morceau | Ce qu’il fait |
|---|---|
| `juju config -m openstack keystone` | Lire la configuration de l’application `keystone` dans le modèle `openstack` |
| `saml-x509-keypair` | Seulement cette option |

✅ **Attendu** (18 octobre) : `set-saml-x509` rend la main sans message, en 45 secondes environ ; `juju config` affiche une référence `secret:…`, et non le contenu : c’est bien un secret, pas une valeur en clair.

⚠ Ce certificat sert à **signer les messages SAML** ; il n’a rien à voir avec le certificat HTTPS du cloud (démo 1), qui sert à chiffrer le transport. Deux usages, deux certificats.

**Ce qu’on a maintenant :** Keystone peut signer, mais il ne sait encore ni où est Keycloak, ni à quoi ressemble sa signature.

## Étape 3 · Récupérer la carte d’identité de Keycloak

**Pourquoi maintenant.** Pour reconnaître le tampon sur un passeport, la douane doit connaître l’État : son nom officiel, ses adresses, sa signature. En SAML, chaque partie publie tout cela dans un fichier XML appelé **métadonnées**. Celles de Keycloak contiennent son identifiant (`entityID`), l’adresse où envoyer les gens s’authentifier, et son certificat de signature. On les télécharge maintenant parce que deux étapes en ont besoin : le charm (étape 4) les lira pour configurer Keystone, et Keystone (étape 6) devra connaître l’`entityID` exact pour n’accepter que les assertions de **ce** Keycloak.

```bash
curl -s --fail --cacert ~/ca-lf.crt https://sso.lab.test:8443/realms/lab/protocol/saml/descriptor -o ~/keycloak-idp.xml
grep -o 'entityID="[^"]*"' ~/keycloak-idp.xml
```

**Ligne 1 : télécharger.** Même `curl` qu’à l’étape 0d, avec deux différences :

| Morceau | Ce qu’il fait |
|---|---|
| `…/realms/lab/protocol/saml/descriptor` | L’adresse où Keycloak publie les métadonnées SAML du realm `lab`. C’est une adresse standard de Keycloak |
| `-o ~/keycloak-idp.xml` | Cette fois, on **garde** la réponse, dans un fichier. `idp` pour *Identity Provider* : le nom de Keycloak dans le vocabulaire SAML |

**Ligne 2 : lire l’essentiel du fichier.** Le fichier XML fait plusieurs kilo-octets ; on en extrait la seule ligne qui compte pour la suite.

| Morceau | Ce qu’il fait |
|---|---|
| `grep -o` | Afficher **seulement** la partie qui correspond au motif (`-o`, *only matching*), pas toute la ligne |
| `'entityID="[^"]*"'` | Le motif : le texte `entityID="`, puis n’importe quoi sauf un guillemet (`[^"]*`), puis un guillemet. Donc : l’attribut `entityID` et sa valeur |

✅ **Attendu** (18 octobre) : `entityID="https://sso.lab.test:8443/realms/lab"`.

**Comment le lire.** L’`entityID` est le **nom officiel** de ce realm Keycloak ; il apparaîtra dans chaque assertion comme émetteur (*Issuer*). Un autre realm, ou un autre Keycloak, aurait un autre `entityID`, et Keystone le refuserait. On le reliera à l’étape 6 sans le retaper.

**Ce qu’on a maintenant :** tout ce qu’il faut savoir sur Keycloak, dans un fichier. Personne ne l’a encore lu.

## Étape 4 · Keystone apprend à reconnaître Keycloak (premier sens de la confiance)

**Pourquoi maintenant.** On a la clé de Keystone (2) et la carte d’identité de Keycloak (3). On peut donc configurer la douane : « voici l’État dont tu dois reconnaître les passeports ». Concrètement, c’est le module SAML d’Apache dans le pod Keystone, `mod_auth_mellon`, qu’il faut configurer. On ne le fait pas à la main (le charm réécrirait tout) : on déploie un charm dédié, `keystone-saml-k8s`, qui porte la configuration d’**un** fournisseur, et on le relie à Keystone.

### 4a · Déployer le fournisseur et le relier à Keystone

```bash
juju deploy -m openstack keystone-saml-k8s keystone-idp-saml2-keycloak --channel 2024.1/stable \
  --config name=keycloak \
  --config label='Keycloak - Lab' \
  --config metadata-url=https://sso.lab.test:8443/realms/lab/protocol/saml/descriptor \
  --config ca-chain="$(base64 -w0 ~/ca-lf.crt)
$(cat ~/ca-lf.crt)"
juju integrate -m openstack keystone-idp-saml2-keycloak:keystone-saml keystone:keystone-saml
```

**Ligne 1 à 6 : une seule commande, `juju deploy`, coupée par des `\`** (le `\` en fin de ligne dit « la commande continue à la ligne suivante »).

| Morceau | Ce qu’il fait |
|---|---|
| `juju deploy -m openstack` | Déployer une application dans le modèle `openstack`, celui où sont tous les services OpenStack |
| `keystone-saml-k8s` | Le **charm** à déployer : le programme, publié par Canonical, qui sait déclarer un fournisseur SAML à Keystone |
| `keystone-idp-saml2-keycloak` | Le **nom** qu’on donne à cette application dans le modèle. On suit la convention de Sunbeam (`keystone-idp-<protocole>-<nom>`) : si un jour Sunbeam sait le faire lui-même, il retrouvera ses petits |
| `--channel 2024.1/stable` | La version du charm : celle qui correspond à notre OpenStack 2024.1 (révision 134 ce jour-là) |
| `--config name=keycloak` | L’identifiant du fournisseur **dans Keystone**. Il entre dans toutes les adresses de fédération (`…/identity_providers/keycloak/…`) ; on le réutilisera tel quel à l’étape 6 |
| `--config label='Keycloak - Lab'` | Le texte que Horizon afficherait dans sa liste de connexion. Entre guillemets simples à cause de l’espace |
| `--config metadata-url=…` | L’adresse de la carte d’identité de Keycloak (étape 3). Le charm la télécharge **lui-même, depuis le pod** : d’où le DNS vérifié à l’étape 0b |
| `--config ca-chain="…"` | La CA du lab, pour que le charm accepte le certificat HTTPS de Keycloak pendant ce téléchargement. Même rôle que `--cacert` à l’étape 0d. Le format est particulier, voir ci-dessous |

**Le format de `ca-chain`, mot par mot.** La valeur entre guillemets contient deux lignes :

| Morceau | Ce qu’il fait |
|---|---|
| `$(…)` | « Remplace par le résultat de la commande entre parenthèses » |
| `base64 -w0 ~/ca-lf.crt` | Le certificat encodé en base64, sur une seule ligne (`-w0` : pas de retour à la ligne tous les 76 caractères) |
| retour à la ligne, puis `$(cat ~/ca-lf.crt)` | Le même certificat, **en clair** cette fois |

**Pourquoi les deux :** en révision 134, le code du charm qui télécharge les métadonnées attend la CA **en base64**, mais son contrôle de validité cherche un bloc `-----BEGIN CERTIFICATE-----` **en clair** dans la même valeur. En mettant les deux, le contrôle trouve le bloc en clair, et le décodage base64 s’arrête au `==` final : il rend exactement la CA. C’est la seule forme qui passe avec cette révision du charm. C’est aussi pour ce charm qu’on a nettoyé les `\r` à l’étape 0d.

**Ligne 7 : relier.**

| Morceau | Ce qu’il fait |
|---|---|
| `juju integrate -m openstack` | Créer une **relation** entre deux applications du modèle. Dans Juju, une relation est un canal par lequel deux charms échangent de la configuration |
| `keystone-idp-saml2-keycloak:keystone-saml` | Premier bout : l'application `keystone-idp-saml2-keycloak`, par son point de relation `keystone-saml` |
| `keystone:keystone-saml` | Second bout : l'application `keystone`, par son point de relation `keystone-saml` |

**Une seule relation, `keystone-saml`, avec deux bouts.** La syntaxe est `application:point-de-relation`, une fois pour chaque application. Les deux points portent le même nom parce qu'ils sont faits pour se brancher l'un sur l'autre : ce n'est pas deux relations, c'est la même vue de chaque côté. Une fois créée, `juju status -m openstack --relations | grep keystone-saml` l'affiche sur une seule ligne, avec ses deux bouts.

Déployer sans relier ne ferait rien : c’est **cette relation** qui envoie à Keystone les métadonnées et la CA, et qui déclenche la réécriture de la configuration de `mod_auth_mellon` dans le pod.

### 4b · Attendre que ce soit prêt

```bash
watch -n 15 "juju status -m openstack keystone-idp-saml2-keycloak keystone horizon"
```

| Morceau | Ce qu’il fait |
|---|---|
| `watch -n 15 "…"` | Relance la commande entre guillemets toutes les 15 secondes et affiche le résultat en plein écran. `Ctrl+C` pour sortir |
| `juju status -m openstack` | L’état des applications du modèle `openstack` |
| `keystone-idp-saml2-keycloak keystone horizon` | Seulement ces trois applications, pour ne pas noyer l’écran avec les 25 |

✅ **Attendu** (18 octobre, environ 10 minutes), dans l’ordre : `waiting … installing agent`, `waiting … Waiting for keystone to set SP URLs`, puis :

```text
horizon/0*                      active    idle   10.1.0.208
keystone-idp-saml2-keycloak/0*  active    idle   10.1.0.194         Provider is ready
keystone/0*                     active    idle   10.1.0.79
```

**Comment lire ces états.**

| Message | Ce qui se passe |
|---|---|
| `installing agent` | Kubernetes crée le pod du nouveau charm |
| `Waiting for keystone to set SP URLs` | Le charm attend que Keystone lui dise à quelles adresses il expose la fédération (les adresses qui contiennent `keycloak`) |
| `Provider is ready` | Le charm a téléchargé les métadonnées de Keycloak avec la CA, Keystone a reconfiguré Apache, et **Keystone publie maintenant sa propre carte d’identité** (ses métadonnées de *Service Provider*) |

C’est ce document que l’étape 5 va lire : **ne pas continuer avant `Provider is ready`**. Si l’état reste sur `Failed to get IDP metadata`, revenir à l’étape 0b (DNS du pod) ou 0d (CA).

**Ce qu’on a maintenant :** la douane reconnaît l’État. Mais l’État ne connaît pas la douane : si `alice` se présentait, Keycloak refuserait la demande de Keystone, signée par une clé inconnue.

## Étape 5 · Keycloak apprend à reconnaître Keystone (second sens)

**Pourquoi maintenant.** La confiance doit être **réciproque**. Keycloak ne délivre un passeport qu’à un demandeur qu’il connaît, et ne le renvoie qu’à une adresse qu’il connaît. Il faut donc lui donner la carte d’identité de Keystone, que Keystone vient de publier (étape 4) : son nom, l’adresse de retour, et le certificat de signature créé à l’étape 2.

### 5a · Lire la carte d’identité de Keystone (Lab-Sunbeam)

```bash
source ~/admin-openrc
curl -s --cacert "$OS_CACERT" -w "code HTTP : %{http_code}\n" \
  'https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/metadata' \
  -o ~/keystone-sp.xml
python3 ~/extract-sp.py ~/keystone-sp.xml
```

**Ligne 1 : charger les variables de l’administrateur.** `source` exécute le fichier dans la session courante : les lignes `export OS_…=` de `~/admin-openrc` deviennent des variables disponibles. On en veut une en particulier ici : `OS_CACERT`, le chemin de la CA de **Sunbeam**, écrit par `sunbeam openrc` à l’étape 0a.

**Lignes 2 à 4 : télécharger.** Même `curl` qu’aux étapes 0d et 3, mais cette fois on interroge le **cloud**, pas Keycloak :

| Morceau | Ce qu’il fait |
|---|---|
| `--cacert "$OS_CACERT"` | Vérifier le certificat du cloud avec la CA de **Sunbeam** : c’est elle qui a signé `cloud.lab.test`, pas la CA du lab. Les guillemets protègent le chemin s’il contient des espaces |
| `-w "code HTTP : %{http_code}\n"` | Afficher le code de réponse HTTP à la fin (`-w`, *write out*). On le met **exprès** : un `curl -s` muet qui échoue ne crée pas le fichier, et c’est le script suivant qui se plaint (`No such file or directory`), loin de la cause |
| `https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/metadata` | L’adresse où Keystone publie ses métadonnées SAML **pour le fournisseur `keycloak`** (le `name` de l’étape 4). `OS-FEDERATION` est la partie de l’API Keystone consacrée à la fédération ; `mellon` est le module Apache qui gère SAML. Entre guillemets simples à cause des caractères spéciaux |
| `-o ~/keystone-sp.xml` | Garder le fichier. `sp` pour *Service Provider* |

| Code affiché | Ce que ça veut dire | Que faire |
|---|---|---|
| `200` | Le fichier est créé : continuer | |
| `000` | Aucune connexion HTTPS possible : le cloud est en HTTP, ou `OS_CACERT` est vide | Étape 0a, puis `source ~/admin-openrc` |
| `404` | Keystone ne connaît pas de fournisseur `keycloak` | Le charm de l’étape 4 n’est pas à `Provider is ready`, ou son option `name` n’est pas `keycloak` |

**Ligne 5 : en extraire ce qu’on va recopier dans Keycloak.** Le XML est illisible tel quel ; le petit script `extract-sp.py` du dépôt en sort les quatre informations utiles.

✅ **Attendu** (18 octobre) :

```text
Client ID / Entity ID: urn:saml2:keycloak
ACS urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/postResponse
SLO urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/logout
SP X509 certificate (base64): MIIEGTCC…
```

| Ligne | Ce que c’est | Ce que Keycloak en fera |
|---|---|---|
| `Entity ID` | Le nom officiel de Keystone : `urn:saml2:` suivi du nom du fournisseur | Reconnaître de qui vient une demande |
| `ACS` (*Assertion Consumer Service*) | L’adresse où Keystone attend les passeports (flèche 5 du schéma) ; `HTTP-POST` : ils y arrivent par un formulaire posté | N’envoyer l’assertion **qu’à** cette adresse |
| `SLO` (*Single Logout*) | L’adresse de déconnexion | Prévenir Keystone quand `alice` se déconnecte de Keycloak |
| `SP X509 certificate` | Le certificat `~/saml/sp.crt` de l’étape 2, en base64 | Vérifier la signature des demandes de Keystone (flèche 2) |

### 5b · Importer cette carte d’identité dans Keycloak (Windows, puis navigateur)

Récupérer le fichier sur Windows (PowerShell, dans le dossier du dépôt) :

```powershell
scp vagrant@192.168.56.10:~/keystone-sp.xml .
```

Le même `scp` qu’à l’étape 0c, dans l’autre sens : la source est sur Lab-Sunbeam (`machine:chemin`), la destination est `.`, le dossier courant sur Windows. On en a besoin parce que l’import dans Keycloak se fait depuis le navigateur, donc depuis un fichier du PC.

Dans Keycloak, un service qui lui demande des authentifications s’appelle un **client**. Realm **lab** : **Clients → Import client → Browse**, choisir `keystone-sp.xml` → **Save**. L’import lit le fichier et remplit presque tout, **mais pas tout** (constaté le 20 octobre : *Sign assertions* Off, *Name ID format* `username`, *Encrypt assertions* On). On **contrôle** donc chaque réglage, dans deux onglets, parce que chaque réglage ferme une porte.

**Onglet *Settings*** (Keycloak 26 ; les sections sont dans cet ordre sur la page) :

| Section | Réglage | Valeur | La porte qu’il ferme |
|---|---|---|---|
| *General settings* | *Client ID* | `urn:saml2:keycloak` (l’`Entity ID` de 5a) | Keycloak ne traite que les demandes qui se présentent sous ce nom |
| *Access settings* | *Valid redirect URIs* | L’adresse **ACS** exacte de 5a, en `https://`, sans joker | Un pirate ne peut pas faire renvoyer le passeport d’`alice` vers son propre site |
| *Access settings* | *Master SAML Processing URL* | La même adresse ACS | Adresse par défaut des réponses |
| *SAML capabilities* | *Name ID format* | `persistent` (l’import met `username`) | `alice` est identifiée par un code stable, pas par son nom : si elle se marie ou change d’adresse mail, ses droits ne bougent pas (étape 7d) |
| *SAML capabilities* | *Force name ID format* | **On** | Keycloak impose ce format, même si la demande en propose un autre |
| *SAML capabilities* | *Force POST binding* | On | L’assertion est postée par le navigateur, pas mise dans une URL (où elle finirait dans les journaux) |
| *Signature and Encryption* | *Sign documents* | On | Keystone peut vérifier que la réponse vient bien de Keycloak |
| *Signature and Encryption* | *Sign assertions* | **On** (l’import le laisse Off) | Keystone vérifie aussi la signature du passeport lui-même, pas seulement de l’enveloppe |
| *Signature and Encryption* | *Signature algorithm* | `RSA_SHA256` | Algorithme de signature actuel |
| *Signature and Encryption* | *SAML signature key name* | `KEY_ID` (l’import met `NONE`) | Keycloak indique quelle clé a signé ; `mod_auth_mellon` s’en sert pour la retrouver |

Puis **Save**, en bas de page.

**Onglet *Keys*** (dans la barre d’onglets en haut du client) :

| Réglage | Valeur | La porte qu’il ferme |
|---|---|---|
| *Client signature required* | **On**, et le certificat affiché doit être `CN=Keystone SAML Lab` (importé avec le fichier) | Keycloak refuse toute demande qui n’est pas signée par la clé de Keystone (étape 2) |
| *Encrypt assertions* (section *Encryption keys config*) | **Off** (l’import l’active) | Le lab ne chiffre pas les assertions ; le transport est déjà en HTTPS. Activé, Keystone devrait avoir une clé de déchiffrement qu’on ne lui a pas donnée, et répondrait `400` à chaque passeport (constaté le 20 octobre) |

✅ **Attendu :** le client `urn:saml2:keycloak` apparaît dans **Clients** ; dans *Settings*, *Sign assertions* On et *Name ID format* `persistent` ; dans *Keys*, *Encrypt assertions* Off et un certificat `CN=Keystone SAML Lab` : celui de l’étape 2, arrivé jusqu’ici par les métadonnées.

**Ce qu’on a maintenant :** la confiance est réciproque. Keycloak accepterait une demande de Keystone et lui renverrait un passeport pour `alice`. Mais Keystone, en le recevant, ne saurait **quoi en faire** : aucune règle ne dit où ranger `alice` ni ce qu’elle a le droit de faire.

## Étape 6 · La règle de la douane : qui entre, et où

**Pourquoi maintenant.** C’est ici que l’on retrouve ce que les TP identité ont appris : un droit, c’est un **groupe**, un **rôle**, une **cible**. La fédération n’y change rien ; elle ajoute seulement une règle qui dit **dans quel groupe** entre une personne qui se présente avec un passeport. On construit d’abord la cible (où mène la porte), puis la règle (qui passe la porte).

### 6a · La cible : un domaine, un groupe, un projet

```bash
source ~/admin-openrc
openstack domain create keycloak --description "Comptes federes depuis Keycloak"
openstack group create --domain keycloak lab_members
openstack project create --domain keycloak formation
openstack role add --group lab_members --group-domain keycloak --project formation --project-domain keycloak member
openstack role assignment list --group lab_members --group-domain keycloak --names
```

| Ligne | Ce qu’elle fait | Pourquoi |
|---|---|---|
| `source ~/admin-openrc` | Charge les identifiants de l’administrateur (si ce n’est pas déjà fait dans cette session) | Créer des domaines et des projets exige le rôle `admin` (TP 1, § 1.6.2) |
| `openstack domain create keycloak --description "…"` | Crée le domaine `keycloak` | **Un domaine par source d’identité** : tous les comptes qui viendront de ce Keycloak y seront rangés, séparés des comptes locaux. C’est le découpage standard : un domaine = une organisation, une source (TP 2) |
| `openstack group create --domain keycloak lab_members` | Crée le groupe `lab_members` **dans** ce domaine | Les droits vont à un groupe, jamais à une personne : quand d’autres salariés arriveront, ils entreront dans le même groupe sans qu’on touche aux affectations (TP 4) |
| `openstack project create --domain keycloak formation` | Crée le projet `formation` dans ce domaine | La zone où mène la porte : c’est là qu’`alice` pourra créer des VM |
| `openstack role add --group lab_members --group-domain keycloak --project formation --project-domain keycloak member` | Donne le rôle `member` au groupe, sur le projet | Le moindre privilège : exploiter ce projet, rien d’autre. Jamais `admin`. Les `--group-domain` et `--project-domain` sont obligatoires : un nom n’est unique que dans son domaine (TP 2) |
| `openstack role assignment list --group lab_members --group-domain keycloak --names` | Affiche les affectations du groupe, avec les noms (`--names`) plutôt que les identifiants | Vérifier avant de continuer |

✅ **Attendu :**

```text
+--------+------+----------------------+--------------------+--------+--------+-----------+
| Role   | User | Group                | Project            | Domain | System | Inherited |
+--------+------+----------------------+--------------------+--------+--------+-----------+
| member |      | lab_members@keycloak | formation@keycloak |        |        | False     |
+--------+------+----------------------+--------------------+--------+--------+-----------+
```

Le groupe est vide : personne n’y est encore. C’est la règle de 6b qui y fera entrer les gens, à chaque connexion.

### 6b · La règle : fournisseur, mapping, protocole

Trois objets Keystone, qui s’emboîtent :

- le **fournisseur d’identité** : « j’accepte les passeports de cet État, et je range leurs porteurs dans le domaine `keycloak` » ;
- le **mapping** : « voici comment lire un passeport, et dans quel groupe mettre son porteur » ;
- le **protocole** : « pour ce fournisseur, en SAML 2, applique ce mapping ».

Le mapping est dans `~/mapping.json` (copié à l’étape 0c) :

```json
[
  {
    "local": [
      { "user":  { "name": "{0}" },
        "group": { "domain": { "name": "keycloak" }, "name": "lab_members" } }
    ],
    "remote": [ { "type": "REMOTE_USER" } ]
  }
]
```

**Comment le lire.** Un mapping est une liste de règles ; ici une seule. Chaque règle a deux parties :

| Partie | Ce qu’elle dit |
|---|---|
| `remote` | **Quoi regarder dans le passeport.** `REMOTE_USER` est le nom sous lequel le module SAML transmet l’identifiant de la personne à Keystone. Donc : « il faut qu’il y ait un identifiant » |
| `local` | **Quoi en faire.** `"user": {"name": "{0}"}` : créer un utilisateur Keystone nommé comme la première valeur trouvée dans `remote` (`{0}` = le premier élément, ici l’identifiant). `"group": …` : le mettre dans le groupe `lab_members` du domaine `keycloak` |

Puisque le groupe a `member` sur `formation` (6a), la personne a ce droit. **Toute** personne authentifiée par ce Keycloak entre donc dans ce groupe : simple pour un lab, trop large en entreprise ; l’étape 9 corrige cela.

```bash
REMOTE_ID=$(python3 -c 'import xml.etree.ElementTree as E; print(E.parse("/home/vagrant/keycloak-idp.xml").getroot().attrib["entityID"])')
echo "$REMOTE_ID"
openstack identity provider create --remote-id "$REMOTE_ID" --domain keycloak keycloak
openstack mapping create --rules ~/mapping.json keycloak_saml
openstack federation protocol create --identity-provider keycloak --mapping keycloak_saml saml2
openstack federation protocol list --identity-provider keycloak
```

**Ligne 1 : relire l’`entityID` de Keycloak dans sa carte d’identité (étape 3), sans le retaper.**

| Morceau | Ce qu’il fait |
|---|---|
| `REMOTE_ID=$(…)` | Met le résultat de la commande dans la variable `REMOTE_ID` |
| `python3 -c '…'` | Exécute le petit programme Python entre guillemets |
| `import xml.etree.ElementTree as E` | Charge le lecteur XML de Python |
| `E.parse("/home/vagrant/keycloak-idp.xml").getroot()` | Lit le fichier et prend son élément racine |
| `.attrib["entityID"]` | Lit l’attribut `entityID` de cet élément ; `print` l’affiche |

On aurait pu copier-coller la valeur vue à l’étape 3. On la relit par programme parce qu’une faute de frappe dans cet identifiant est invisible et fait tout échouer : Keystone refuserait silencieusement les assertions.

**Ligne 2 : l’afficher**, pour vérifier.

**Ligne 3 : le fournisseur d’identité.**

| Morceau | Ce qu’il fait |
|---|---|
| `openstack identity provider create` | Crée un fournisseur d’identité dans Keystone |
| `--remote-id "$REMOTE_ID"` | Les assertions dont l’émetteur est **exactement** cette valeur sont acceptées ; toutes les autres sont refusées |
| `--domain keycloak` | Les utilisateurs venus de ce fournisseur sont rangés dans le domaine `keycloak` (6a) |
| `keycloak` (dernier mot) | Le nom du fournisseur. Il **doit** être celui de l’option `name` du charm (étape 4) : c’est par ce nom que Keystone relie l’objet au module Apache déjà configuré et aux adresses `…/identity_providers/keycloak/…` |

**Ligne 4 : le mapping.**

| Morceau | Ce qu’il fait |
|---|---|
| `openstack mapping create` | Enregistre une règle de traduction |
| `--rules ~/mapping.json` | Le fichier des règles, lu ci-dessus |
| `keycloak_saml` | Le nom qu’on lui donne |

**Ligne 5 : le protocole, qui branche le tout.**

| Morceau | Ce qu’il fait |
|---|---|
| `openstack federation protocol create` | Déclare un protocole pour un fournisseur |
| `--identity-provider keycloak` | Pour ce fournisseur |
| `--mapping keycloak_saml` | Appliquer ce mapping |
| `saml2` | Le protocole : SAML 2. Ce nom apparaît aussi dans les adresses (`…/protocols/saml2/…`) ; il doit être exactement `saml2` |

**Ligne 6 : vérifier** que le protocole existe et pointe sur le bon mapping.

✅ **Attendu** (18 octobre) : `https://sso.lab.test:8443/realms/lab` (ligne 2), puis :

```text
+-------+---------------+
| id    | mapping       |
+-------+---------------+
| saml2 | keycloak_saml |
+-------+---------------+
```

**Ce qu’on a maintenant :** la chaîne est complète. Keycloak connaît Keystone (5), Keystone connaît Keycloak (4 et 6b) et sait quoi faire d’un passeport (6b), et la porte mène quelque part (6a). Il ne reste qu’à essayer.

## Étape 7 · `alice` entre, avec les droits prévus et pas plus

### Pourquoi on ne passe pas par Horizon

Horizon propose bien le choix « Keycloak - Lab » dans sa page de connexion, mais sur ce lab la connexion par Horizon n’aboutit pas : le charm Keystone (rév. 440) n’inscrit pas l’adresse de Horizon dans sa liste des tableaux de bord de confiance quand le fournisseur est SAML (il ne le fait que pour OpenID Connect). On teste donc la fédération **directement sur Keystone**, ce qui prouve toute la chaîne, et c’est de toute façon ce qu’un outil en ligne de commande ferait.

### 7a · Dans le navigateur : voir le trajet

**Prérequis : le navigateur doit faire confiance à la CA de Sunbeam.** Depuis l’étape 0a, `cloud.lab.test` est signé par `internal-ca`, une autorité que Windows ne connaît pas : sans cela, le navigateur affiche « Votre connexion n’est pas privée » et refuse d’aller plus loin. (Si la démo 1 a été jouée, c’est déjà fait : passer au point 1.)

Sur Lab-Sunbeam, afficher le certificat public de cette CA :

```bash
openssl x509 -in "$OS_CACERT" -noout -subject -enddate
cat "$OS_CACERT"
```

| Ligne | Ce qu’elle fait |
|---|---|
| `openssl x509 -in "$OS_CACERT" -noout -subject -enddate` | Lit le certificat de la CA de Sunbeam (même commande qu’à l’étape 0d) ; `-enddate` affiche en plus sa date de fin de validité |
| `cat "$OS_CACERT"` | Affiche le certificat entier, un bloc `-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----`. C’est la partie **publique** : la copier n’expose rien |

✅ **Attendu** (18 octobre) : `subject=CN = internal-ca, …` et `notAfter=Oct  9 10:32:22 2027 GMT` : la CA a été créée à l’installation du cloud, valable un an.

Puis, sur Windows :

1. Copier le bloc `-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----` dans un fichier `sunbeam-ca.crt` (Bloc-notes, enregistrer avec l’extension `.crt`).
2. Double-cliquer sur `sunbeam-ca.crt` → **Installer le certificat** → **Ordinateur local** → **Placer tous les certificats dans le magasin suivant** → **Autorités de certification racines de confiance** → **Terminer**.
3. Vérifier : ouvrir `https://cloud.lab.test/openstack-horizon` ; le cadenas doit être fermé, sans avertissement.

Windows connaît maintenant **deux** CA du lab : celle de Keycloak (`ca.crt`, installée par `Configurer-Lab-Sunbeam.ps1`) et celle de Sunbeam (`sunbeam-ca.crt`). Le trajet de 7a passe par les deux sites, il faut les deux.

1. Ouvrir une **fenêtre de navigation privée** (pour partir sans aucune session Keycloak déjà ouverte), à l’adresse :
   `https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth`
   C’est la flèche 1 : on demande à Keystone d’entrer par le fournisseur `keycloak`, protocole `saml2`. Comparer avec l’adresse de l’étape 5a : même base, `auth` au lieu de `auth/mellon/metadata`.
2. La page de Keycloak s’affiche (flèches 2 et 3) : saisir `alice` et son mot de passe. **Ce mot de passe est vérifié par Keycloak** ; Keystone ne le verra pas.
3. Retour sur Keystone (flèches 4 à 7) : la page affiche le **jeton** au format JSON.

✅ **Attendu :** dans le JSON, `"methods": ["saml2"]`, le domaine `keycloak`, et `"OS-FEDERATION"` avec le fournisseur `keycloak` et le protocole `saml2`.

**Comment le lire.** `methods: ["saml2"]` est la trace, dans le jeton, que l’identité a été prouvée par un passeport et non par un mot de passe Keystone (TP 1, § 1.4.2 : un compte local aurait `["password"]`). Un auditeur distingue ainsi les deux modes de connexion.

### 7b · En ligne de commande : le même trajet, flèche par flèche

Le script `~/test-sso-saml.py` (étape 0c) fait ce que le navigateur vient de faire, mais en affichant chaque échange. Il a besoin de `OS_CACERT` (pour parler au cloud) et de `~/ca.crt` (pour parler à Keycloak) : d’où le `source`.

```bash
source ~/admin-openrc
python3 ~/test-sso-saml.py alice
```

| Morceau | Ce qu’il fait |
|---|---|
| `python3 ~/test-sso-saml.py` | Lance le script avec Python 3 |
| `alice` | L’utilisateur Keycloak à connecter. Le script demandera son mot de passe sans l’afficher |

✅ **Attendu** (18 octobre) :

```text
Mot de passe Keycloak de alice :
1. Redirigé vers : https://sso.lab.test:8443/realms/lab/protocol/saml
2. Assertion SAML reçue de Keycloak, postée vers : OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/postResponse
3. Réponse de Keystone : 201
4. Jeton non limité à un projet : gAAAAABq…, expire 2026-10-18T11:03:41.000000Z
   Utilisateur : G-50829266-f3a1-4e25-95ec-a0a551b573c0 | domaine : keycloak
   Méthode : ['saml2'] | fournisseur : keycloak | groupes (id) : ['2e13f063…']
```

**Comment le lire, ligne par ligne.**

| Ligne | Ce qui s’est passé | Flèche du schéma |
|---|---|---|
| 1 | Keystone a renvoyé le script vers Keycloak, avec sa demande signée (étape 2) | 2 |
| 2 | Le script a donné le mot de passe à Keycloak, qui a rendu le passeport ; le script l’a posté à l’adresse ACS déclarée à l’étape 5 | 3, 4, 5 |
| 3 | `201` (*Created*) : Keystone a reconnu la signature de Keycloak (étape 4), appliqué le mapping (étape 6) et **créé** un jeton | 6, 7 |
| 4 | Le jeton est **sans portée** (TP 1, § 1.4.3) : il prouve qui est `alice`, pas encore sur quel projet elle agit. Le domaine est `keycloak`, le groupe est `lab_members` : exactement ce que le mapping a dit | — |

Le jeton est rangé dans `~/lab-sec-fed-token`, avec les droits `600` (lisible par toi seul : un jeton vaut un mot de passe pendant une heure, TP 1, § 1.4.5).

**Si le script s’arrête avant la ligne 3.** Chaque ligne manquante désigne l’étape en cause. Le message le plus précis est dans le **journal de Keycloak**, sur **Lab-Services** :

```bash
cd ~/lab/keycloak && docker compose logs --tail=30 keycloak | grep -iE "error|warn" | tail -5
```

| Morceau | Ce qu’il fait |
|---|---|
| `docker compose logs --tail=30 keycloak` | Les 30 dernières lignes du journal du conteneur `keycloak` |
| `grep -iE "error\|warn"` | Ne garder que les erreurs et avertissements (`-i` : sans tenir compte de la casse) |
| `tail -5` | Les 5 dernières |

| Ce que montre le script | Ce que dit le journal Keycloak | Cause | Que faire |
|---|---|---|---|
| `Pas de formulaire de connexion Keycloak.` après la ligne 1 | `LOGIN_ERROR … error="client_not_found", reason="Cannot_match_source_hash"` (constaté le 20 octobre) | Keystone a bien redirigé (étape 4 correcte), mais Keycloak ne trouve pas de client dont la clé corresponde à la signature de la demande : **l’étape 5b n’a pas été faite**, ou le client importé n’a pas le certificat `CN=Keystone SAML Lab` dans son onglet *Keys* | Dans Keycloak, **Clients** : si `urn:saml2:keycloak` est absent, faire 5b ; s’il existe, le supprimer et réimporter le `keystone-sp.xml` **actuel** |
| Idem | `error="invalid_redirect_uri"` | Le client a été importé **avant** le TLS : ses adresses ACS sont en `http://`, Keystone envoie maintenant `https://` | Supprimer le client, refaire 5a puis 5b |
| Idem | `error="invalid_signature"` | Le certificat dans *Keys* n’est pas celui de l’étape 2 (par exemple, `set-saml-x509` relancé après l’import) | Supprimer le client, refaire 5a puis 5b |
| Ligne 1 affiche `http://cloud.lab.test…` ou une erreur de certificat | — | Le cloud n’est pas en HTTPS, ou `OS_CACERT` n’est pas chargé | Étape 0a, puis `source ~/admin-openrc` |
| Ligne 2 puis `Réponse de Keystone : 400` | rien (Keycloak a accepté et envoyé le passeport) | Le module SAML de Keystone (`mod_auth_mellon`) **n’arrive pas à lire** l’assertion. Cause presque toujours : *Encrypt assertions* resté **On** dans le client Keycloak (l’import l’active), alors que Keystone n’a pas de clé de déchiffrement. Autres causes : *Sign assertions* Off, algorithme autre que `RSA_SHA256`, *Client ID* différent de `urn:saml2:keycloak` | Dans Keycloak, **Clients → urn:saml2:keycloak → Settings** : *Encrypt assertions* **Off**, **Save**, relancer. Sinon, lire le reproche de `mellon` : `sudo k8s kubectl -n openstack logs keystone-0 -c keystone --since=5m \| grep -iE "mellon\|saml" \| tail -5` (`decrypt` → chiffrement ; `signature` → signature ; `audience` → *Client ID*) |
| Ligne 2 puis `Réponse de Keystone : 401` | rien (Keycloak a accepté) | Keystone a reçu le passeport mais le mapping ne s’applique pas : fournisseur absent, `remote-id` faux, ou condition de groupe non remplie (étape 9) | `openstack identity provider show keycloak` (le `remote_ids` doit être l’`entityID` de l’étape 3) ; journal Keystone : `sudo k8s kubectl -n openstack logs keystone-0 -c keystone --since=5m \| grep -iE "federation\|map"` |
| `Account is disabled` | `error="user_disabled"` | `alice` est désactivée dans Keycloak (étape 8) | **Users → alice → Enabled : On** |
| Page *Update Account Information* au lieu de la ligne 2 | — | Profil incomplet (*Last name*) ou une *Required user action* sur `alice` | Étape 1 : compléter le profil, vider *Required user actions* |

### 7c · Ce que ce jeton permet : les droits d’un `member`, rien de plus

Comme n’importe quel jeton sans portée, on l’échange contre un jeton sur un projet, puis on agit avec. Pour ne pas retaper six options à chaque commande, on définit une petite fonction `F`.

```bash
T=$(cat ~/lab-sec-fed-token)
F() { env -u OS_USERNAME -u OS_PASSWORD -u OS_USER_DOMAIN_NAME -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME \
      openstack --os-auth-type token --os-token "$T" --os-project-name formation --os-project-domain-name keycloak "$@"; }
F token issue -c project_id -c expires
F network list -c Name
F user list
```

**Ligne 1 :** met le jeton dans la variable `T`.

**Lignes 2 et 3 : la fonction `F`.** `F() { …; }` définit une commande `F` qui exécute ce qui est entre accolades ; `"$@"` y est remplacé par les arguments qu’on donne à `F`.

| Morceau | Ce qu’il fait | Pourquoi |
|---|---|---|
| `env -u OS_USERNAME -u OS_PASSWORD -u OS_USER_DOMAIN_NAME -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME` | Lance la commande qui suit **sans** ces cinq variables (`-u`, *unset*) | `admin-openrc` les a définies ; si on les laissait, le client mélangerait le mot de passe de l’admin avec le jeton d’`alice` et refuserait (`Authentication plugin requires…`) |
| `openstack` | Le client OpenStack | |
| `--os-auth-type token` | S’authentifier avec un **jeton** et non un mot de passe | `alice` n’a pas de mot de passe dans Keystone |
| `--os-token "$T"` | Le jeton fédéré de 7b | |
| `--os-project-name formation --os-project-domain-name keycloak` | Demander un jeton **sur ce projet** | C’est l’échange « jeton sans portée → jeton de projet » (TP 1, § 1.4.3) ; sans projet, aucune commande Nova ou Neutron ne marche |
| `"$@"` | La commande voulue (`token issue`, `network list`…) | |

**Lignes 4 à 6 : trois essais.**

| Commande | Ce qu’elle demande | Avec quel droit |
|---|---|---|
| `F token issue -c project_id -c expires` | Un jeton sur `formation` ; n’afficher que les colonnes `project_id` et `expires` (`-c`) | Avoir un rôle sur le projet |
| `F network list -c Name` | La liste des réseaux visibles depuis `formation` ; colonne `Name` seulement | `reader`, impliqué par `member` (TP 1, § 1.2) |
| `F user list` | La liste des utilisateurs de Keystone | `admin` seulement (TP 1, § 1.6.2) |

✅ **Attendu** (18 octobre) : un jeton sur le projet `formation` ; la liste des réseaux (`external-network`) ; puis ⛔ `ForbiddenException: 403 … identity:list_users`.

**Comment le lire.** `alice` peut lire les réseaux de `formation` (droit d’un `member`) et **ne peut pas** lister les utilisateurs (droit d’un `admin`). C’est la preuve que la fédération n’a donné **que** ce que 6a a décidé. Le `403` est attendu : c’est la démonstration du moindre privilège, pas une erreur.

### 7d · Ce que Keystone a créé : l’utilisateur fantôme

```bash
openstack user list --domain keycloak
```

Liste les utilisateurs du domaine `keycloak` (toujours `--domain` : sans lui, on ne verrait que le domaine du jeton, TP 1, § 1.2). On est de nouveau administrateur ici : pas de `F`.

✅ **Attendu** (18 octobre) : un utilisateur `G-50829266-f3a1-4e25-95ec-a0a551b573c0`.

**Comment le lire.** Ce n’est pas `alice` : c’est l’identifiant **persistant** choisi à l’étape 5 (*Name ID format* = `persistent`), un code stable et sans rapport visible avec la personne. Keystone a créé cet utilisateur **à la première connexion**, parce que le mapping l’a demandé (`"user": {"name": "{0}"}`). On l’appelle un **utilisateur fantôme** (*shadow user*) : Keystone garde sa trace pour les affectations et l’audit, mais il n’a **aucun mot de passe** ; on ne peut pas se connecter avec. Son appartenance au groupe `lab_members` n’est pas enregistrée non plus : elle est recalculée par le mapping **à chaque connexion**. C’est important pour les étapes 8 et 10.

## Étape 8 · Le gain : un seul interrupteur

**Pourquoi cette étape.** Jusqu’ici, on a montré que ça marche. On montre maintenant **pourquoi c’est mieux** : la sécurité du compte se gère à un seul endroit.

### 8a · Désactiver `alice` dans Keycloak

**Dans Keycloak :** **Users → alice → Enabled : Off → Save**. Puis, sur Lab-Sunbeam, retenter la connexion :

```bash
python3 ~/test-sso-saml.py alice
```

✅ **Attendu** (18 octobre) : Keycloak refuse : `Account is disabled, contact your administrator.` Keystone n’est jamais atteint (le script s’arrête à la ligne 2 : pas d’assertion).

**Comment le lire.** Un seul clic dans l’annuaire de l’entreprise, et `alice` ne peut plus entrer dans le cloud, ni dans aucune autre application fédérée sur ce Keycloak. Sans fédération, il aurait fallu désactiver son compte dans chaque application, en espérant n’en oublier aucune.

### 8b · Et les jetons déjà délivrés ?

Ils restent valables jusqu’à leur expiration (une heure, TP 1, § 1.4.7) : le jeton obtenu à l’étape 7 fonctionne encore, parce que Keystone ne redemande pas de passeport à chaque appel. Pour un départ urgent, on le révoque côté Keystone :

```bash
openstack token revoke "$(cat ~/lab-sec-fed-token)"
F token issue
```

| Ligne | Ce qu’elle fait |
|---|---|
| `openstack token revoke "$(cat …)"` | Révoque le jeton dont la valeur est lue dans le fichier (`$(cat …)` est remplacé par le contenu du fichier). Commande d’administrateur : on révoque le jeton de quelqu’un d’autre |
| `F token issue` | Essaie d’utiliser ce jeton (c’est `F` qui le porte, via `$T`) |

✅ **Attendu :** `Failed to validate token (HTTP 404)` : Keystone ne reconnaît plus le jeton.

**Procédure de départ d’un salarié, en deux temps :** désactiver dans Keycloak (plus de nouveau passeport), **puis** révoquer ses jetons en cours (plus d’accès avec l’ancien). Désactiver seulement l’utilisateur fantôme dans Keystone ne suffirait pas : pour un compte fédéré, Keystone ne consulte pas l’état du fantôme à la connexion ; seul l’État qui délivre les passeports peut bloquer la personne.

**Réactiver `alice`** pour la suite : dans Keycloak, **Users → alice → Enabled : On → Save**.

| Sans fédération | Avec fédération |
|---|---|
| Un mot de passe de plus par personne, stocké dans Keystone | Aucun mot de passe dans OpenStack |
| Politique de mots de passe : options de Keystone, **non exposées par Sunbeam** (démo 3) | Politique de Keycloak : longueur, historique, verrouillage, second facteur (démo 3) |
| Départ d’un salarié : penser à chaque application | Un seul compte à désactiver, puis les jetons en cours à couper |
| Second facteur : à construire dans Keystone | Natif dans Keycloak (TOTP, WebAuthn) |

## Étape 9 · En entreprise : seule l’équipe entre, pas toute l’entreprise

**Pourquoi cette étape.** La règle de l’étape 6 fait entrer **toute** personne connue de Keycloak. En entreprise, Keycloak connaît tous les salariés, dont la comptabilité et le service juridique, qui n’ont rien à faire dans le cloud. On veut n’admettre que l’équipe `openstack-formation`, créée à l’étape 1. Pour cela, deux choses : que Keycloak **écrive l’équipe dans le passeport**, et que Keystone **la lise**.

### 9a · Keycloak transmet les groupes dans l’assertion

Par défaut, le passeport ne contient que l’identifiant. On ajoute au client un *mapper* (côté Keycloak, c’est le nom d’une règle qui ajoute une information dans l’assertion) qui y inscrit les groupes de la personne.

Realm **lab** : **Clients → urn:saml2:keycloak → Client scopes → urn:saml2:keycloak-dedicated → Configure a new mapper → Group list** :

| Champ | Valeur | Pourquoi |
|---|---|---|
| *Name* | `groups` | Le nom de la règle, libre |
| *Group attribute name* | `groups` | Le nom de l’**attribut** dans l’assertion. C’est lui que Keystone verra, sous le nom `MELLON_groups` (9b) |
| *SAML Attribute NameFormat* | `Basic` | Le format le plus simple ; `mod_auth_mellon` le lit sans réglage |
| *Single Group Attribute* | désactivé | Un attribut par groupe, pas une liste concaténée |
| *Full group path* | **désactivé** | L’assertion contient `openstack-formation`, et non `/openstack-formation` : c’est la forme qu’on comparera en 9b |

→ **Save**.

### 9b · Keystone n’accepte que si le passeport mentionne l’équipe

Le module SAML d’Apache (`mod_auth_mellon`) transmet chaque attribut de l’assertion à Keystone sous le nom `MELLON_<attribut>` : l’attribut `groups` devient `MELLON_groups`. On écrit un second mapping, avec une condition de plus, et on remplace l’ancien.

```bash
cat > ~/lab-sec-mapping-groupe.json <<'JSON'
[
  {
    "local": [
      { "user":  { "name": "{0}" },
        "group": { "domain": { "name": "keycloak" }, "name": "lab_members" } }
    ],
    "remote": [
      { "type": "REMOTE_USER" },
      { "type": "MELLON_groups", "any_one_of": ["openstack-formation"] }
    ]
  }
]
JSON
openstack mapping set --rules ~/lab-sec-mapping-groupe.json keycloak_saml
python3 ~/test-sso-saml.py alice
```

**Lignes 1 à 14 : écrire le fichier.** `cat > fichier <<'JSON'` … `JSON` écrit tout ce qui est entre les deux `JSON` dans le fichier (c’est un *heredoc* ; les guillemets autour du premier `JSON` empêchent le shell d’interpréter les `{}` et les `$`).

**La règle, par rapport à celle de l’étape 6 :** `local` est identique (même utilisateur, même groupe). `remote` a maintenant **deux** conditions, toutes deux obligatoires :

| Condition | Ce qu’elle exige |
|---|---|
| `{"type": "REMOTE_USER"}` | Un identifiant (comme avant) |
| `{"type": "MELLON_groups", "any_one_of": ["openstack-formation"]}` | Un attribut `groups` dont **au moins une** valeur (`any_one_of`) est `openstack-formation` |

Si la seconde manque, la règle ne s’applique pas, et comme il n’y a pas d’autre règle, Keystone ne sait pas quoi faire de la personne et la refuse.

**Ligne 15 : remplacer le mapping.** `openstack mapping set --rules … keycloak_saml` : même commande qu’à l’étape 6, mais `set` au lieu de `create` : on modifie le mapping existant, sans toucher au fournisseur ni au protocole, qui pointent toujours sur `keycloak_saml`.

**Ligne 16 : réessayer** la connexion d’`alice`.

✅ **Attendu** (18 octobre) : `3. Réponse de Keystone : 201`. `alice` passe parce qu’elle est dans l’équipe (étape 1) et que l’assertion le dit (9a).

**Pour le montrer aux apprenants, si le temps le permet :** retirer `alice` du groupe dans Keycloak (**Users → alice → Groups → Leave**), relancer le script : Keystone répond `401`, et son journal indique pourquoi :

```bash
sudo k8s kubectl -n openstack logs keystone-0 -c keystone --since=5m | grep "Could not map"
```

(`logs` au lieu de `exec` : lire le journal du conteneur ; `--since=5m` : les cinq dernières minutes ; `grep` : la ligne qui nous intéresse.) Attendu : `Could not map any federated user properties to identity values` : **authentifiée par Keycloak, mais sans aucun droit dans OpenStack**. C’est la séparation des deux métiers, vue en 2.1, en une ligne de journal. Remettre `alice` dans le groupe ensuite.

Remettre le mapping du lab pour la suite :

```bash
openstack mapping set --rules ~/mapping.json keycloak_saml
```

## Étape 10 · Les scripts d’`alice` : sans mot de passe, sans navigateur

**Pourquoi cette étape.** La connexion fédérée suppose un navigateur et une personne qui tape son mot de passe. Un script de sauvegarde lancé la nuit n’a ni l’un ni l’autre. La réponse d’OpenStack est l’**identifiant d’application** (TP 4, § 4.5) : un couple identifiant/secret, créé par l’utilisateur, limité à un projet, avec une date d’expiration, et révocable sans toucher au compte.

### 10a · Une condition préalable, propre aux comptes fédérés

Un identifiant d’application doit survivre à la session : Keystone exige donc que l’utilisateur ait un rôle **enregistré** sur le projet. Or le rôle d’`alice` vient du groupe du mapping, recalculé à chaque connexion et jamais enregistré (étape 7d). La plateforme donne donc d’abord le rôle directement à l’utilisateur fantôme, pour les seules personnes qui ont besoin de scripts :

```bash
FED=$(openstack user list --domain keycloak -f value -c ID | head -1)
openstack role add --user "$FED" --project formation --project-domain keycloak member
openstack role assignment list --user "$FED" --project formation --project-domain keycloak --names
```

**Ligne 1 : retrouver l’identifiant du fantôme.**

| Morceau | Ce qu’il fait |
|---|---|
| `openstack user list --domain keycloak` | Les utilisateurs du domaine `keycloak` (7d) |
| `-f value -c ID` | Format brut (`-f value`, sans tableau), colonne `ID` seulement : on obtient l’identifiant nu |
| `\| head -1` | La première ligne, au cas où il y en aurait plusieurs |
| `FED=$(…)` | Dans la variable `FED` |

On passe par l’identifiant parce que le nom du fantôme (`G-5082…`) n’est pas fait pour être tapé.

**Ligne 2 :** `openstack role add --user "$FED" …` : la même commande qu’en 6a, mais sur un **utilisateur** au lieu d’un groupe. C’est l’exception à la règle « jamais de rôle direct » : on l’accepte ici parce qu’un identifiant d’application ne peut pas s’appuyer sur un groupe calculé.

**Ligne 3 :** vérifier.

✅ **Attendu :** une ligne `member | G-50829266-… | | formation@keycloak`.

### 10b · `alice` crée son identifiant et s’en sert

Il faut un jeton fédéré valide dans `T` (étape 7). Si le jeton a été révoqué à l’étape 8, relancer `python3 ~/test-sso-saml.py alice` puis `T=$(cat ~/lab-sec-fed-token)`.

```bash
umask 077
F application credential create lab-sec-alice-script --role member \
  --expiration "$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%S)" -f json > ~/lab-sec-alice-ac.json
ACID=$(python3 -c 'import json; print(json.load(open("/home/vagrant/lab-sec-alice-ac.json"))["id"])')
ACS=$(python3 -c 'import json; print(json.load(open("/home/vagrant/lab-sec-alice-ac.json"))["secret"])')
env -u OS_USERNAME -u OS_PASSWORD -u OS_USER_DOMAIN_NAME -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_NAME \
  openstack --os-auth-type v3applicationcredential \
  --os-application-credential-id "$ACID" --os-application-credential-secret "$ACS" network list -c Name
```

**Ligne 1 : `umask 077`.** Le fichier qui va contenir le secret ne doit être lisible que par toi (voir étape 2).

**Lignes 2 et 3 : créer l’identifiant, en tant qu’`alice`.**

| Morceau | Ce qu’il fait | Pourquoi |
|---|---|---|
| `F application credential create` | Via `F`, donc **avec le jeton d’`alice`** sur `formation` | C’est l’utilisateur qui crée ses propres identifiants d’application ; ils héritent de ses droits, pas de ceux de l’administrateur |
| `lab-sec-alice-script` | Le nom de l’identifiant | Un nom par usage, pour savoir quoi révoquer |
| `--role member` | Les rôles qu’il portera, **nommés** | Un identifiant ne reçoit que les rôles qu’on cite ; les implications ne suivent pas (TP 4, § 4.5) |
| `--expiration "$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%S)"` | Date d’expiration : `date` calcule « maintenant + 30 jours » en UTC (`-u`), au format que Keystone attend (`2026-11-17T11:03:41`) | Un secret qui traîne dans un script a une fin |
| `-f json > ~/lab-sec-alice-ac.json` | Réponse en JSON, écrite dans un fichier | Le **secret n’est affiché qu’une fois**, à la création ; on le garde dans un fichier protégé au lieu de l’écran |

**Lignes 4 et 5 : extraire l’identifiant et le secret du fichier.** Deux petits programmes Python : `json.load(open(…))` lit le fichier JSON, `["id"]` et `["secret"]` en prennent un champ, `print` l’affiche, `$(…)` le met dans la variable (`ACID` : identifiant, `ACS` : secret).

**Lignes 6 à 8 : s’en servir, sans `F`, sans jeton, sans mot de passe.**

| Morceau | Ce qu’il fait |
|---|---|
| `env -u …` | Comme dans `F` : retirer les variables de l’administrateur |
| `--os-auth-type v3applicationcredential` | S’authentifier avec un **identifiant d’application** |
| `--os-application-credential-id "$ACID"` | Lequel |
| `--os-application-credential-secret "$ACS"` | Son secret |
| `network list -c Name` | La même commande qu’en 7c |

✅ **Attendu** (18 octobre) : l’identifiant est créé, et la dernière commande liste `external-network` : le script agit sur `formation`, **sans mot de passe de personne, sans Keycloak, sans navigateur**. C’est ce qu’un script de sauvegarde mettrait dans sa configuration.

⚠ Ce rôle enregistré (10a) ne dépend plus de Keycloak : si `alice` quitte l’entreprise, désactiver son compte Keycloak (étape 8) ne coupera **pas** ses scripts. Il faut **aussi** retirer ce rôle et supprimer ses identifiants d’application. C’est le prix de l’automatisation, à écrire dans la procédure de départ.

## Étape 11 · Ajouter un deuxième utilisateur : rien à faire dans OpenStack

**Pourquoi cette étape.** C’est la récompense de tout ce qu’on a construit. Une nouvelle personne, `bob`, rejoint l’équipe. Sans fédération, il faudrait lui créer un compte dans Keystone, lui choisir un mot de passe, le lui transmettre, et lui donner un rôle. Avec la fédération : on le crée dans Keycloak, on le met dans l’équipe, **et c’est tout**. Keystone le découvrira à sa première connexion, et le mapping le placera dans le bon groupe, avec les bons droits.

### 11a · Dans Keycloak : créer `bob` et le mettre dans l’équipe

Realm **lab** :

1. **Users → Add user** : *Username* `bob`, *Email* `bob@lab.test`, *First name* `Bob`, *Last name* `Durand`, *Email verified* activé, *Required user actions* vide → **Create**.
2. Onglet **Credentials → Set password** : un mot de passe d’au moins 12 caractères, *Temporary* désactivé → **Save**.
3. Onglet **Groups → Join Group** : cocher `openstack-formation` → **Join**.

Le point 3 n’est indispensable que si le mapping filtré de l’étape 9 est actif. Avec le mapping du lab (étape 6), toute personne de Keycloak entre. Le faire quand même : c’est ce qu’on ferait en entreprise.

### 11b · Avant qu’il se connecte : Keystone ne le connaît pas

```bash
openstack user list --domain keycloak
```

✅ **Attendu :** une seule ligne, le fantôme d’`alice` (`G-5082…`). Aucune trace de `bob` : on n’a rien fait dans Keystone, et c’est le but.

### 11c · `bob` se connecte

```bash
python3 ~/test-sso-saml.py bob
```

Même script qu’à l’étape 7b, avec `bob` à la place d’`alice`. Il demande le mot de passe Keycloak de `bob`.

✅ **Attendu :** `3. Réponse de Keystone : 201`, puis `Utilisateur : G-…` (un **autre** code que celui d’`alice`), `domaine : keycloak`, `groupes (id) : ['2e13f063…']` (le **même** groupe `lab_members`).

**Comment le lire.** Le trajet est identique à celui d’`alice` : Keycloak a vérifié le mot de passe de `bob`, Keystone a reconnu le passeport, et le mapping a fait son travail : « une personne de Keycloak → groupe `lab_members` ». Personne n’a touché à Keystone.

### 11d · Ce que `bob` peut faire, et ce que Keystone a créé

```bash
T=$(cat ~/lab-sec-fed-token)
F network list -c Name
F user list
openstack user list --domain keycloak
```

| Ligne | Ce qu’elle fait |
|---|---|
| `T=$(cat ~/lab-sec-fed-token)` | Le script vient d’écraser le fichier avec le jeton de `bob` : on le recharge dans `T`, que la fonction `F` (étape 7c) utilise |
| `F network list -c Name` | Les réseaux de `formation`, avec le jeton de `bob` |
| `F user list` | Essai d’une action d’administrateur |
| `openstack user list --domain keycloak` | En tant qu’administrateur : les fantômes |

✅ **Attendu :** `external-network` ; puis ⛔ `403 … identity:list_users` ; puis **deux** lignes `G-…` dans le domaine `keycloak`.

**Comment le lire.** `bob` a exactement les droits d’`alice` : `member` sur `formation`, rien de plus, parce qu’ils sont dans le même groupe. Keystone a créé son fantôme à la première connexion, sans mot de passe. **Zéro commande OpenStack** pour accueillir un nouvel utilisateur : c’est ce qu’on a gagné.

**Ce qu’on a maintenant :** l’arrivée d’une personne, c’est une action dans l’annuaire. Son départ aussi (étape 8). OpenStack n’est plus dans la boucle.

### 11e · Et pour une autre équipe, sur un autre projet ?

Le mapping peut contenir **plusieurs règles**. Exemple : l’équipe `openstack-prod` de Keycloak doit arriver dans un groupe `prod_ops`, `member` d’un projet `production`. Côté Keystone, on ajoute la cible et une seconde règle ; côté Keycloak, un groupe `openstack-prod` et les personnes dedans. Le mapper de l’étape 9a transmet déjà tous les groupes.

```bash
openstack group create --domain keycloak prod_ops
openstack project create --domain keycloak production
openstack role add --group prod_ops --group-domain keycloak --project production --project-domain keycloak member
cat > ~/lab-sec-mapping-deux-equipes.json <<'JSON'
[
  { "local":  [ { "user": { "name": "{0}" }, "group": { "domain": { "name": "keycloak" }, "name": "lab_members" } } ],
    "remote": [ { "type": "REMOTE_USER" }, { "type": "MELLON_groups", "any_one_of": ["openstack-formation"] } ] },
  { "local":  [ { "user": { "name": "{0}" }, "group": { "domain": { "name": "keycloak" }, "name": "prod_ops" } } ],
    "remote": [ { "type": "REMOTE_USER" }, { "type": "MELLON_groups", "any_one_of": ["openstack-prod"] } ] }
]
JSON
openstack mapping set --rules ~/lab-sec-mapping-deux-equipes.json keycloak_saml
```

| Ligne | Ce qu’elle fait |
|---|---|
| `group create`, `project create`, `role add` | La cible de la seconde équipe, comme en 6a |
| Le fichier : deux règles | Chaque règle a sa condition de groupe (`any_one_of`) et sa destination (`group.name`). Keystone évalue **toutes** les règles : une personne dans les deux groupes Keycloak entre dans les deux groupes Keystone |
| `mapping set` | Remplace le mapping, comme en 9b |

**Comment le lire.** C’est le découpage standard (diapositive IAM) appliqué à la fédération : un groupe Keycloak par équipe, un groupe Keystone par équipe, un rôle sur un projet. Pour changer les droits d’une personne, on change son groupe **dans Keycloak** ; pour changer ce qu’un groupe peut faire, on change le rôle **dans Keystone**. Jamais de rôle sur une personne.

Remettre le mapping du lab pour la suite, et retirer la cible d’essai :

```bash
openstack mapping set --rules ~/mapping.json keycloak_saml
openstack project delete production --domain keycloak
openstack group delete prod_ops --domain keycloak
rm -f ~/lab-sec-mapping-deux-equipes.json
```

## Retour arrière

Après la démo 3, qui utilise `alice`. Le fantôme de `bob` (étape 11) est supprimé avec le domaine, comme celui d’`alice` ; supprimer aussi `bob` dans Keycloak au temps 5. Joué le 18 octobre. Cinq temps, dans l’ordre inverse de la construction : d’abord la règle de la douane (6), puis le fournisseur (4), puis les clés (2), puis Keycloak (5 et 1).

**1. Les objets de Keystone** (étape 6, puis l’utilisateur fantôme de 7d) :

```bash
source ~/admin-openrc
openstack federation protocol delete --identity-provider keycloak saml2
openstack mapping delete keycloak_saml
openstack identity provider delete keycloak
for u in $(openstack user list --domain keycloak -f value -c ID); do openstack user delete "$u"; done
openstack project delete formation --domain keycloak
openstack group delete lab_members --domain keycloak
openstack domain set --disable keycloak
openstack domain delete keycloak
rm -f ~/lab-sec-fed-token ~/lab-sec-alice-ac.json ~/lab-sec-mapping-groupe.json ~/lab-sec-bundle.pem
```

| Ligne | Ce qu’elle défait | Pourquoi dans cet ordre |
|---|---|---|
| `federation protocol delete` | Le protocole (6b, ligne 5) | Il dépend du fournisseur et du mapping : on le retire en premier |
| `mapping delete` | Le mapping (6b, ligne 4) | |
| `identity provider delete` | Le fournisseur (6b, ligne 3) | |
| `for u in $(openstack user list --domain keycloak -f value -c ID); do openstack user delete "$u"; done` | **Tous** les fantômes du domaine (`alice`, `bob`…) et, avec eux, leurs identifiants d’application (10). `for u in $(…)` : pour chaque identifiant renvoyé par la liste | Keystone supprime les identifiants d’application avec leur propriétaire ; un domaine ne se supprime pas tant qu’il contient des utilisateurs |
| `project delete`, `group delete` | La cible (6a) | Un domaine ne se supprime pas s’il contient encore des projets |
| `domain set --disable`, puis `domain delete` | Le domaine (6a) | Un domaine doit être désactivé avant d’être supprimé (TP 2) |
| `rm -f …` | Les fichiers de travail : jeton, secret d’identifiant, mapping d’essai, et le fichier que le script de test a créé | Un jeton et un secret ne traînent pas |

**2. Le fournisseur côté Juju** (étape 4) :

```bash
juju remove-application -m openstack keystone-idp-saml2-keycloak --no-prompt
```

| Morceau | Ce qu’il fait |
|---|---|
| `juju remove-application -m openstack keystone-idp-saml2-keycloak` | Supprime l’application déployée en 4a, et sa relation avec Keystone |
| `--no-prompt` | Ne pas demander `Continue [y/N]?` |

L’application disparaît de `juju status` en une minute environ ; Keystone répond `503` quelques instants, le temps de reconfigurer Apache sans le module SAML.

**3. Faire oublier « Keycloak - Lab » à Horizon.** Quand il ne reste aucun fournisseur fédéré, le charm Keystone n’efface pas la liste déjà envoyée à Horizon, et Horizon ne réécrit pas sa configuration seul. On recrée la relation, puis on fait régénérer la configuration de Horizon :

```bash
juju remove-relation -m openstack horizon:trusted-dashboard keystone:trusted-dashboard
juju status -m openstack --relations | grep trusted-dashboard
juju integrate -m openstack horizon:trusted-dashboard keystone:trusted-dashboard
juju exec -m openstack --unit horizon/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"
curl -s --cacert "$OS_CACERT" https://cloud.lab.test/openstack-horizon/auth/login/ | grep -c "Keycloak - Lab"
```

| Ligne | Ce qu’elle fait |
|---|---|
| `juju remove-relation … trusted-dashboard` | Coupe la relation par laquelle Keystone dit à Horizon quelles méthodes de connexion proposer |
| `juju status … --relations \| grep trusted-dashboard` | Vérifie qu’elle a disparu ; relancer jusqu’à ce que la ligne n’apparaisse plus (20 s environ) |
| `juju integrate …` | La recrée : Keystone renvoie alors la liste **actuelle**, vide |
| `juju exec -m openstack --unit horizon/0 -- "JUJU_DISPATCH_PATH=hooks/config-changed ./dispatch"` | Exécute, dans l’unité `horizon/0`, le traitement « configuration modifiée » du charm (`./dispatch` est le point d’entrée de tout charm ; la variable `JUJU_DISPATCH_PATH` lui dit quel événement jouer). Il réécrit `local_settings.py` à partir de l’état actuel des relations |
| `curl … \| grep -c "Keycloak - Lab"` | Compte (`-c`) les occurrences du libellé dans la page de connexion de Horizon |

✅ **Attendu** (18 octobre) : `0`. La page de connexion de Horizon redevient le simple formulaire d’origine.

**4. La paire de clés SAML** (étape 2) :

```bash
juju config -m openstack keystone saml-x509-keypair
juju config -m openstack keystone --reset saml-x509-keypair
juju remove-secret -m openstack <ID>
rm -rf ~/saml ~/keycloak-idp.xml ~/keystone-sp.xml ~/ca-lf.crt ~/ca.crt ~/mapping.json ~/extract-sp.py ~/test-sso-saml.py
```

| Ligne | Ce qu’elle fait |
|---|---|
| `juju config … saml-x509-keypair` | Affiche `secret:<ID>` : noter cet identifiant |
| `juju config … --reset saml-x509-keypair` | Remet l’option à vide : Keystone retire la paire de clés de sa configuration |
| `juju remove-secret -m openstack <ID>` | Supprime le secret lui-même (🔁 remplacer `<ID>` par l’identifiant noté). Le `--reset` ne le fait pas |
| `rm -rf …` | Les fichiers de l’étape 0c, 2, 3 et 5a |

✅ **Attendu :** `juju config … saml-x509-keypair` n’affiche plus rien, et Keystone revient `active idle` en moins d’une minute.

**5. Dans Keycloak** (étapes 5 et 1) : supprimer le client `urn:saml2:keycloak`, le groupe `openstack-formation` et l’utilisateur `alice`.

Si un instantané VirtualBox a été pris avant la démo, le restaurer est le retour arrière le plus complet.

## À retenir

- La fédération **sépare** deux métiers : Keycloak vérifie l’identité, Keystone donne les droits. Elle déplace l’authentification, pas l’autorisation.
- La confiance s’établit **dans les deux sens** : Keystone reconnaît la signature de Keycloak (étape 4), Keycloak reconnaît celle de Keystone (étape 5). Chaque étape produit ce que la suivante consomme : clés → carte d’identité de l’IdP → fournisseur côté Keystone → client côté Keycloak → mapping.
- La fédération ne donne **aucun droit** : c’est le mapping, le groupe et l’affectation qui décident, selon le moindre privilège. `alice` est `member` de `formation` parce que 6a l’a décidé, pas parce que Keycloak l’a dit.
- Le mot de passe des personnes ne passe plus par OpenStack ; la politique et la désactivation des comptes se gèrent à **un seul endroit**, puis on coupe les jetons en cours. Les identifiants d’application des scripts, eux, doivent être traités à part.
- Deux CA, deux usages : à chaque `curl`, la CA du lab vers Keycloak, la CA de Sunbeam vers le cloud. Et deux certificats côté Keystone : HTTPS pour le transport, SAML pour signer.
- Sur ce lab (Sunbeam 2024.1), on déploie le fournisseur avec Juju plutôt qu’avec `sunbeam identity provider add` (CA privée), et on teste sur Keystone plutôt que par Horizon (charm rév. 440). Les deux limites sont propres à cette version.
- Le compte `admin` local de Keystone reste indispensable pour réparer une fédération en panne : c’est un compte de **secours**, à protéger particulièrement (démo 3).
