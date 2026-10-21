# Démo 05 : qui administre un domaine

**Module 9 · 20 min.**
**Crée :** Lucas `manager` du domaine `orion`. Le domaine jetable `demo-ephemere` est créé puis supprimé.

La plateforme pose le cadre ; un gestionnaire devrait gérer le quotidien de son domaine sans pouvoir en sortir. Trois points : jamais `admin`, ce que `manager` vaut **ici**, comment suspendre et retirer un domaine.

```bash
source ~/demos-identite/demo-env.sh
```

## 1. Le piège du rôle `admin`

❓ Lucas reçoit `admin` sur le seul projet `socle`. Verra-t-il les comptes de l'intégrateur ?

```bash
openstack role add --user lucas --user-domain orion --project socle --project-domain orion admin
en_tant_que lucas orion projet socle orion -- user list --domain prestataires -c Name
en_tant_que lucas orion projet socle orion -- project list --domain admin_domain -c Name
openstack role remove --user lucas --user-domain orion --project socle --project-domain orion admin
```

✅ Les deux commandes de Lucas réussissent : il voit `karim`, `lucas` de l'intégrateur et le projet `admin` de la plateforme. On retire aussitôt le rôle.

**À dire.** `admin_required` ne regarde pas la cible (démo 03) : `admin` quelque part = `admin` partout. **`admin` ne se délègue jamais**, ni sur un projet ni sur un domaine.

## 2. Lucas gestionnaire du domaine

```bash
openstack role add --user lucas --user-domain orion --domain orion manager
en_tant_que lucas orion domaine orion -- token issue -c domain_id
```

✅ Un jeton de **domaine** (pas de projet).

**À dire.** `manager` sur le domaine, jeton de portée domaine : c'est le profil de délégation du support. Gérer n'est pas utiliser : il ne donne aucun accès aux instances des projets.

## 3. Tester la délégation

**Pourquoi.** Ne pas supposer : tester. Faire parier la salle à chaque ligne.

```bash
L() { en_tant_que lucas orion domaine orion -- "$@"; }
L user list --domain orion -c Name                                        # 1
L project create essai-lucas --domain orion                               # 2
L user create essai-u --domain orion --password "$DEMO_PW"                # 3
L role add --user lucas --user-domain orion --domain orion admin          # 4
L user list --domain prestataires                                         # 5
L domain create orion2                                                    # 6
L quota set "$(projet_id socle orion)" --instances 99                     # 7
```

| # | Tentative | Support | Ce lab |
|---|---|---|---|
| 1 | Lister son domaine | ✅ | ✅ |
| 2 | Créer un projet chez lui | ✅ | ⛔ `403 identity:create_project` |
| 3 | Créer un compte chez lui | ✅ | ⛔ `403 identity:create_user` |
| 4 | Se donner `admin` | ⛔ | ⛔ mais le client **n'affiche rien** |
| 5 | Lire un autre domaine | ⛔ | ⛔ le client plante (`'NoneType' object has no attribute 'id'`) |
| 6 | Créer un domaine | ⛔ | ⛔ `403 identity:create_domain` |
| 7 | Changer un quota | ⛔ | ⛔ `Programming error choosing an endpoint.` |

⚠ La ligne 4 est silencieuse : vérifier qu'elle a bien échoué.

```bash
openstack role assignment list --names --role admin | grep "@orion" || echo "Lucas n'est pas admin"
openstack project delete essai-lucas --domain orion 2>/dev/null; openstack user delete essai-u --domain orion 2>/dev/null; unset -f L
```

✅ `Lucas n'est pas admin`.

**À dire.**
- La cloison tient : Lucas ne sort pas de son domaine et ne fabrique pas d'administrateur.
- Mais il ne peut pas non plus créer : **ici, `manager` ne fait que lire**. La plateforme garde comptes, projets et affectations (c'est elle qui construit en démo 06).
- Un `role add` refusé ne dit rien : la vérité est dans `role assignment list`.

## 4. Suspendre un domaine

**Pourquoi.** Fin de contrat ou compromission chez l'intégrateur : couper tout le monde, tout de suite, sans rien détruire.

```bash
openstack domain set --disable prestataires
en_tant_que karim prestataires projet socle orion -- token issue
openstack domain set --enable prestataires
en_tant_que karim prestataires projet socle orion -- token issue -c expires
```

⛔ `HTTP 401` pendant la désactivation, même pour `socle` (projet d'Orion). ✅ Jeton de nouveau délivré après réactivation.

**À dire.** L'interrupteur d'urgence d'un locataire : immédiat, réversible, rien n'est supprimé.

## 5. Supprimer un domaine

```bash
openstack domain create demo-ephemere
openstack project create jetable --domain demo-ephemere
openstack domain delete demo-ephemere
openstack domain set --disable demo-ephemere
openstack domain delete demo-ephemere
```

⛔ `Cannot delete a domain that is enabled, please disable it first. (HTTP 403)`. ✅ Supprimé une fois désactivé.

**À dire.**
- Le verrou « désactiver d'abord » évite l'erreur de manipulation.
- Keystone efface comptes, projets et affectations, **pas** les instances, volumes et réseaux des projets : ils deviendraient orphelins. Ordre : désactiver, purger les ressources, supprimer.
