# Démo 08 : revue finale et nettoyage

**Modules 8 à 10 · 10 min.** On audite ce qui a été construit, comme le ferait un auditeur, puis on retire tout.

```bash
source ~/demos-identite/demo-env.sh
```

## 1. Qui est administrateur, où que ce soit ?

```bash
openstack role assignment list --names --role admin -c User -c Group -c Project -c Domain
```

✅ Seulement les comptes de Sunbeam (`admin`, comptes de service) : aucun compte d'Orion ni de l'intégrateur.

**À dire.** C'est la première ligne de toute revue : sur ce cloud, `admin` n'importe où vaut le cloud entier (démo 05).

## 2. Qui gère chaque domaine ?

```bash
openstack role assignment list --names --role manager
openstack role assignment list --names --domain orion
```

✅ `lucas@orion` gestionnaire d'`orion`. Signal d'alerte en revue : un seul gestionnaire par domaine (le support en recommande deux, via un groupe).

## 3. Les accès entre domaines

```bash
for p in $(openstack project list --domain orion -f value -c ID); do
  openstack role assignment list --names --project "$p" -f value -c User | grep "@prestataires"
done | sort -u
```

✅ `karim@prestataires` : le seul compte externe ayant un rôle chez Orion.

**À dire.** Chaque affectation croisée doit avoir une raison écrite et une échéance. Ce sont celles qu'on oublie.

## 4. Ce que voit réellement l'auditrice

```bash
openstack role assignment list --names --effective --user nadia --user-domain orion -f value -c Role -c Project | sort
```

✅ `reader` sur tous les projets d'Orion, y compris `prod-api` créé après coup, et rien d'autre.

**À dire.** `--effective` répond à « pourquoi a-t-elle ce droit ? » : groupe `audit`, rôle hérité sur le domaine.

## 5. Capacité promise

```bash
for p in $(openstack project list --domain orion -f value -c Name); do
  printf "%-14s " "$p"
  openstack quota show "$(projet_id "$p" orion)" -f value | awk '$1=="instances"||$1=="cores"||$1=="floating-ips"{printf "%s=%s  ",$1,$2}'
  echo
done
```

✅ Les nœuds à 0, `dev-portail` réduit, `rec-portail` à 0 instance, `prod-paiement` sans adresse flottante ; les autres projets **aux défauts** (10 instances, 50 adresses flottantes).

**À dire.** Un projet resté aux défauts est un signal d'alerte : sa capacité n'a été décidée par personne.

## 6. Tout retirer

```bash
bash ~/demos-identite/nettoyage.sh
```

✅ Le script liste ce qu'il va supprimer, demande `oui`, puis retire réseaux, projets (feuilles d'abord), comptes, groupes et domaines. À la fin, il ne reste que `admin_domain`, `service_domain`, `users` et `Default`.

**À dire.** L'ordre du script est celui de la démo 05 : les ressources d'abord (Keystone ne les supprime pas), les projets par les feuilles, puis désactiver et supprimer les domaines.

## Ce qu'il faut retenir des trois modules

| Brique | Rôle | Commande de contrôle |
|---|---|---|
| Affectation | la seule source de droits : acteur + rôle + cible | `role assignment list --names --effective` |
| Jeton | une preuve datée, d'une portée, pour qui la détient | `token issue` |
| Politique | chaque service décide, règle par règle | `oslopolicy-policy-generator` |
| Domaine | isole les identités et leur administration | `domain list`, `--domain` partout |
| Projet | isole les ressources | `project show --children` |
| Rôle hérité | fait descendre un droit dans l'arbre | `--inherited`, puis `--effective` |
| Quota | protège la capacité commune | `quota show --usage <id>` |
