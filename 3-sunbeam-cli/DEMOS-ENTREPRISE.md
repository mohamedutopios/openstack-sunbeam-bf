# Sunbeam en entreprise : cinq démos à reproduire chez soi

Ce document rassemble **cinq démos courtes**, choisies parce qu’elles correspondent à des tâches réelles d’un exploitant de cloud OpenStack Sunbeam. Chacune part d’une **situation d’entreprise**, montre les commandes, leur **sortie réelle**, comment la **lire**, et ce qu’il faut faire si le résultat est différent.

Elles sont faites pour être **rejouées** après la formation, telles quelles, sur un autre cloud Sunbeam : il suffit d’adapter les noms signalés.

| # | Situation en entreprise | Ce que la démo apporte | Durée |
|---|---|---|---|
| 1 | « Le cloud fonctionne-t-il ? » : le matin, après un redémarrage, avant une intervention | Un contrôle de santé en 4 commandes, avec un verdict automatique OK / ANOMALIE | 5 min |
| 2 | Un administrateur arrive dans l’équipe | Des accès propres : fichiers protégés, profils nommés, aucun mot de passe affiché | 10 min |
| 3 | Après une intervention, on veut une preuve que le cloud rend le service | Une VM de test joignable depuis le PC, puis un nettoyage complet | 15 min |
| 4 | On prépare un changement (ajout d’un service, mise à jour) | Un dossier de changement : l’état « avant », comparable à « après » | 5 min |
| 5 | Les équipes demandent un nouveau service : l’orchestration | Ajouter Heat avec Sunbeam, l’utiliser pour créer un environnement complet, le retirer proprement, et **prouver** le retour à l’état initial | 40 min |

**Tests :** toutes les commandes ont été exécutées le **17 octobre 2026**, dans cet ordre, sur le lab de formation : snap `openstack` 2024.1 (révision 1101), déploiement `star-heron`, un seul nœud `sunbeam`. Les sorties sont réelles. Seuls les mots de passe sont masqués.

**Le guide de référence** `README.md` du même dossier détaille chaque commande `sunbeam` ; ce document se concentre sur des scénarios complets.

---

## Avant de commencer

### Où taper les commandes

Dans **Lab-Sunbeam**, avec le compte `vagrant`. Depuis Windows :

```powershell
ssh vagrant@192.168.56.10
```

Ouvre une **session neuve** pour chaque démo. Les variables chargées par un `source …openrc` d’une session précédente peuvent fausser les résultats.

### Comment lire ce document

| Repère | Signification |
|---|---|
| **Situation** | Pourquoi on fait cela en entreprise |
| **À quoi ça sert** | Ce que fait la commande |
| **Ce que tu vois** | La sortie réelle du lab |
| **Comment le lire** | L’interprétation, valeur par valeur |
| **Si tu vois autre chose** | Les écarts possibles et la conduite à tenir |
| 🔁 **À adapter chez toi** | Les noms propres au lab à remplacer |

### Ce qui distingue `sunbeam` des autres commandes

| Commande | Rôle | Dans ce document |
|---|---|---|
| `sunbeam` | **Exploite** le cloud : santé, accès, ajout ou retrait de services | Le cœur des démos |
| `openstack` | **Utilise** le cloud : VM, réseaux, piles Heat | Pour vérifier ce que `sunbeam` a fait |
| `juju` | **Observe** les composants internes | Pour suivre une activation |

---

## Démo 1 : le contrôle de santé (5 min)

### Situation

Chaque matin, après un redémarrage, ou avant toute intervention, l’exploitant vérifie que le cloud est en bon état. Une intervention sur un cloud déjà malade complique tout diagnostic ensuite.

### Étape 1 : se reconnecter

```bash
sunbeam utils juju-login
```

**À quoi ça sert :** `sunbeam` interroge Juju, qui pilote les composants du cloud. Après un redémarrage, la session Juju a souvent expiré.

**Ce que tu vois :**

```text
Juju re-login complete.
```

**Si tu vois autre chose :** sans cette commande, les suivantes peuvent répondre `Error: Failed to login to Juju Controller`. Ce n’est pas une panne : relancer `sunbeam utils juju-login`.

### Étape 2 : quel cloud ?

```bash
sunbeam deployment list
```

**À quoi ça sert :** une machine d’administration peut gérer plusieurs clouds. Toutes les commandes `sunbeam` visent le **déploiement courant**. On vérifie donc d’abord qu’on regarde le bon.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━┓
┃ Deployment  ┃ Endpoint ┃ Type  ┃
┡━━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━┩
│ star-heron* │ local    │ local │
└─────────────┴──────────┴───────┘
```

**Comment le lire :** un seul cloud, `star-heron` ; l’astérisque `*` indique qu’il est le **courant**. `local` : installé sur des machines préparées à la main (l’autre type, `maas`, désigne des serveurs physiques gérés par MAAS).

**Si tu vois autre chose :** plusieurs lignes, et l’astérisque sur le mauvais cloud : `sunbeam deployment switch NOM`.

### Étape 3 : les machines et leurs rôles

```bash
sunbeam cluster list
```

**À quoi ça sert :** savoir de quelles machines est fait le cloud, quel rôle tient chacune, et si chaque rôle fonctionne.

**Ce que tu vois :**

```text
                          openstack-machines
┏━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┓
┃ Node    ┃ Machine ┃ Cluster ┃ Compute ┃ Control ┃ Network ┃ Storage ┃
┡━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━┩
│ sunbeam │ running │ ONLINE  │ active  │ active  │         │ active  │
└─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┘
```

**Comment le lire :** une ligne par machine.

| Colonne | Valeur | Signification |
|---|---|---|
| `Node` | `sunbeam` | Le nom de la machine |
| `Machine` | `running` | La machine est connue de Juju et son agent tourne |
| `Cluster` | `ONLINE` | Elle est membre du cluster Sunbeam et répond |
| `Compute` | `active` | Elle peut héberger des VM |
| `Control` | `active` | Elle porte les services OpenStack (Keystone, Nova…) |
| `Network` | *(vide)* | Elle n’a pas ce rôle : normal sur un nœud unique |
| `Storage` | `active` | Elle fournit le stockage Ceph |

⚠ L’ordre des colonnes `Machine` et `Cluster` **peut changer** d’une exécution à l’autre : lire les titres, pas les positions.

### Étape 4 : un verdict automatique

**À quoi ça sert :** un tableau se lit à l’œil ; un contrôle répété chaque jour, ou sur dix machines, doit donner un **verdict** sans interprétation. La forme YAML s’y prête.

```bash
sunbeam cluster list -f yaml
```

**Ce que tu vois :**

```yaml
openstack-machines:
  '0':
    hostname: sunbeam
    status:
      cluster: ONLINE
      compute: active
      control: active
      machine: running
      storage: active
