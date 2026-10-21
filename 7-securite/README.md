# Sécuriser un cloud Sunbeam : démos de la journée

Ce dossier accompagne la journée **sécurité** de la formation. Les supports théoriques sont `support/11-openstack-authentification-externe-mots-de-passe-v1.0.html` et `support/13-openstack-micro-segmentation-audit-v1.0.html` ; ici, on **fait**, pas à pas, sur le lab.

> **Statut : rejoué sur le lab le 18 octobre 2026**, démos 1 à 6, retours arrière compris. Chaque fichier précise ce qui n’a pas été joué : l’import de la CA dans Windows (démo 1), l’affichage dans le navigateur (démo 2), le second facteur de Keystone, impossible sur ce lab (démo 3), `regenerate-password` sur `admin` (démo 4). La centralisation des journaux (démo 6, 6.5) est jouée : elle prend 75 minutes et charge fortement le lab ; son retrait n’a pas été joué. Les sorties citées sont celles de ce jour : les identifiants et adresses changent d’une installation à l’autre.

## Objectifs de la journée

| Objectif | Démos |
|---|---|
| Fédération d’identité, durcissement selon le référentiel ANSSI | 1, 2, 3, 4 |
| Isolation réseau entre tenants | 5 |
| Centralisation des journaux | 6 |

## Le parcours, dans l’ordre où on le joue

Les démos sont numérotées dans l’**ordre où elles se jouent**, qui suit les dépendances techniques. Il diffère un peu de l’ordre du programme, où le chiffrement vient en quatrième position : la fédération SAML exige que l’adresse publique du cloud soit déjà en **HTTPS**, et la politique de mots de passe s’applique dans le Keycloak que la fédération vient de brancher.

| # | Fichier | Thème du programme | Dépend de | Durée indicative |
|---|---|---|---|---|
| 1 | [01-chiffrement-tls.md](01-chiffrement-tls.md) | Chiffrement des flux : constat, activation, certificats, sécurité par défaut et durcissement | — | 1 h 15 |
| 2 | [02-federation-keycloak.md](02-federation-keycloak.md) | Fédération d’identité : une autorité d’authentification externe (Keycloak) | 1 (HTTPS) | 1 h 30 |
| 3 | [03-mots-de-passe-anssi.md](03-mots-de-passe-anssi.md) | Politique de mots de passe ANSSI : complexité, expiration, verrouillage, impact sur les comptes de service | 2 (Keycloak branché, compte `alice`) | 1 h |
| 4 | [04-rotation-secrets.md](04-rotation-secrets.md) | Rotation des mots de passe de service et des clés de jetons | — | 45 min |
| 5 | [05-reseau-micro-segmentation.md](05-reseau-micro-segmentation.md) | Réseaux partagés et privés, isolation entre tenants, groupes de sécurité, micro-segmentation | — | 1 h 30 |
| 6 | [06-audit-tracabilite.md](06-audit-tracabilite.md) | Journalisation des services, corrélation, centralisation | — | 1 h 15 |

**Correspondance avec le programme :**

| Programme | Démo |
|---|---|
| Fédération d’identité : autorité d’authentification externe | 2 |
| Politique de mots de passe (référentiel ANSSI) | 3 |
| Rotation des secrets | 4 |
| Chiffrement des flux (TLS) | 1 |
| Réseau et micro-segmentation | 5 |
| Audit et traçabilité | 6 |

Pour présenter dans l’ordre du programme, on peut **commenter** le chiffrement en quatrième position, à condition de l’avoir **activé** avant la fédération (par exemple la veille, ou en début de journée).

## L’environnement

| Élément | Valeur sur le lab |
|---|---|
| Cloud | Lab-Sunbeam, `192.168.56.10` ; API publique `cloud.lab.test` (`192.168.56.201`), interne `internal.lab.test` (`.202`) |
| Autorité d’authentification | Keycloak 26.8.0 dans Lab-Services (`192.168.56.20`), `https://sso.lab.test:8443`, realm `lab` |
| Autorité de certification du lab | `ca.crt` à la racine du dépôt : « Sunbeam Lab Root CA », valable jusqu’en 2031, approuvée sur Windows par `Configurer-Lab-Sunbeam.ps1` |
| Réseau externe (IP flottantes) | `external-network`, `192.168.57.0/24` ; le PC Windows y a l’adresse `192.168.57.1` |
| Comptes OpenStack | `admin` (domaine `admin_domain`), `demo` (domaine `users`) |

## Avant la séance : un lab stable

Les démos créent des VM et modifient le cloud : elles demandent un lab **en bon état**. Constaté le 17 octobre : après une veille du PC, ou sans Lab-Services, le cloud répond de façon aléatoire (`503`, « Keystone service is temporarily unavailable »).

1. **Désactiver la veille du PC** pendant la journée (PowerShell, PC branché) :

   ```powershell
   powercfg /change standby-timeout-ac 0
   ```

2. **Démarrer Lab-Services, puis Lab-Sunbeam**, dans cet ordre : Lab-Services fournit le DNS du lab et Keycloak. Vérifier que Lab-Services répond vraiment, depuis Lab-Sunbeam :

   ```bash
   getent hosts sso.lab.test
   curl -s -o /dev/null -w "%{http_code}\n" -k https://sso.lab.test:8443/realms/lab
   ```

   Attendu : `192.168.56.20   sso.lab.test`, puis `200`. Constaté le 18 octobre : Lab-Services allumée mais **figée** (ping OK, SSH muet, `000` pour Keycloak). Sa console VirtualBox affichait en boucle `rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks`, signe d’un noyau bloqué. *Machine → Réinitialiser* n’a pas suffi (le noyau a continué) ; il a fallu **Machine → Fermer → Éteindre la machine**, puis **Démarrer**. Keycloak répond environ 3 minutes après le démarrage.
