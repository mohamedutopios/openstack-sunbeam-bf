# Démo 04 : les domaines, des espaces d'identité

**Module 9 · 15 min.**
**Crée :** domaines `orion` et `prestataires` ; `lucas@orion`, `lucas@prestataires`, `karim@prestataires` ; projet `socle` ; Karim `member` sur `socle`.

Un domaine est un espace de noms, une frontière d'administration et un point de raccordement d'annuaire. Il isole les **identités**, pas les ressources.

```bash
source ~/demos-identite/demo-env.sh
```

## 1. Créer les domaines

**Pourquoi.** Orion et l'intégrateur sont deux organisations : deux populations, deux responsables, peut-être deux annuaires.

```bash
openstack domain create orion --description "Orion : SI du groupe"
openstack domain create prestataires --description "Consultants de l'intégrateur"
openstack domain list -c Name -c Enabled
```

✅ Six domaines, tous actifs.

❓ Faut-il un domaine par environnement (prod, recette, dev) ? *Non : mêmes personnes, même annuaire. Les environnements se séparent par projets (démo 06).*

## 2. Deux Lucas, aucun conflit

```bash
openstack user create lucas --domain orion --password "$DEMO_PW"
openstack user create lucas --domain prestataires --password "$DEMO_PW"
openstack user create karim --domain prestataires --password "$DEMO_PW"
openstack user show lucas
openstack user show lucas --domain orion -c id -c domain_id
openstack user show lucas --domain prestataires -c id -c domain_id
```

✅ Les trois créations passent. ⛔ `No User found for lucas` sans domaine. ✅ Deux identifiants distincts avec `--domain`.

Même règle pour les projets :

```bash
openstack project create essai --domain orion
openstack project create essai --domain prestataires
openstack project create essai --domain orion
openstack project delete essai --domain orion; openstack project delete essai --domain prestataires
```

⛔ La troisième création : `… not permitted to have two projects with … the same name … in the same domain (HTTP 409)`.

**À dire.**
- Un nom n'est unique que **dans** son domaine. Toujours nom + domaine, ou l'identifiant (qui ne change jamais).
- Un compte ou un projet ne change jamais de domaine : on le recrée.

## 3. Ce qui reste commun à tous

```bash
openstack role list -c Name
openstack network list --external -c Name
openstack flavor list --public -c Name
```

✅ Les mêmes rôles, le même `external-network`, les mêmes gabarits pour tous les domaines.

**À dire.**
- Propre au domaine : comptes, groupes, projets, source d'identité. Commun : rôles, catalogue, gabarits, images publiques, réseau externe, hyperviseurs.
- Nova, Neutron et Cinder **ignorent les domaines** : ils ne voient que des projets. L'isolation des ressources, c'est le projet (démo 06).

## 4. Un consultant externe sur un projet d'Orion

**Pourquoi.** Karim doit travailler sur le projet commun d'Orion, mais son compte reste géré chez l'intégrateur.

```bash
openstack project create socle --domain orion --description "Services communs"
openstack role add --user karim --user-domain prestataires --project socle --project-domain orion member
openstack role assignment list --names --project socle --project-domain orion
en_tant_que karim prestataires projet socle orion -- token issue -c project_id
```

`--user-domain` : où chercher Karim. `--project-domain` : où chercher le projet.

✅ `member | karim@prestataires | socle@orion`, puis un jeton sur `socle`.

**À dire.**
- Une affectation relie un acteur et une cible de domaines différents : c'est le travail entre organisations.
- Ces affectations croisées sont les plus faciles à oublier : on les retrouvera dans la revue (démo 08).

❓ Karim quitte l'intégrateur : qui coupe son accès ? *L'intégrateur (désactiver le compte) ou Orion (retirer l'affectation). Les deux marchent.*