```

**Comment le lire :** les mêmes informations, une par ligne, toujours dans le même ordre. Un rôle absent (ici `network`) n’apparaît pas.

On en tire un verdict :

```bash
sunbeam cluster list -f yaml | grep -E -q "blocked|error|waiting|maintenance|OFFLINE|unknown" && echo "ANOMALIE : voir sunbeam cluster list" || echo "OK : tous les noeuds et roles sont sains"
```

**La commande, mot par mot :**

| Morceau | Rôle |
|---|---|
| `grep -E -q "blocked\|error\|…"` | Cherche un des mots qui signalent un problème ; `-q` = sans rien afficher, seulement réussir ou échouer |
| `&& echo "ANOMALIE…"` | Exécuté si un mot a été trouvé |
| `\|\| echo "OK…"` | Exécuté sinon |

**Ce que tu vois :**

```text
OK : tous les noeuds et roles sont sains
```

🔁 **À adapter chez toi :** cette ligne peut être placée dans un script lancé chaque matin, dont la sortie est envoyée par courriel ou à l’outil de supervision.

### Étape 5 : aucune opération bloquée

```bash
sunbeam plans list
```

**À quoi ça sert :** Sunbeam découpe le cloud en **plans** (Terraform), un par couche. Pendant une opération, le plan concerné est **verrouillé**. Un verrou resté en place après une coupure bloque toutes les commandes suivantes.

**Ce que tu vois :**

```text
┏━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┓
┃ Plan                 ┃ Locked ┃
┡━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━┩
│ hypervisor-plan      │        │
│ microceph-plan       │        │
│ cinder-volume-plan   │        │
│ demo-setup           │        │
│ k8s-plan             │        │
│ sunbeam-machine-plan │        │
│ openstack-plan       │        │
└──────────────────────┴────────┘
```

**Comment le lire :** colonne `Locked` vide partout : **aucune opération en cours**, on peut intervenir.

### Si tu vois autre chose

| Ce que tu vois | Signification | Que faire |
|---|---|---|
| `blocked` dans un rôle | Le composant attend une intervention humaine | `juju status -m admin/openstack-machines` pour lire son message (guide `4-juju-cli/`, démo 4) |
| `waiting` ou `maintenance` | Le composant démarre ou se reconfigure | Attendre 5 minutes, relancer la démo 1 |
| `Cluster` différent de `ONLINE` | La machine ne répond plus au cluster | Vérifier qu’elle est démarrée et joignable |
| Un plan verrouillé alors que rien ne tourne | Opération interrompue | `sunbeam plans unlock NOM`, **seulement** après avoir vérifié qu’aucune commande `sunbeam` ne tourne |

**Règle :** on n’intervient sur le cloud que si la démo 1 donne **OK** et aucun verrou.

---

## Démo 2 : des accès administratifs propres (10 min)

### Situation

Un nouvel administrateur rejoint l’équipe. Il doit pouvoir utiliser la commande `openstack` en tant qu’administrateur, et tester ce que voit un utilisateur ordinaire, sans que les mots de passe traînent dans des fichiers lisibles par tous ou s’affichent à l’écran.

### Ce que `sunbeam` sait fournir

`sunbeam` génère des accès pour **deux comptes**, créés à l’installation :

| Compte | Domaine / projet | Rôle |
|---|---|---|
| `admin` | `admin_domain` / `admin` | Administrateur du cloud |
| `demo` | `users` / `demo` | Utilisateur ordinaire de démonstration, créé par `sunbeam configure` |

Pour des comptes nominatifs (`alice`, `bob`…), on les crée avec la commande `openstack` (`labs-iam/`), puis on écrit leurs accès sur le modèle ci-dessous.

### Étape 1 : le fichier openrc de l’administrateur, protégé

```bash
umask 077
mkdir -p ~/acces
sunbeam openrc > ~/acces/admin-openrc
ls -l ~/acces/admin-openrc
```

**La commande, mot par mot :**

| Ligne | Rôle |
|---|---|
| `umask 077` | Pour la suite de la session, tout fichier créé ne sera lisible **que par toi** |
| `mkdir -p ~/acces` | Un dossier dédié aux accès |
| `sunbeam openrc > …` | Écrit les variables de connexion de l’administrateur dans un fichier |
| `ls -l` | Vérifie les droits |

**Ce que tu vois :**

```text
-rw------- 1 vagrant vagrant 355 Oct 17 09:26 /home/vagrant/acces/admin-openrc
```

**Comment le lire :** `-rw-------` = lecture et écriture pour le propriétaire (`vagrant`), **rien** pour les autres. C’est l’effet de `umask 077`.

Regarder le contenu **sans** le mot de passe :

```bash
grep -v OS_PASSWORD ~/acces/admin-openrc
```

**Ce que tu vois :**

```text
# openrc for access to OpenStack
export OS_USERNAME=admin
export OS_AUTH_URL=http://cloud.lab.test/openstack-keystone/v3
export OS_USER_DOMAIN_NAME=admin_domain
export OS_PROJECT_DOMAIN_NAME=admin_domain
export OS_PROJECT_NAME=admin
export OS_AUTH_VERSION=3
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=RegionOne
```

**Comment le lire :** le compte (`admin`), l’adresse de Keystone (`OS_AUTH_URL`, la seule adresse que le client doit connaître), le domaine et le projet, la région. `grep -v` retire la ligne `OS_PASSWORD`, qui existe bien dans le fichier : c’est la forme à utiliser devant un public.

**Utilisation :** `source ~/acces/admin-openrc`, puis toutes les commandes `openstack` de la session agissent en `admin`. **Inconvénient :** on oublie vite qu’on est administrateur. L’étape 2 corrige cela.

### Étape 2 : des profils nommés dans `clouds.yaml`

**À quoi ça sert :** ranger plusieurs comptes dans un seul fichier, à l’emplacement standard, et **choisir le compte dans chaque commande**. On sait toujours qui agit, et le fichier est lu aussi par Ansible, Terraform ou le SDK Python.

```bash
sunbeam cloud-config -a -c lab-admin -u --no-hints
sunbeam cloud-config -c lab-demo -u --no-hints
```

**La commande, mot par mot :**

| Option | Rôle |
|---|---|
| `cloud-config` | Générer un profil au format `clouds.yaml` |
| `-a` | Profil de l’administrateur ; sans `-a`, profil de `demo` |
| `-c lab-admin` | Le **nom du profil**, celui qu’on tapera ensuite |
| `-u` | **Écrire** dans le fichier ; sans `-u`, la commande affiche seulement le profil |
| *(pas de `-f`)* | Fichier par défaut : `~/.config/openstack/clouds.yaml`, que le client `openstack` lit tout seul |
| `--no-hints` | Pas de question interactive |

**Ce que tu vois :**

```text
Writing cloud information to /home/vagrant/.config/openstack/clouds.yaml ...
done
Writing cloud information to /home/vagrant/.config/openstack/clouds.yaml ...
done
```

La seconde commande **ajoute** son profil sans effacer le premier.

### Étape 3 : protéger le fichier

```bash
ls -l ~/.config/openstack/clouds.yaml
chmod 600 ~/.config/openstack/clouds.yaml
ls -l ~/.config/openstack/clouds.yaml
```

**Ce que tu vois :**

```text
-rw-rw---- 1 vagrant vagrant 515 Oct 17 09:27 /home/vagrant/.config/openstack/clouds.yaml
-rw------- 1 vagrant vagrant 515 Oct 17 09:27 /home/vagrant/.config/openstack/clouds.yaml
```

**Comment le lire :** `sunbeam` crée le fichier lisible par le **groupe** (`rw-rw----`), malgré le `umask`. Comme il contient les mots de passe **en clair**, on le restreint au seul propriétaire (`rw-------`). À faire **à chaque** génération.

Vérifier le contenu sans les mots de passe :

```bash
grep -E "^  [a-z-]+:$|username|project_name|domain_name" ~/.config/openstack/clouds.yaml
```

**Ce que tu vois :**

```text
  lab-admin:
      project_domain_name: admin_domain
      project_name: admin
      user_domain_name: admin_domain
      username: admin
  lab-demo:
      project_domain_name: users
      project_name: demo
      user_domain_name: users
      username: demo
