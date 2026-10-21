# Travaux pratiques : identité, cloisonnement et moindre privilège

Ces travaux pratiques accompagnent les modules 8 à 12 du support (`support/8-…` à `support/12-…`). Les supports expliquent ; ici, on **fait** : chaque TP enchaîne des scénarios reproductibles, avec les commandes, le résultat attendu, les questions à poser aux apprenants et les pièges.

> **Statut :** les **TP 1 à 5 ont été rejoués** sur le lab les 17 et 18 octobre 2026 (Keystone 2024.1 déployé par Sunbeam, client `openstack` 7.5.0). Les résultats indiqués sont ceux observés, et les commandes ont été corrigées là où le client ou les charms l’imposaient. Si une autre version change un résultat, note l’écart.

### Pièges du client et du lab relevés au rejeu

| Constat | Ce que font les TP |
|---|---|
| Un `role add` refusé n’affiche **rien** et rend le code 0 (Keystone journalise pourtant `ForbiddenAction`) | Vérifier chaque délégation avec `role assignment list`, ou appeler l’API avec `curl` pour voir le vrai `403` (TP 2, TP 4, TP 5) |
| `quota show` et `quota set` refusent `--domain` | Passer l’**identifiant** du projet (`openstack project show … -f value -c id`) (TP 3, TP 4, TP 5) |
| `implied role create` sur un rôle propre à un domaine envoie `PUT /roles/None/implies` (404) | Créer l’implication par l’API (TP 2) |
| `application credential list --user` plante (`'function' object has no attribute 'list'`) | Lister par l’API, ou depuis la session du propriétaire (TP 4) |
| Les rôles impliqués ne sont **pas** transmis aux identifiants d’application | Donner explicitement chaque rôle voulu à l’identifiant (TP 4) |
| Les charms ne règlent pas `service_type` dans `[keystone_authtoken]` | Les identifiants d’application à règles d’accès sont refusés (`401`) partout : démonstration remplacée par l’explication (TP 4, § 4.5.3) |
| Un jeton révoqué reste accepté par Neutron une trentaine de secondes (cache) | Attendre avant de constater le `401` (TP 1, § 1.4.6) |
| `user list` sans `--domain` ne liste que le domaine du jeton (`admin_domain`) | Toujours préciser `--domain` (TP 2, TP 5) |
| Supprimer un projet ne supprime ni ses réseaux ni ses groupes de sécurité | `nettoyage.sh` les supprime avant le projet ; les VM et volumes restent à supprimer à la main |

### Ce que le TP 1 a montré, et qui change les TP suivants

Les règles de Keystone sur ce lab (TP 1, § 1.6.2) n’appliquent pas le modèle Secure RBAC décrit dans le support :

| Constat | Conséquence pour les TP |
|---|---|
| `create_user`, `create_project` et `create_grant` exigent le rôle `admin` ; **aucune règle ne mentionne `manager`** | Un gestionnaire de domaine (`manager` sur le domaine) ne peut ni créer de comptes, ni créer de projets, ni donner de rôles. Il n’est en pratique qu’un **lecteur** de son domaine. Les TP 2, 3 et 5 font donc faire ces créations par la **plateforme** (`admin`), après avoir constaté le refus |
| `rule:admin_required` accepte un rôle `admin` **quelle que soit sa portée** | « Admin quelque part, admin partout » (TP 2, § 2.3) : donner `admin` à un client, même sur un seul projet, lui donne tout |
| `admin@admin_domain` n’a **aucun rôle système** | Pas de jeton système pour l’administrateur (`401`) ; les démonstrations de portée système passent par un compte dédié (TP 4, § 4.4) |
| Nova réserve `os-hypervisors:list` à l’administrateur (`rule:context_is_admin`) | Un lecteur système ne voit pas les hyperviseurs (TP 4, § 4.4) |

⚠ **Avant chaque séance :** désactiver la mise en veille du PC (`powercfg /change standby-timeout-ac 0`), démarrer **Lab-Services puis Lab-Sunbeam**, et vérifier que le cloud est stable. Sans Lab-Services, son DNS manque : Nova, Neutron et Cinder répondent `503 … The Keystone service is temporarily unavailable`. Après une veille, la VM se réveille avec une horloge décalée et une charge très élevée : les commandes échouent de façon aléatoire.

## Parcours

| Fichier | Thème | Module du support | Durée indicative |
|---|---|---|---|
| [01-keystone-en-profondeur.md](01-keystone-en-profondeur.md) | Entités, catalogue, jetons, sources d’identité, politiques | 8 | 2 h 30 |
| [02-domaines.md](02-domaines.md) | Espaces d’identité indépendants, administration globale ou déléguée | 9 | 2 h |
| [03-projets-hierarchie-quotas.md](03-projets-hierarchie-quotas.md) | Projets, hiérarchie, rôles hérités, quotas, modèles d’organisation | 10 | 2 h 30 |
| [04-roles-moindre-privilege.md](04-roles-moindre-privilege.md) | Rôles standards, Secure RBAC, rôles impliqués, comptes de service | 12 | 2 h 30 |
| [05-scenario-integre.md](05-scenario-integre.md) | Simulation complète : construire et auditer un SI cloisonné | 8 à 12 | 3 h |

