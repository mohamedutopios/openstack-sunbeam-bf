# La fédération Keycloak, en clair

> Résumé de la démo 2 (`02-federation-keycloak.md`), sans les commandes. Une page pour comprendre **ce qu’on fait et pourquoi**, avant de taper quoi que ce soit.

## Le problème qu’on résout

Aujourd’hui, pour entrer dans le cloud, il faut un compte **dans Keystone**, avec un mot de passe **stocké dans Keystone**. Chaque application de l’entreprise fait pareil. Résultat : un mot de passe par application, et quand quelqu’un part, il faut penser à le couper partout.

**Ce qu’on veut :** qu’`alice` entre dans le cloud avec son compte d’entreprise (Keycloak), que son mot de passe **ne soit jamais** dans OpenStack, et qu’un seul clic dans Keycloak la coupe de tout.

## L’idée en une image

| Dans la vraie vie | Dans la démo |
|---|---|
| L’**État** délivre les passeports et vérifie l’identité des gens | **Keycloak** : il connaît `alice`, vérifie son mot de passe |
| La **douane** ne connaît pas les gens ; elle vérifie le **tampon** du passeport, puis décide où la personne peut aller | **Keystone** : il vérifie la signature de Keycloak, puis donne les droits |
| Le **passeport** | L’**assertion SAML** : un document signé par Keycloak qui dit « c’est alice » |
| La **règle de la douane** : « un passeport de cet État donne accès à telle zone » | Le **mapping** : « une personne authentifiée par Keycloak entre dans tel groupe, donc tel projet » |

**À retenir :** Keycloak dit *qui*. Keystone dit *quoi*. La fédération déplace la vérification du mot de passe, **pas** les droits.

## Ce qu’il faut construire

Pour que ça marche, il faut que l’État et la douane **se fassent confiance dans les deux sens**, puis qu’on écrive la règle. C’est tout. Chaque étape de la démo construit une de ces trois choses.

```text
   Keystone ──── reconnaît ────► Keycloak      (étape 4)
   Keystone ◄─── reconnaît ───── Keycloak      (étape 5)
   Keystone : « un passeport = tel groupe = tels droits »   (étape 6)
```

## Les étapes, une par une

### 0 · Préparer le terrain

**Ce qu’on fait :** on passe le cloud en HTTPS, on vérifie que Keycloak tourne et que Keystone sait le joindre, on copie la CA du lab sur Lab-Sunbeam.

**Pourquoi :** le passeport d’`alice` va transiter par son navigateur. En HTTP, n’importe qui sur le réseau pourrait le copier et entrer à sa place. Et pour que Keystone et Keycloak se parlent en HTTPS, chacun doit connaître l’autorité qui a signé le certificat de l’autre : c’est le rôle des deux CA (celle du lab pour Keycloak, celle de Sunbeam pour le cloud).

### 1 · Créer `alice` dans Keycloak

**Ce qu’on fait :** on crée la personne, son mot de passe, et son équipe (le groupe `openstack-formation`), **dans Keycloak seulement**.

**Pourquoi :** c’est le principe même de la fédération : la personne n’existe que dans l’annuaire de l’entreprise. On ne la créera **jamais** dans Keystone. Le groupe servira à l’étape 9 pour dire « seule cette équipe entre dans le cloud ».

### 2 · Donner à Keystone une clé pour signer

**Ce qu’on fait :** on fabrique une clé privée et un certificat, et on les confie à Keystone.

**Pourquoi :** quand Keystone envoie `alice` vers Keycloak, il joint une *demande*. Si cette demande n’était pas signée, n’importe quel site pourrait en fabriquer une et récupérer le passeport d’`alice`. Keycloak ne répond qu’aux demandes signées par une clé qu’il connaît. Cette clé est créée **en premier** parce que Keycloak l’apprendra à l’étape 5.

### 3 · Récupérer la carte d’identité de Keycloak

**Ce qu’on fait :** on télécharge un fichier XML que Keycloak publie : ses **métadonnées**. Il contient son nom officiel, ses adresses, et sa clé de signature.