```

**Comment le lire :** deux profils, `lab-admin` et `lab-demo`, chacun avec son compte, son domaine et son projet.

### Étape 4 : utiliser les profils

```bash
openstack --os-cloud lab-demo network list -c Name
openstack --os-cloud lab-admin hypervisor list
openstack --os-cloud lab-demo hypervisor list
```

**Ce que tu vois :**

```text
+------------------+
| Name             |
+------------------+
| demo-network     |
| external-network |
+------------------+
+--------------------------------------+---------------------+-----------------+-----------+-------+
| ID                                   | Hypervisor Hostname | Hypervisor Type | Host IP   | State |
+--------------------------------------+---------------------+-----------------+-----------+-------+
| cc165330-eaa5-44bc-968c-e364028e8b1a | sunbeam             | QEMU            | 10.0.2.15 | up    |
+--------------------------------------+---------------------+-----------------+-----------+-------+
ForbiddenException: 403: Client Error for url: http://cloud.lab.test:80/openstack-nova/v2.1/os-hypervisors/detail, Policy doesn't allow os_compute_api:os-hypervisors:list-detail to be performed.
```

**Comment le lire :**

| Commande | Résultat | Ce que ça prouve |
|---|---|---|
| `lab-demo network list` | Les réseaux visibles par `demo` | Le profil utilisateur fonctionne |
| `lab-admin hypervisor list` | L’hyperviseur `sunbeam` | Le profil administrateur fonctionne |
| `lab-demo hypervisor list` | `403`, règle `os-hypervisors:list-detail` refusée | Les droits sont bien séparés : un utilisateur ne voit pas l’infrastructure |

Aucun `source`, aucune variable chargée : le compte est **écrit dans la commande**.

### Étape 5 : l’adresse de l’interface web

```bash
sunbeam dashboard url
```

**Ce que tu vois :**

```text
http://cloud.lab.test:80/openstack-horizon
```

**Comment le lire :** Horizon est servi par le nom public du cloud, en HTTP (le TLS n’est pas activé sur ce lab). Vérifié depuis Windows : la page répond `200`.

⚠ L’ancienne forme `sunbeam dashboard-url` fonctionne encore, mais affiche un avertissement `This command is deprecated`.

### Si tu vois autre chose

| Ce que tu vois | Cause | Que faire |
|---|---|---|
| `Cloud lab-admin was not found` | Fichier non écrit (oubli de `-u`) ou écrit ailleurs (`-f`) | Relancer avec `-u`, sans `-f` |
| Le mauvais compte répond | Des variables `OS_*` sont chargées dans la session | Nouvelle session, sans `source` |
| `Generated … /tmp/…` mais fichier introuvable | `sunbeam` est un snap avec son propre `/tmp` | Toujours écrire dans `~/` |
| `401` | Mot de passe changé depuis la génération | Régénérer le profil |

### À retenir pour l’entreprise

- Les mots de passe sont **en clair** dans ces fichiers : droits `600`, jamais en pièce jointe, jamais dans un dépôt Git.
- On ne remet **jamais** le compte `admin` à une équipe : on lui crée ses comptes et son projet.
- Pour une application ou un script, la bonne pratique est un **identifiant d’application** (`openstack application credential create`), limité à un projet, révocable et avec une date d’expiration, plutôt qu’un mot de passe.

---

## Démo 3 : prouver que le cloud rend le service (15 min)

### Situation

Après un redémarrage, une mise à jour ou l’ajout d’un service, « tout est `active` » ne suffit pas. Il faut une **preuve de bout en bout** : une VM qui démarre, obtient une adresse publique, et répond depuis le poste de l’administrateur.

### Étape 1 : lancer une VM de test

```bash
sunbeam launch --name lab-validation
```

**À quoi ça sert :** en une commande, `sunbeam` crée une VM dans le projet de démonstration, avec tout ce qu’il faut pour la joindre.

**Ce que fait la commande, dans l’ordre :**

1. elle se connecte avec le compte `demo` ;
2. elle crée une clé SSH nommée `sunbeam` si elle n’existe pas, et garde la clé privée sur le disque ;
3. elle lance une VM : image `ubuntu`, gabarit `m1.tiny` (1 vCPU, 512 Mo), réseau `demo-network` ;
4. elle lui attribue une **IP flottante** (publique) du réseau externe.

**Ce que tu vois** (1 min 54 s sur le lab) :

```text
Launching an OpenStack instance ...
Access the instance by running the following command:
`ssh -i /home/vagrant/snap/openstack/1101/sunbeam ubuntu@192.168.57.122`
```

**Comment le lire :** la dernière ligne est la commande de connexion : la clé privée créée au point 2, le compte `ubuntu` des images Ubuntu, et l’**IP flottante**. **Note-la** : elle sert au nettoyage.

### Étape 2 : regarder la VM

```bash
openstack --os-cloud lab-demo server show lab-validation -c status -c addresses -c image -c key_name
```

(Le profil `lab-demo` vient de la démo 2.)

**Ce que tu vois :**

```text
| addresses | demo-network=10.20.0.101, 192.168.57.122 |
| image     | ubuntu (705fec8a-ae43-48cf-a441-0969e4e950be) |
| key_name  | sunbeam |
| status    | ACTIVE |
```

**Comment le lire :** `ACTIVE` = la VM tourne pour l’hyperviseur. Deux adresses : `10.20.0.101`, privée, dans `demo-network` ; `192.168.57.122`, l’IP flottante, joignable depuis le PC.

### Étape 3 : attendre la fin du démarrage

**Point important :** `ACTIVE` ne veut pas dire « prête ». Le système de la VM démarre ensuite. Sur ce lab, la virtualisation est imbriquée et lente : le démarrage a pris **environ 5 minutes et demie**. Pendant ce temps, le ping et le SSH échouent ; c’est **normal**.

Pour savoir où en est la VM, lire sa console :

```bash
openstack --os-cloud lab-demo console log show lab-validation | grep "Cloud-init .* finished"
```

**Ce que tu vois**, une fois le démarrage terminé :

```text
[  328.143424] cloud-init[1038]: Cloud-init v. 26.1-0ubuntu1~24.04.1 finished at Sat, 17 Oct 2026 09:37:41 +0000. Datasource DataSourceOpenStackLocal [net,ver=2].  Up 327.68 seconds
```

**Comment le lire :** `cloud-init` est le programme qui configure la VM au premier démarrage (adresse, clé SSH) ; `finished` = la VM est prête ; `Up 327.68 seconds` = elle a mis 5 min 28 s. Si la commande n’affiche rien, attendre une minute et recommencer.

### Étape 4 : la preuve depuis le PC

Dans **PowerShell, sur Windows** :

```powershell
ping 192.168.57.122
```

**Ce que tu vois :**

```text
Réponse de 192.168.57.122 : octets=32 temps=3 ms TTL=63
Réponse de 192.168.57.122 : octets=32 temps=5 ms TTL=63
Réponse de 192.168.57.122 : octets=32 temps=17 ms TTL=63
```

**Comment le lire :** la VM répond depuis le poste de travail. `TTL=63` = un routeur traversé (le routeur virtuel du projet) : le trafic passe bien par le réseau du cloud.

Puis, dans **Lab-Sunbeam**, entrer dans la VM :

```bash
ssh -i ~/snap/openstack/1101/sunbeam ubuntu@192.168.57.122 "hostname; uptime; curl -s -m 10 -o /dev/null -w 'internet %{http_code}\n' http://archive.ubuntu.com"
```

**Ce que tu vois :**

```text
lab-validation
 09:37:47 up 5 min,  1 user,  load average: 5.23, 3.25, 1.41