3. **Vérifier le cloud** dans Lab-Sunbeam (guide `3-sunbeam-cli/DEMOS-ENTREPRISE.md`, démo 1) :

   ```bash
   sunbeam utils juju-login
   sunbeam cluster list
   juju status -m openstack --format short | grep -v "workload:active"
   uptime
   ```

   Attendu : tous les rôles `active`, aucune ligne pour la deuxième commande, et une charge (`load average`) redescendue sous 10 environ. Après un redémarrage de Lab-Sunbeam, les routeurs MySQL (`*-mysql-router`) passent en `error` tant que `mysql/0` n’est pas `active` : attendre `mysql/0 … Primary`, puis `juju resolved -m openstack <unité>` pour chacun (constaté le 18 octobre, cloud sain 12 minutes après le démarrage).
4. **Prendre un instantané, VM éteinte** : les démos 1 et 2 modifient durablement le cloud, la démo 3 le realm Keycloak, et la démo 6 ajoute COS ; l’instantané garantit le retour arrière.

   - Lab-Sunbeam : `sudo shutdown -h now` dans la VM, attendre l’état *Éteinte* dans VirtualBox, **Machine → Prendre un instantané**, puis **Démarrer**. Constaté le 18 octobre : instantané en quelques secondes.
   - Lab-Services : même chose.

   ⚠ **Pas d’instantané VM allumée.** Essayé le 18 octobre sur Lab-Services : l’instantané « à chaud » est resté bloqué à 90 % pendant des heures (état `livesnapshotting`), sans jamais être enregistré, et la VM est restée coincée dans cet état. Un instantané à chaud copie la mémoire pendant que la VM continue d’écrire : sur un PC à court de mémoire, la copie ne rattrape jamais la VM.

## Ce que les tests du 18 octobre ont révélé

Ces points changent la façon de jouer les démos ; chacun est expliqué dans sa démo, avec la preuve (journal ou code lu) et le contournement.

| Démo | Constat | Conséquence |
|---|---|---|
| 1 | Un filtre `tcpdump` sur `192.168.56.201` ne voit rien depuis Lab-Sunbeam : Kubernetes (Cilium) remplace l’adresse avant l’envoi | Capturer sur le port (`tcp port 80`) |
| 1 | TLS s’arrête au répartiteur Traefik ; derrière, HTTP sur le réseau des pods | Limite à connaître, à couvrir sur un cloud à plusieurs nœuds |
| 1 | Après `sunbeam disable tls`, le cloud reste instable une dizaine de minutes | Attendre et vérifier avant de rendre le cloud |
| 2 | `sunbeam identity provider add generic saml2` échoue avec une CA privée (Sunbeam rev 1101) | Le fournisseur se déploie avec Juju |
| 2 | Le charm `keystone-saml-k8s` (rev 134) refuse la CA en base64 seule | Valeur « base64 puis PEM » |
| 2 | Le charm Keystone (rev 440) n’écrit `trusted_dashboard` que pour OpenID Connect | Pas de connexion SAML par Horizon : test direct sur Keystone |
| 2 | Désactiver l’utilisateur fantôme dans Keystone ne bloque pas une nouvelle connexion fédérée | Désactiver dans Keycloak, puis couper les jetons |
| 2 | Le retrait du fournisseur laisse le choix « Keycloak - Lab » dans Horizon | Recréer la relation `trusted-dashboard` et régénérer Horizon |
| 3 | Keystone n’accepte pas la méthode `totp` | Pas de second facteur pour les comptes locaux |
| 4 | Les mots de passe générés par les charms font 12 caractères | À signaler dans l’analyse de risque |
| 4 | Un identifiant d’application ne reçoit que les rôles nommés (`member` sans `reader` ne voit pas les réseaux du projet) | `--role member --role reader` |
| 5 | `openstack port list --long` n’a pas de colonne pour la sécurité de port | Audit par l’API de Neutron |
| 6 | Keystone ne nomme pas le compte visé par un échec `401` | Compter par adresse, ou par compte dans Keycloak |
| 6 | `observability embedded` active aussi la télémétrie, prend 75 minutes et pousse la charge jusqu’à 77 ; Loki ne reçoit pas les journaux de la machine (`nova-compute`) | L’activer avant la séance ; `journalctl` pour la machine |
| 2 | Le guide `Guide-Sunbeam-VirtualBox-Keycloak.md` (section 12) utilise `sunbeam identity provider add`, qui échoue sur ce lab | Suivre la démo 2, étape 4, plutôt que le guide |

## Conventions

| Repère | Signification |
|---|---|
| **À quoi ça sert** | Le but de l’étape, et ce qu’on en attend en entreprise |
| **La commande, mot par mot** | Le rôle de chaque morceau |
| ✅ **Attendu** | Le résultat observé sur le lab (la date est indiquée) |
| **Comment le lire** | L’interprétation |
| **Si tu vois autre chose** | Les écarts probables et la conduite à tenir |
| ⚠ **à vérifier** | Syntaxe ou comportement non confirmé : commande de vérification fournie |
| 🔁 **À adapter** | Valeur propre au lab à remplacer chez toi |

Les objets créés par les démos commencent par `lab-sec` : un nom facile à retrouver pour le nettoyage.