**Pourquoi :** c’est ce que la douane doit connaître pour reconnaître le tampon de l’État. Deux étapes s’en serviront : l’étape 4 (pour configurer Keystone) et l’étape 6 (pour n’accepter que les passeports de **ce** Keycloak).

### 4 · Keystone apprend à reconnaître Keycloak

**Ce qu’on fait :** on déploie, avec Juju, un petit charm qui donne à Keystone l’adresse des métadonnées de Keycloak et la CA pour aller les lire. On le relie à Keystone.

**Pourquoi :** c’est le **premier sens** de la confiance : la douane sait maintenant à quoi ressemble le tampon de l’État. En interne, Keystone configure son module SAML (Apache `mod_auth_mellon`). Quand le charm dit `Provider is ready`, Keystone publie à son tour **sa** carte d’identité.

*(Sunbeam a une commande pour ça, `sunbeam identity provider add`, mais sur ce lab elle ne sait pas prendre une CA privée. On fait donc avec Juju ce qu’elle aurait fait.)*

### 5 · Keycloak apprend à reconnaître Keystone

**Ce qu’on fait :** on télécharge la carte d’identité de Keystone (ses métadonnées), on la copie sur le PC, et on l’importe dans Keycloak comme un **client**. Puis on vérifie une dizaine de réglages que l’import ne met pas tous correctement.

**Pourquoi :** c’est le **second sens** de la confiance. Keycloak ne délivre un passeport qu’à un demandeur qu’il connaît (le nom `urn:saml2:keycloak`, et la clé de l’étape 2), et ne le renvoie qu’à une adresse qu’il connaît (l’adresse ACS de Keystone). Chaque réglage ferme une porte : la signature prouve que la demande vient de Keystone ; l’adresse de retour exacte empêche de détourner le passeport ; *Encrypt assertions* doit être **Off**, sinon Keystone reçoit un passeport chiffré qu’il ne peut pas lire.

À la fin de cette étape, la confiance est réciproque. Mais Keystone ne sait pas encore **quoi faire** d’un passeport.

### 6 · Écrire la règle de la douane

**Ce qu’on fait :** côté Keystone, on crée une **cible** (un domaine `keycloak`, un groupe `lab_members`, un projet `formation`, et le rôle `member` du groupe sur le projet) ; puis la **règle** : un fournisseur d’identité (« j’accepte les passeports de ce Keycloak »), un mapping (« toute personne qui arrive entre dans le groupe `lab_members` »), et un protocole qui relie les deux.

**Pourquoi :** la fédération ne donne **aucun droit**. Ce sont le groupe, le rôle et le projet, exactement comme dans les TP identité, qui décident. Le mapping ne fait qu’une chose : mettre la personne dans le bon groupe à chaque connexion. Et c’est un groupe, pas la personne, qui a le rôle : quand d’autres salariés arriveront, rien ne changera.

### 7 · Tester

**Ce qu’on fait :** `alice` se connecte (dans le navigateur, ou avec un script qui affiche chaque échange). Elle obtient un jeton, le transforme en jeton sur le projet `formation`, liste les réseaux (ça passe), essaie de lister les utilisateurs (refusé, `403`).

**Pourquoi :** c’est la preuve de tout : Keycloak a vérifié le mot de passe, Keystone a accepté le passeport, et `alice` a **exactement** les droits d’un `member`, pas plus. Le `403` n’est pas une erreur, c’est la démonstration du moindre privilège.

On remarque aussi que Keystone a créé un utilisateur « fantôme » avec un code (`G-…`) et **sans mot de passe** : c’est la trace d’`alice`, pour les affectations et l’audit, rien de plus.

*(On ne teste pas par Horizon : sur ce lab, le charm Keystone ne l’autorise pas pour SAML. On teste directement sur Keystone, ce qui prouve la même chose.)*

### 8 · Montrer le gain : un seul interrupteur

**Ce qu’on fait :** on désactive `alice` dans Keycloak. Elle ne peut plus se connecter. On révoque aussi son jeton en cours.

**Pourquoi :** c’est la raison d’être de la fédération. Un clic dans l’annuaire de l’entreprise, et la personne est coupée de toutes les applications fédérées. Le jeton déjà délivré reste valable une heure : d’où la révocation, en second temps, pour un départ urgent.

### 9 · Comme en entreprise : seule l’équipe entre