internet 200
```

**Comment le lire :** on est bien dans la VM (`hostname`), qui tourne depuis 5 minutes, et qui **accède à Internet** (`200` = page reçue). La chaîne complète fonctionne : calcul, image, réseau privé, routeur, IP flottante, sortie vers l’extérieur.

À la première connexion, SSH demande de confirmer l’empreinte de la VM : répondre `yes`.

### Étape 5 : nettoyer

```bash
openstack --os-cloud lab-demo server delete lab-validation --wait
openstack --os-cloud lab-demo floating ip list -c "Floating IP Address" -c "Fixed IP Address"
```

**Ce que tu vois :**

```text
+---------------------+------------------+
| Floating IP Address | Fixed IP Address |
+---------------------+------------------+
| 192.168.57.122      | None             |
+---------------------+------------------+
```

**Comment le lire :** la VM est supprimée, mais **son IP flottante reste réservée** au projet (`Fixed IP Address: None` = attachée à rien). Une adresse publique oubliée est une ressource perdue, et souvent facturée chez un fournisseur. On la rend, puis on retire la clé :

```bash
openstack --os-cloud lab-demo floating ip delete 192.168.57.122
openstack --os-cloud lab-demo keypair delete sunbeam
rm -f ~/snap/openstack/*/sunbeam
openstack --os-cloud lab-demo server list
openstack --os-cloud lab-demo floating ip list
```

✅ **Attendu :** les deux dernières commandes n’affichent **rien**.

🔁 **À adapter chez toi :** l’IP flottante est celle affichée par `sunbeam launch` ; le dossier `1101` est la révision du snap (`~/snap/openstack/*/` couvre toutes les révisions).

### Si tu vois autre chose

| Symptôme | Cause probable | Que faire |
|---|---|---|
| `sunbeam launch` échoue, la VM est en `ERROR` | Calcul, image ou capacité | Guide `5-openstack-cli/`, démo 5 |
| Pas de ping depuis Windows après 10 minutes | Carte réseau 3 de Lab-Sunbeam sur le mauvais réseau, ou routage du PC | Guide apprenant, étape 10 |
| Ping OK, SSH `Connection refused` | Le service SSH de la VM n’a pas encore démarré | Attendre la ligne `finished` de l’étape 3 |
| `Permission denied (publickey)` | Mauvaise clé | Utiliser exactement le chemin affiché par `sunbeam launch` |

⚠ `sunbeam launch` sert à **valider** un cloud, pas à créer des VM de travail : il utilise toujours le projet de démonstration.

---

## Démo 4 : préparer un changement (5 min)

### Situation

Toute intervention sur un cloud de production passe par un **dossier de changement** : ce qui va être fait, l’état avant, l’état après, et la preuve que le retour arrière est possible. Sunbeam permet de **photographier** l’état du cloud en quelques fichiers, qu’on comparera ensuite.

### Étape 1 : créer le dossier

```bash
DOSSIER=~/changements/$(date +%F)-ajout-heat
mkdir -p "$DOSSIER/avant"
```

**La commande, mot par mot :** `$(date +%F)` = la date du jour (`2026-10-17`) ; la variable `DOSSIER` garde le chemin pour la suite de la session. Un dossier par changement, daté et nommé.

🔁 **À adapter chez toi :** remplace `ajout-heat` par le nom de ton changement.

### Étape 2 : photographier l’état « avant »

```bash
sunbeam manifest generate -f "$DOSSIER/avant/manifest.yaml"
sunbeam list-features -f yaml > "$DOSSIER/avant/features.yaml"
sunbeam cluster list -f yaml > "$DOSSIER/avant/cluster.yaml"
openstack --os-cloud lab-admin catalog list -f value -c Name | sort > "$DOSSIER/avant/catalogue.txt"
openstack --os-cloud lab-admin domain list -f value -c Name | sort > "$DOSSIER/avant/domaines.txt"
chmod -R go-rwx "$DOSSIER"
```

**Ce que contient chaque fichier :**

| Fichier | Commande | Ce qu’il photographie |
|---|---|---|
| `manifest.yaml` | `sunbeam manifest generate` | La **configuration complète** : réseaux, adresses, versions des composants (612 lignes) |
| `features.yaml` | `sunbeam list-features -f yaml` | Les services optionnels activés ou non |
| `cluster.yaml` | `sunbeam cluster list -f yaml` | Les machines et l’état de leurs rôles |
| `catalogue.txt` | `openstack catalog list` | Les services annoncés aux utilisateurs |
| `domaines.txt` | `openstack domain list` | Les domaines d’identité |

`sort` trie les listes, pour que deux relevés soient comparables ligne à ligne. `chmod -R go-rwx` protège le dossier : le manifeste contient des **mots de passe**.

**Ce que tu vois :**

```text
Generated manifest is at /home/vagrant/changements/2026-10-17-ajout-heat/avant/manifest.yaml
```

### Étape 3 : relire la photographie

```bash
ls -l "$DOSSIER/avant"
cat "$DOSSIER/avant/features.yaml"
cat "$DOSSIER/avant/catalogue.txt"
```

**Ce que tu vois :**

```text
-rw------- 1 vagrant vagrant    64 Oct 17 09:40 catalogue.txt
-rw------- 1 vagrant vagrant   173 Oct 17 09:40 cluster.yaml
-rw------- 1 vagrant vagrant    42 Oct 17 09:40 domaines.txt
-rw------- 1 vagrant vagrant   399 Oct 17 09:40 features.yaml
-rw------- 1 vagrant vagrant 21501 Oct 17 09:40 manifest.yaml

