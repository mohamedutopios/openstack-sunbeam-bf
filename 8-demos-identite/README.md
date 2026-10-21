# Démos identité : Keystone, domaines, projets et quotas

Huit démos courtes, jouées par le formateur, pour les modules 8, 9 et 10 du support (`0-support-v2/8-…`, `9-…`, `10-…`). Elles **se suivent** (chacune part de l'état laissé par la précédente) et sont **indépendantes des TP** de `6-labs-iam` : autres noms, autre fil rouge, nettoyage propre.

> **État :** pas encore rejouées de bout en bout. Les résultats attendus viennent de ce qui a été constaté sur ce même lab (Sunbeam, Keystone 2024.1, client `openstack` 7.5.0, octobre 2026). Ceux qui n'ont jamais été observés sont marqués *non vérifié*.

| # | Démo | Module | Message | Durée |
|---|---|---|---|---|
| 01 | [Cartographier Keystone](01-keystone-cartographie.md) | 8 | Un droit = acteur + rôle + cible ; le catalogue | 15 min |
| 02 | [Les jetons](02-jetons.md) | 8 | Portée, durée, porteur, révocation, clés | 20 min |
| 03 | [Politiques et refus](03-politiques-et-refus.md) | 8 | 401 ou 403 ; la règle qui décide | 15 min |
| 04 | [Domaines : espaces d'identité](04-domaines-espaces-identite.md) | 9 | Ce que le domaine isole, et ce qu'il n'isole pas | 15 min |
| 05 | [Domaines : qui administre](05-domaines-administration.md) | 9 | Jamais `admin` ; ce que vaut `manager` ici ; suspendre | 20 min |
| 06 | [Arbre de projets et rôles hérités](06-projets-hierarchie.md) | 10 | L'arbre fait descendre des droits, pas des ressources | 20 min |
| 07 | [Quotas](07-quotas.md) | 10 | Lire, fixer, voir un quota bloquer | 15 min |
| 08 | [Revue finale et nettoyage](08-revue-finale.md) | 8-10 | Auditer ce qu'on a construit | 10 min |

## Fil rouge : Orion

Un groupe financier fictif, **Orion**, ouvre son SI sur le cloud ; un **intégrateur** externe y envoie des consultants.

```text
admin_domain (Sunbeam)  → compte admin : la plateforme
orion                   → domaine du groupe
├── socle                 services communs
├── prod                  nœud production   → prod-portail, prod-paiement
└── horsprod              nœud hors-prod    → rec-portail, dev-portail
prestataires            → domaine de l'intégrateur
```

| Compte | Domaine | Rôle | Démo |
|---|---|---|---|
| `lucas` | `orion` | gestionnaire (`manager`) du domaine | 04, 05 |
| `lucas` | `prestataires` | homonyme, aucun rôle | 04 |
| `karim` | `prestataires` | `member` sur `socle` (autre domaine) | 04, 05 |
| `sarah` | `orion` | développeuse, groupe `equipe-portail` | 06, 07 |
| `marc` | `orion` | exploitant, groupe `exploitation` | 06 |
| `nadia` | `orion` | auditrice, groupe `audit` | 06 |
| `demo` | `users` | existant (Sunbeam) | 02, 03 |

## Préparer la séance

1. PC hôte sans mise en veille ; démarrer **Lab-Services puis Lab-Sunbeam** (sans Lab-Services, les services répondent `503`).
2. Copier le dossier (PowerShell, dans le dépôt) puis se connecter :

   ```powershell
   scp -r .\8-demos-identite vagrant@192.168.56.10:~/demos-identite
   ssh vagrant@192.168.56.10
   ```

3. Dans la VM, au début de **chaque** session :

   ```bash
   source ~/demos-identite/demo-env.sh
   ```

   Il charge `admin`, demande une fois le mot de passe commun des comptes de démo, et fournit :

   | Fonction | Exemple | Sert à |
   |---|---|---|
   | `en_tant_que` | `en_tant_que sarah orion projet dev-portail orion -- server list` | agir comme un autre compte, sans quitter la session admin |
   | `jeton_de` | `T=$(jeton_de lucas orion domaine orion)` | obtenir son jeton pour `curl` |
   | `projet_id` | `projet_id dev-portail orion` | l'identifiant d'un projet (les quotas n'acceptent pas `--domain`) |

## Forme des démos

Chaque étape : **Pourquoi** (la situation), les **commandes**, l'**attendu** (✅ réussite, ⛔ refus voulu), puis **À dire** (le message). ❓ signale une question à poser **avant** de lancer la commande.

## Ce lab diffère du support sur quatre points

| Sur ce lab | Effet |
|---|---|
| Anciennes règles de politique (`enforce_scope` et `enforce_new_defaults` à `false`) | `admin` n'importe où = `admin` partout (05) |
| Aucune règle Keystone ne mentionne `manager` | Un gestionnaire de domaine ne fait que lire ; la plateforme crée (05) |
| `admin` n'a aucun rôle système | Jeton système refusé, `401` (02) |
| Un `role add` refusé n'affiche rien, code `0` | Toujours vérifier avec `role assignment list` (05) |

## Nettoyer

```bash
bash ~/demos-identite/nettoyage.sh
```

Supprime réseaux, projets, comptes, groupes et les domaines `orion`, `prestataires`, `demo-ephemere`, après confirmation. Ne touche jamais aux domaines de Sunbeam.
