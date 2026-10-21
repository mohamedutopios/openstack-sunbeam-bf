#!/usr/bin/env bash
# Supprime tout ce que les démos identité ont créé : domaines orion, prestataires et demo-ephemere,
# avec leurs projets, utilisateurs, groupes, réseaux et groupes de sécurité.
# Ne touche jamais aux objets de Sunbeam (admin_domain, service_domain, users, Default).
# Usage : bash ~/demos-identite/nettoyage.sh [-y]
set -uo pipefail
source ~/admin-openrc

DOMAINES="orion prestataires demo-ephemere"

echo "Seront supprimés :"
for d in $DOMAINES; do
    openstack domain show "$d" >/dev/null 2>&1 || continue
    echo " - domaine $d : $(openstack project list --domain "$d" -f value -c Name | wc -l) projet(s)," \
         "$(openstack user list --domain "$d" -f value -c Name | wc -l) utilisateur(s)," \
         "$(openstack group list --domain "$d" -f value -c Name | wc -l) groupe(s)"
done
echo "Les instances et volumes éventuels sont à supprimer à la main avant : ils survivraient à leur projet."

if [ "${1:-}" != "-y" ]; then
    read -r -p "Confirmer la suppression ? (oui/non) " r
    [ "$r" = "oui" ] || { echo "Abandon."; exit 0; }
fi

for d in $DOMAINES; do
    openstack domain show "$d" >/dev/null 2>&1 || continue
    # 1. Ressources réseau des projets : Keystone ne les supprime pas avec le projet.
    for p in $(openstack project list --domain "$d" -f value -c ID); do
        # Les règles RBAC de partage disparaissent avec le réseau qu'elles partagent.
        for s in $(openstack subnet list --project "$p" -f value -c ID); do
            openstack subnet delete "$s" && echo "sous-réseau $s supprimé"
        done
        for n in $(openstack network list --project "$p" -f value -c ID); do
            openstack network delete "$n" && echo "réseau $n supprimé"
        done
        for sg in $(openstack security group list --project "$p" -f value -c ID); do
            openstack security group delete "$sg" && echo "groupe de sécurité $sg supprimé"
        done
    done
    # 2. Projets : les feuilles d'abord (un parent ne se supprime pas avant ses enfants).
    for _ in 1 2 3 4 5; do
        reste=$(openstack project list --domain "$d" -f value -c ID)
        [ -z "$reste" ] && break
        for p in $reste; do
            if [ -z "$(openstack project list --parent "$p" -f value -c ID 2>/dev/null)" ]; then
                openstack project delete "$p" && echo "projet $p supprimé"
            fi
        done
    done
    # 3. Utilisateurs, groupes, puis le domaine (désactivé d'abord : Keystone l'exige).
    for u in $(openstack user list --domain "$d" -f value -c ID); do
        openstack user delete "$u" && echo "utilisateur $u supprimé"
    done
    for g in $(openstack group list --domain "$d" -f value -c ID); do
        openstack group delete "$g" && echo "groupe $g supprimé"
    done
    openstack domain set --disable "$d" && openstack domain delete "$d" && echo "domaine $d supprimé"
done

echo "Nettoyage terminé. Domaines restants : $(openstack domain list -f value -c Name | tr '\n' ' ')"