baremetal: false
caas: false
dns: false
images-sync: false
instance-recovery: false
ldap: false
loadbalancer: false
maintenance: false
observability.embedded: false
observability.external: false
orchestration: false
pro: false
resource-optimization: false
secrets: false
shared-filesystem: false
telemetry: false
tls.ca: false
tls.self-signed: false
tls.vault: false
validation: false
vault: false

cinder
cinderv3
glance
keystone
neutron
nova
placement
s3
swift
```

**Comment le lire :** cinq fichiers protégés (`-rw-------`). Aucune fonctionnalité optionnelle activée (`false` partout, dont `orchestration`, Heat) ; neuf services au catalogue : le socle du cloud.

### Si tu vois autre chose

| Ce que tu vois | Cause | Que faire |
|---|---|---|
| `Generated … /tmp/…` mais fichier absent | Le snap a son propre `/tmp` | Toujours un chemin sous `~/` |
| `Cloud lab-admin was not found` | La démo 2 n’a pas été faite dans cette installation | Faire la démo 2, ou remplacer `--os-cloud lab-admin` par `source ~/admin-openrc` au préalable |

---

## Démo 5 : ajouter un service avec Sunbeam, Heat (40 min)

### Situation

Les équipes de développement veulent créer leurs environnements de test **en une commande**, à partir d’un fichier décrivant l’infrastructure, au lieu de cliquer dans Horizon. C’est le rôle du service d’**orchestration Heat**. L’exploitant doit l’ajouter, prouver qu’il fonctionne, et savoir le retirer proprement.

Avec Sunbeam, ajouter un service OpenStack est **une commande**. Le reste de la démo montre ce qu’un exploitant doit faire autour.

**Avant de commencer :** démo 1 = **OK**, démo 4 faite (dossier « avant »), et la variable `DOSSIER` définie dans la session (sinon : `DOSSIER=~/changements/$(date +%F)-ajout-heat`).

### Étape 1 : activer Heat

```bash
sunbeam list-features | grep orchestration
sunbeam enable orchestration
```

**La commande, mot par mot :** `enable` = activer une fonctionnalité ; `orchestration` = son nom, qui correspond au service Heat.

**Ce que tu vois :** d’abord `│ orchestration │         │` (colonne `Enabled` vide), puis, **11 minutes plus tard** :

```text
OpenStack orchestration application enabled.
```

**Ce qui se passe pendant ces 11 minutes :** `sunbeam` ajoute Heat à son plan, Terraform le décrit, Juju le déploie. Pour le voir, dans une **seconde session** SSH :

```bash
watch -n 30 "juju status -m openstack --color=false | grep -E '^heat'"
```

**Ce que tu vois défiler** (relevé sur le lab) :

| Heure | Ligne `heat/0` | Signification |
|---|---|---|
| +2 min | `waiting allocating … installing agent` | Kubernetes crée le pod de Heat |
| +4 min | `blocked … (identity-service) integration missing` | Heat attend son raccordement à Keystone : normal à ce stade |
| +5 min | `waiting … (workload) Not all relations are ready` | Raccordé à Keystone, attend la base de données et la messagerie |
| +6 min | `heat-mysql-router/0 … active` | La connexion à la base de données est prête |
| +11 min | `heat/0* active idle` | Heat est prêt |

Un `blocked` **passager** pendant une activation n’est pas une panne. Il ne devient inquiétant que s’il dure au-delà de la fin de la commande `sunbeam`.

### Étape 2 : vérifier que le service est en place

```bash
sunbeam list-features | grep orchestration
openstack --os-cloud lab-admin catalog list -f value -c Name | grep heat
openstack --os-cloud lab-admin orchestration service list -c Hostname -c Binary -c Status
```

**Ce que tu vois :**

```text
│ orchestration          │    X    │
heat-cfn
heat
+----------+-------------+--------+
| Hostname | Binary      | Status |
+----------+-------------+--------+
| heat-0   | heat-engine | up     |
| heat-0   | heat-engine | up     |
| heat-0   | heat-engine | up     |
| heat-0   | heat-engine | up     |
+----------+-------------+--------+
```

**Comment le lire :**

| Contrôle | Résultat | Signification |
|---|---|---|
| `list-features` | `X` | Sunbeam considère Heat comme activé |
| Catalogue | `heat`, `heat-cfn` | Les utilisateurs **voient** le service : `heat` pour l’API native, `heat-cfn` pour la compatibilité avec les modèles CloudFormation d’AWS |
| `orchestration service list` | 4 `heat-engine` `up` | Les processus qui exécutent les modèles tournent, dans le pod `heat-0` |

### Étape 3 : photographier l’état « après » et comparer

```bash
mkdir -p "$DOSSIER/apres"
sunbeam manifest generate -f "$DOSSIER/apres/manifest.yaml"
sunbeam list-features -f yaml > "$DOSSIER/apres/features.yaml"
sunbeam cluster list -f yaml > "$DOSSIER/apres/cluster.yaml"
openstack --os-cloud lab-admin catalog list -f value -c Name | sort > "$DOSSIER/apres/catalogue.txt"
openstack --os-cloud lab-admin domain list -f value -c Name | sort > "$DOSSIER/apres/domaines.txt"
chmod -R go-rwx "$DOSSIER"
diff -r "$DOSSIER/avant" "$DOSSIER/apres"
```

**À quoi ça sert :** `diff -r` compare les deux dossiers fichier par fichier et n’affiche **que les différences**. C’est le compte rendu exact du changement, à joindre au dossier.

**Ce que tu vois :**

```text
diff -r …/avant/catalogue.txt …/apres/catalogue.txt
3a4,5
> heat
> heat-cfn
diff -r …/avant/domaines.txt …/apres/domaines.txt
2a3
> heat
diff -r …/avant/features.yaml …/apres/features.yaml
11c11
< orchestration: false
---
> orchestration: true
```

**Comment le lire :**

| Notation | Signification |
|---|---|
| `> ligne` | Ligne présente **après**, absente avant : ajoutée |
| `< ligne` | Ligne présente **avant**, absente après : retirée |
| `3a4,5` | Après la ligne 3, ajout (*add*) des lignes 4 et 5 |
| `11c11` | Ligne 11 changée (*change*) |

Le changement réel : `orchestration` passe à `true`, deux services apparaissent au catalogue, et **un domaine `heat`** est créé (Heat y range les comptes qu’il crée pour les piles).

Ce que la comparaison montre aussi, par son silence : `manifest.yaml` et `cluster.yaml` sont **identiques**. L’activation n’a modifié ni la configuration de base ni l’état des machines. L’état « Heat activé » n’est pas dans le manifeste : il est gardé par Sunbeam et se lit avec `list-features`.

### Étape 4 : utiliser Heat, un environnement complet en une commande

**À quoi ça sert :** montrer aux équipes ce que le service leur apporte. On décrit, dans un **modèle**, un environnement applicatif complet : réseau, sous-réseau, routeur vers l’extérieur, pare-feu, VM et adresse publique. Heat crée le tout, dans le bon ordre.

Créer le modèle :

```bash
cat > ~/lab-environnement.yaml <<'EOF'
heat_template_version: 2021-04-16
description: Environnement applicatif de test - reseau, routeur, pare-feu, VM et IP publique