Les TP se suivent : chacun réutilise ce que le précédent a créé. Le TP 5 peut aussi se jouer seul, comme évaluation.

## Le fil rouge : l’entreprise Acme

Une entreprise, **Acme**, confie son SI à la plateforme OpenStack. Elle travaille avec un **partenaire** externe, qui doit rester totalement séparé.

```text
Plateforme (équipe cloud)        → domaine admin_domain, projet admin   (déjà créés par Sunbeam)
│
├── Domaine acme                 → administré par Bruno (gestionnaire de domaine)
│   └── Projet acme-si           → racine de l'arbre d'Acme (ne contient pas de ressources)
│       ├── acme-prod            → production : Emma (exploitation)
│       ├── acme-recette         → recette
│       └── acme-dev             → développement : Chloé (développeuse)
│
└── Domaine partenaire           → un autre Bruno, sans aucun lien avec celui d'Acme
    └── Projet partenaire-app
```

| Personne | Compte | Domaine | Rôle visé | TP |
|---|---|---|---|---|
| Équipe plateforme | `admin` (existant) | `admin_domain` | admin | tous |
| Bruno | `bruno` | `acme` | manager du domaine `acme` (sur ce lab : lecture seule du domaine, voir plus haut) | 2, 4 |
| Chloé | `chloe` | `acme` | member de `acme-dev` | 3, 4 |
| Emma | `emma` | `acme` | member de `acme-prod`, reader sur tout Acme | 3, 4 |
| David | `david` | `acme` | reader (auditeur) sur tout Acme | 4 |
| Bruno du partenaire | `bruno` | `partenaire` | manager du domaine `partenaire` | 2 |
| Sauvegarde | identifiant d’application de `emma` | — | reader limité | 4 |

## Où taper les commandes

Toutes les commandes se lancent **dans Lab-Sunbeam** :

```powershell
ssh vagrant@192.168.56.10
```

Copie d’abord ce dossier depuis Windows (PowerShell, dans le dossier du dépôt) :

```powershell
scp -r .\6-labs-iam vagrant@192.168.56.10:~/labs-iam
```

## Préparer la session : `lab-env.sh`

Au début de **chaque** session SSH :

```bash
source ~/labs-iam/lab-env.sh
```

Ce fichier :

- charge les identifiants administrateur (`~/admin-openrc`) ;
- demande **une fois** le mot de passe commun des comptes de TP (`LAB_PW`), sans l’afficher ;
- définit la fonction **`os_as`**, qui exécute une commande `openstack` **en tant qu’un autre utilisateur**, avec la portée voulue, sans toucher à ta session administrateur.

```bash
os_as <utilisateur> <domaine-de-l-utilisateur> projet <projet> <domaine-du-projet> -- <commande openstack>
os_as <utilisateur> <domaine-de-l-utilisateur> domaine <domaine> -- <commande openstack>
os_as <utilisateur> <domaine-de-l-utilisateur> systeme -- <commande openstack>
```

Exemples :

```bash
os_as chloe acme projet acme-dev acme -- server list
os_as bruno acme domaine acme -- user list --domain acme
```

Sans `os_as`, les commandes s’exécutent en tant qu’`admin` sur le projet `admin`.

## Conventions

| Convention | Signification |
|---|---|
| ✅ **Attendu** | Résultat attendu si tout est conforme |
| ⛔ **Refus attendu** | La commande **doit** échouer : c’est la démonstration |
| ⚖ **dépend de Secure RBAC** | Le résultat change selon `enforce_scope` et `enforce_new_defaults` (TP 1, § 1.6) |
| ❓ **Question** | À poser aux apprenants avant de lancer la commande |
| ⚠ **Piège** | Erreur fréquente ou comportement contre-intuitif |

Les noms d’objets créés commencent par `acme` ou `partenaire`, ou par `lab-` : c’est ce qui permet au nettoyage de tout retrouver.

## Nettoyer

```bash
bash ~/labs-iam/nettoyage.sh
```

Le script supprime, dans l’ordre, les réseaux et groupes de sécurité des projets, les projets (avec les identifiants d’application de leurs utilisateurs), les utilisateurs, les groupes, les rôles et les domaines créés par les TP. Il affiche ce qu’il va supprimer et demande confirmation. Les objets de Sunbeam (`admin_domain`, `service_domain`, `users`, `Default`, projets `admin`, `demo`, `services`) ne sont jamais touchés.

**Avant un export des OVA**, lance le nettoyage puis supprime le dossier : `rm -rf ~/labs-iam`.