**Ce qu’on fait :** on demande à Keycloak d’écrire les groupes de la personne dans le passeport, et on ajoute une condition au mapping : « seulement si le passeport mentionne `openstack-formation` ».

**Pourquoi :** la règle de l’étape 6 fait entrer **tout** le monde connu de Keycloak. En entreprise, c’est tous les salariés. On filtre sur l’équipe. `alice` est dans l’équipe depuis l’étape 1 : elle passe toujours. Une personne hors équipe serait authentifiée par Keycloak mais refusée par Keystone : les deux métiers, bien séparés.

### 10 · Les scripts d’`alice`

**Ce qu’on fait :** on donne à `alice` un rôle direct sur le projet, puis elle crée un **identifiant d’application** (un identifiant + un secret, limité au projet, qui expire dans 30 jours). Un script s’en sert sans mot de passe ni navigateur.

**Pourquoi :** la connexion fédérée suppose un navigateur et une personne. Un script de nuit n’a ni l’un ni l’autre. L’identifiant d’application est la réponse d’OpenStack. Le rôle direct est nécessaire parce que le rôle venu du mapping n’est pas enregistré : il est recalculé à chaque connexion. Revers : ce rôle ne dépend plus de Keycloak ; au départ d’`alice`, il faut **aussi** le retirer.

### 11 · Un deuxième utilisateur arrive

**Ce qu’on fait :** on crée `bob` dans Keycloak, on le met dans l’équipe `openstack-formation`. Il se connecte. C’est tout.

**Pourquoi :** c’est la récompense. Avant sa connexion, Keystone ne le connaît pas ; après, il a un fantôme et les droits de son groupe, sans **aucune** commande OpenStack. L’arrivée d’une personne est devenue une action dans l’annuaire, comme son départ. Pour une autre équipe sur un autre projet, on ajoute une règle au mapping (groupe Keycloak → groupe Keystone) : toujours un groupe par équipe, jamais un rôle sur une personne.

## Ce qu’il faut retenir

1. **Deux métiers séparés** : Keycloak vérifie qui, Keystone décide quoi.
2. **Deux sens de confiance** : Keystone reconnaît Keycloak (4), Keycloak reconnaît Keystone (5). L’ordre des étapes vient de là : clé → carte d’identité de Keycloak → Keystone configuré → Keycloak configuré → règle.
3. **Aucun droit par la fédération** : c’est le groupe, le rôle et le projet qui décident, comme toujours.
4. **Un seul interrupteur** : désactiver dans Keycloak, puis couper les jetons en cours. Les identifiants d’application se traitent à part.
5. **Deux CA, deux certificats** : la CA du lab pour parler à Keycloak, celle de Sunbeam pour parler au cloud ; un certificat HTTPS pour le transport, un certificat SAML pour signer.

## Ce qui a coincé en vrai, et pourquoi (20 octobre 2026)

| Symptôme | Cause | Leçon |
|---|---|---|
| `keystone-sp.xml` introuvable | Le cloud était en HTTP : la démo 1 n’avait pas été jouée | Le TLS est un prérequis, pas une option. Il est maintenant inclus dans l’étape 0 |
| `sunbeam enable tls` très long, compteur `(1/3)`, `(2/3)` qui oscille | Normal : 14 minutes, tous les services redémarrent | Ne pas interrompre ; suivre avec `juju status` dans une autre session |
| `admin-openrc` vide après un `Ctrl+C` | `sunbeam openrc > fichier` écrase avant d’écrire | Écrire dans un fichier temporaire puis `mv` |
| Le script s’arrête à « Pas de formulaire » ; Keycloak dit `client_not_found` | Le client n’était pas importé dans Keycloak (étape 5 pas faite après le TLS) | Keycloak ne répond qu’à un demandeur qu’il connaît |
| Keystone répond `400` au passeport | *Encrypt assertions* à On dans Keycloak (l’import l’active) | Keystone n’a pas de clé pour déchiffrer ; Off |
| Les réglages ne sont pas là où le document le disait | Keycloak 26 a déplacé *Encrypt assertions* dans l’onglet *Keys* | Suivre les deux tableaux de 5b, onglet par onglet |