parameters:
  prefixe:
    type: string
    default: lab-app
    description: Prefixe des noms de ressources
  cidr:
    type: string
    default: 10.40.0.0/24
  image:
    type: string
    default: ubuntu
  gabarit:
    type: string
    default: m1.tiny
  reseau_externe:
    type: string
    default: external-network
  admin_cidr:
    type: string
    default: 192.168.57.0/24
    description: Reseau autorise en SSH et ping

resources:
  reseau:
    type: OS::Neutron::Net
    properties:
      name: {list_join: ["-", [{get_param: prefixe}, net]]}

  sous_reseau:
    type: OS::Neutron::Subnet
    properties:
      name: {list_join: ["-", [{get_param: prefixe}, subnet]]}
      network: {get_resource: reseau}
      cidr: {get_param: cidr}

  routeur:
    type: OS::Neutron::Router
    properties:
      name: {list_join: ["-", [{get_param: prefixe}, router]]}
      external_gateway_info: {network: {get_param: reseau_externe}}

  interface:
    type: OS::Neutron::RouterInterface
    properties:
      router: {get_resource: routeur}
      subnet: {get_resource: sous_reseau}

  pare_feu:
    type: OS::Neutron::SecurityGroup
    properties:
      name: {list_join: ["-", [{get_param: prefixe}, sg]]}
      rules:
        - {protocol: icmp, remote_ip_prefix: {get_param: admin_cidr}}
        - {protocol: tcp, port_range_min: 22, port_range_max: 22, remote_ip_prefix: {get_param: admin_cidr}}

  port:
    type: OS::Neutron::Port
    properties:
      network: {get_resource: reseau}
      fixed_ips: [{subnet: {get_resource: sous_reseau}}]
      security_groups: [{get_resource: pare_feu}]

  vm:
    type: OS::Nova::Server
    properties:
      name: {list_join: ["-", [{get_param: prefixe}, vm]]}
      image: {get_param: image}
      flavor: {get_param: gabarit}
      networks: [{port: {get_resource: port}}]

  ip_publique:
    type: OS::Neutron::FloatingIP
    depends_on: interface
    properties:
      floating_network: {get_param: reseau_externe}
      port_id: {get_resource: port}

outputs:
  ip_publique:
    description: Adresse a utiliser depuis le PC
    value: {get_attr: [ip_publique, floating_ip_address]}
  ip_privee:
    description: Adresse de la VM dans son reseau
    value: {get_attr: [vm, first_address]}
EOF
```

**Comment lire le modèle :**

| Section | Rôle |
|---|---|
| `heat_template_version` | La version du format |
| `parameters` | Les **réglages** de l’environnement, avec une valeur par défaut : préfixe des noms, plage d’adresses, image, taille de VM, réseau externe, réseau autorisé à se connecter |
| `resources` | Les **ressources** à créer. `get_resource` relie une ressource à une autre (le sous-réseau **dans** le réseau, le port **sur** le pare-feu…) ; `get_param` lit un paramètre ; `list_join` construit un nom (`lab-app-net`) |
| `depends_on: interface` | L’IP publique n’est créée qu’une fois le routeur relié au sous-réseau : sans cela, elle ne serait pas joignable |
| `outputs` | Ce que la pile **renvoie** une fois créée : ici les adresses de la VM |

Vérifier le modèle **avant** de l’exécuter :

```bash
openstack --os-cloud lab-demo orchestration template validate -t ~/lab-environnement.yaml -f yaml | head -8
```

**Ce que tu vois :**

```text
Description: Environnement applicatif de test - reseau, routeur, pare-feu, VM et IP
  publique
Parameters:
  admin_cidr:
    Default: 192.168.57.0/24
    Description: Reseau autorise en SSH et ping
    Label: admin_cidr
    NoEcho: 'false'
```

**Comment le lire :** Heat a compris le modèle et liste ses paramètres. Une erreur de syntaxe serait signalée ici, **sans rien créer**.

Créer l’environnement (une **pile**, *stack*, = l’ensemble des ressources créées à partir d’un modèle) dans le projet `demo` :

```bash
openstack --os-cloud lab-demo stack create lab-app -t ~/lab-environnement.yaml --wait
```

**Ce que tu vois** (1 min 38 s) :

```text
[lab-app]: CREATE_IN_PROGRESS  Stack CREATE started
[lab-app.reseau]: CREATE_IN_PROGRESS  state changed
[lab-app.routeur]: CREATE_IN_PROGRESS  state changed
[lab-app.pare_feu]: CREATE_IN_PROGRESS  state changed
[lab-app.reseau]: CREATE_COMPLETE  state changed
[lab-app.pare_feu]: CREATE_COMPLETE  state changed
[lab-app.sous_reseau]: CREATE_IN_PROGRESS  state changed
[lab-app.sous_reseau]: CREATE_COMPLETE  state changed
[lab-app.port]: CREATE_IN_PROGRESS  state changed
[lab-app.routeur]: CREATE_COMPLETE  state changed
[lab-app.interface]: CREATE_IN_PROGRESS  state changed
[lab-app.port]: CREATE_COMPLETE  state changed
[lab-app.vm]: CREATE_IN_PROGRESS  state changed
[lab-app.interface]: CREATE_COMPLETE  state changed
[lab-app.ip_publique]: CREATE_IN_PROGRESS  state changed
[lab-app.ip_publique]: CREATE_COMPLETE  state changed
[lab-app.vm]: CREATE_COMPLETE  state changed
[lab-app]: CREATE_COMPLETE  Stack CREATE completed successfully
```

(Heures retirées pour la lisibilité.)

**Comment le lire :** chaque ligne est un événement `[pile.ressource]: ÉTAT`. Heat **calcule l’ordre** à partir des liens du modèle : le réseau, le routeur et le pare-feu démarrent ensemble, car ils ne dépendent de rien ; le sous-réseau attend le réseau ; le port attend le sous-réseau et le pare-feu ; la VM attend le port ; l’IP publique attend l’interface du routeur. Huit ressources, aucune commande à enchaîner à la main.

Lire le résultat :

```bash
openstack --os-cloud lab-demo stack resource list lab-app -c resource_name -c resource_type -c resource_status
openstack --os-cloud lab-demo stack output show lab-app ip_publique -f value -c output_value
```

**Ce que tu vois :**

```text
+---------------+------------------------------+-----------------+
| resource_name | resource_type                | resource_status |
+---------------+------------------------------+-----------------+
| ip_publique   | OS::Neutron::FloatingIP      | CREATE_COMPLETE |
| interface     | OS::Neutron::RouterInterface | CREATE_COMPLETE |
| routeur       | OS::Neutron::Router          | CREATE_COMPLETE |
| vm            | OS::Nova::Server             | CREATE_COMPLETE |
| port          | OS::Neutron::Port            | CREATE_COMPLETE |
| pare_feu      | OS::Neutron::SecurityGroup   | CREATE_COMPLETE |
| sous_reseau   | OS::Neutron::Subnet          | CREATE_COMPLETE |
| reseau        | OS::Neutron::Net             | CREATE_COMPLETE |
+---------------+------------------------------+-----------------+
192.168.57.129
```

**Comment le lire :** les huit ressources du modèle, toutes créées ; puis la sortie `ip_publique` : l’adresse à donner à l’équipe.

### Étape 5 : faire évoluer l’environnement en changeant un paramètre

**Situation :** la sécurité demande que seul le poste de l’administrateur (`192.168.57.1`, l’adresse de Windows sur ce réseau) puisse joindre la VM, au lieu de tout le réseau `192.168.57.0/24`.

Avec Heat, on ne modifie pas le pare-feu à la main : on change **le paramètre**, et Heat applique la différence.

```bash
openstack --os-cloud lab-demo security group rule list lab-app-sg -c "IP Protocol" -c "Port Range" -c "IP Range" -c Direction | grep ingress
openstack --os-cloud lab-demo stack update lab-app --existing --parameter admin_cidr=192.168.57.1/32 --wait
openstack --os-cloud lab-demo security group rule list lab-app-sg -c "IP Protocol" -c "Port Range" -c "IP Range" -c Direction | grep ingress
```

**La commande, mot par mot :** `stack update lab-app` = mettre à jour la pile ; `--existing` = garder le même modèle et les autres paramètres ; `--parameter admin_cidr=…` = la seule valeur qui change.

**Ce que tu vois :**

```text
| icmp        | 192.168.57.0/24 |            | ingress   |
| tcp         | 192.168.57.0/24 | 22:22      | ingress   |

[lab-app]: UPDATE_IN_PROGRESS  Stack UPDATE started
[lab-app.pare_feu]: UPDATE_IN_PROGRESS  state changed
[lab-app.pare_feu]: UPDATE_COMPLETE  state changed
[lab-app]: UPDATE_COMPLETE  Stack UPDATE completed successfully

| tcp         | 192.168.57.1/32 | 22:22      | ingress   |
| icmp        | 192.168.57.1/32 |            | ingress   |
```

**Comment le lire :** avant, ping (`icmp`) et SSH (`tcp 22`) étaient autorisés depuis tout le réseau ; après, depuis la seule adresse `192.168.57.1`. Heat n’a touché **que** le pare-feu : la VM, son adresse et le réseau sont intacts.

**La preuve :** après le démarrage de la VM (voir démo 3, étape 3), depuis **Windows** :

```powershell
ping 192.168.57.129
```

```text
Réponse de 192.168.57.129 : octets=32 temps=7 ms TTL=63
```

Et depuis **Lab-Services** (`192.168.57.2`), une autre machine du même réseau :

```text
2 packets transmitted, 0 received, 100% packet loss
```

Le poste autorisé passe, l’autre machine est refusée.

ℹ Un ping lancé depuis Lab-Sunbeam passe aussi : ses paquets vers ce réseau sortent par le NAT de VirtualBox, donc par le PC, et arrivent avec l’adresse `192.168.57.1`.

### Étape 6 : supprimer l’environnement

```bash
openstack --os-cloud lab-demo stack delete lab-app --yes --wait
openstack --os-cloud lab-demo server list
openstack --os-cloud lab-demo floating ip list
openstack --os-cloud lab-demo router list -c Name
rm -f ~/lab-environnement.yaml
```

**Ce que tu vois** (1 min 25 s) : `Stack DELETE completed successfully`, puis aucune VM, **aucune IP flottante**, et seul le routeur `demo-router` d’origine.

**Comment le lire :** Heat a supprimé les huit ressources, **dans l’ordre inverse**, IP flottante comprise. Comparer avec la démo 3, où l’IP flottante restait réservée après la suppression de la VM. C’est l’avantage d’une infrastructure décrite par un modèle : **rien n’est oublié**.

### Étape 7 : retirer Heat

```bash
sunbeam disable orchestration
sunbeam list-features | grep orchestration
juju status -m openstack --color=false | grep -c -i heat
```

**Ce que tu vois** (6 min 17 s) :

```text
OpenStack orchestration application disabled.
│ orchestration          │         │
0
```

**Comment le lire :** Sunbeam ne considère plus Heat comme activé, et **0** composant Heat reste dans Juju.

### Étape 8 : vérifier le retour à l’état initial

C’est l’étape que l’on oublie, et c’est la plus importante. On reprend la photographie et on la compare à « avant » :

```bash
mkdir -p "$DOSSIER/retour"
sunbeam manifest generate -f "$DOSSIER/retour/manifest.yaml"
sunbeam list-features -f yaml > "$DOSSIER/retour/features.yaml"
sunbeam cluster list -f yaml > "$DOSSIER/retour/cluster.yaml"
openstack --os-cloud lab-admin catalog list -f value -c Name | sort > "$DOSSIER/retour/catalogue.txt"
openstack --os-cloud lab-admin domain list -f value -c Name | sort > "$DOSSIER/retour/domaines.txt"
chmod -R go-rwx "$DOSSIER"
diff -r "$DOSSIER/avant" "$DOSSIER/retour"
```

**Ce que tu vois :**

```text
diff -r …/avant/catalogue.txt …/retour/catalogue.txt
3a4,5
> heat
> heat-cfn
diff -r …/avant/domaines.txt …/retour/domaines.txt
2a3
> heat
```

**Comment le lire :** Heat est retiré (`features.yaml` est revenu identique), **mais** il reste des traces : les services `heat` et `heat-cfn` sont toujours **annoncés** dans le catalogue, alors qu’ils n’existent plus, et le domaine `heat` est toujours là. `sunbeam disable` retire le logiciel, mais **pas** ce qu’il avait enregistré dans Keystone.

Sans la photographie « avant », ces restes passeraient inaperçus. Les relever en détail :

```bash
export OS_CLOUD=lab-admin
openstack service list -c Name -c Type | grep -i -E "heat|orchestration|cloudformation"
openstack user list --domain service_domain -f value -c Name | grep -i heat
openstack role list -f value -c Name | grep -i heat
```

`export OS_CLOUD=lab-admin` évite de répéter `--os-cloud lab-admin` dans les commandes suivantes de la session.

**Ce que tu vois :**

```text
| heat-cfn  | cloudformation |
| heat      | orchestration  |
svc_heat-YTSJDN
heat_stack_user
```

| Reste | Risque |
|---|---|
| Services `heat`, `heat-cfn` | Le catalogue annonce un service qui n’existe plus : les outils des équipes croient Heat disponible, et leurs appels échouent |
| Domaine `heat` | Un domaine d’identité inutile |
| Compte `svc_heat-…` | **Un compte de service actif, avec un mot de passe, qui ne sert plus** : un accès à fermer |
| Rôle `heat_stack_user` | Un rôle inutile |

### Étape 9 : nettoyer, puis prouver

```bash
openstack service delete heat heat-cfn
for u in $(openstack user list --domain service_domain -f value -c Name | grep "^svc_heat"); do
  openstack user delete --domain service_domain "$u"
done
openstack role delete heat_stack_user
openstack domain set --disable heat
openstack domain delete heat
```

| Ligne | Rôle |
|---|---|
| `service delete` | Retire les deux services ; leurs adresses partent avec eux |
| Boucle `for` | Trouve et supprime le compte `svc_heat-…`, dont le suffixe change à chaque installation |
| `role delete` | Retire le rôle |
| `domain set --disable` puis `domain delete` | Keystone refuse de supprimer un domaine actif : on le désactive d’abord |

Puis on refait la photographie « retour » et la comparaison. Les commandes `openstack` n’ont plus besoin de `--os-cloud` : `OS_CLOUD=lab-admin` est toujours défini dans la session.

```bash
rm -rf "$DOSSIER/retour"
mkdir -p "$DOSSIER/retour"
sunbeam manifest generate -f "$DOSSIER/retour/manifest.yaml"
sunbeam list-features -f yaml > "$DOSSIER/retour/features.yaml"
sunbeam cluster list -f yaml > "$DOSSIER/retour/cluster.yaml"
openstack catalog list -f value -c Name | sort > "$DOSSIER/retour/catalogue.txt"
openstack domain list -f value -c Name | sort > "$DOSSIER/retour/domaines.txt"
chmod -R go-rwx "$DOSSIER"
diff -r "$DOSSIER/avant" "$DOSSIER/retour"
```

**Ce que tu vois :**

```text
diff -r …/avant/manifest.yaml …/retour/manifest.yaml
48c48
<       nameservers: 192.168.1.254,192.168.56.20
---
>       nameservers: 192.168.56.20,192.168.1.254
```

**Comment le lire :** catalogue, domaines, fonctionnalités et machines sont **identiques** à l’état d’avant. La seule différence est une ligne du manifeste : les **mêmes** serveurs DNS, dans un ordre différent. Ce n’est pas un changement de configuration, seulement la façon dont `manifest generate` les écrit. Savoir faire ce tri fait partie de la lecture d’un `diff` : on cherche ce qui change **réellement**.

✅ **Conclusion du dossier de changement :** le service a été ajouté, utilisé, retiré, et le cloud est **prouvé** revenu à son état initial.

### Si tu vois autre chose

| Ce que tu vois | Cause | Que faire |
|---|---|---|
| `sunbeam enable` dépasse 20 minutes | Le lab est lent, ou un composant est bloqué | Dans la seconde session, lire le message de `heat/0` ; démo 1 après la fin |
| `CREATE_FAILED` sur une ressource | Quota, nom déjà utilisé, image ou réseau introuvable | `openstack --os-cloud lab-demo stack event list lab-app` donne la raison |
| `public endpoint for orchestration service … not found` sur une commande `stack` | Heat n’est pas activé (ou a été retiré et nettoyé) | `sunbeam list-features` |
| `domain delete` refusé | Domaine encore actif | `openstack domain set --disable heat` d’abord |

---

## Après les démos : remettre le lab en état

Les démos 3 et 5 suppriment leurs ressources. Restent les fichiers des démos 2 et 4, qui contiennent des **mots de passe** :

```bash
rm -rf ~/acces ~/changements
rm -f ~/.config/openstack/clouds.yaml
```

En entreprise, on garde au contraire le dossier `~/changements/…`, rangé avec le reste du dossier de changement.

---

## Fiche réflexe

| Je veux… | Commande |
|---|---|
| Savoir si le cloud va bien | `sunbeam utils juju-login`, `sunbeam deployment list`, `sunbeam cluster list`, `sunbeam plans list` |
| Un verdict pour un script | `sunbeam cluster list -f yaml \| grep -E -q "blocked\|error\|waiting\|maintenance\|OFFLINE\|unknown" && echo ANOMALIE \|\| echo OK` |
| Les accès administrateur | `sunbeam openrc`, ou `sunbeam cloud-config -a -c NOM -u`, puis `chmod 600` |
| L’adresse d’Horizon | `sunbeam dashboard url` |
| Prouver que le cloud rend le service | `sunbeam launch --name NOM`, attendre `Cloud-init … finished`, ping et SSH, puis supprimer VM, **IP flottante** et clé |
| Photographier l’état avant un changement | `sunbeam manifest generate -f …`, `sunbeam list-features -f yaml`, `sunbeam cluster list -f yaml` + catalogue et domaines |
| Ajouter un service | `sunbeam enable NOM`, puis vérifier `list-features` et le catalogue |
| Retirer un service | `sunbeam disable NOM`, puis **comparer à l’état avant** et nettoyer Keystone |

## Ce que ce lab ne permet pas de montrer

Le lab n’a qu’**un seul nœud**. Les opérations suivantes sont courantes en entreprise mais n’ont pas été exécutées ; leur syntaxe est décrite dans `README.md`, § 8.2 :

- **ajouter un nœud** : `sunbeam cluster add`, puis `sunbeam cluster join` sur la nouvelle machine ;
- **passer en haute disponibilité** : `sunbeam cluster resize` ;
- **mettre à jour** les composants : `sunbeam cluster refresh`, précédé de la démo 4 et suivi des démos 1 et 3 ;
- **régler un proxy d’entreprise** : `sunbeam proxy set`.
