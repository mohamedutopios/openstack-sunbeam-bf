#!/usr/bin/env bash
# Supprime tout ce que les TP identite ont cree : domaines acme et partenaire (avec leurs projets,
# utilisateurs et groupes), roles et projets prefixes lab-. Ne touche jamais aux objets de Sunbeam.
# Usage : bash ~/labs-iam/nettoyage.sh [-y]
set -uo pipefail
source ~/admin-openrc

PROTECTED_DOMAINS="admin_domain service_domain users Default default"
DOMAINS="acme partenaire $(openstack domain list -f value -c Name | grep -E '^lab-' | tr '\n' ' ')"
CUSTOM_ROLES=$(openstack role list -f value -c Name | grep -E '^(lab-|acme-)' || true)

echo "Seront supprimes :"
for d in $DOMAINS; do
    if openstack domain show "$d" >/dev/null 2>&1; then
        echo " - domaine $d : $(openstack project list --domain "$d" -f value -c Name | wc -l) projet(s)," \
             "$(openstack user list --domain "$d" -f value -c Name | wc -l) utilisateur(s)," \
             "$(openstack group list --domain "$d" -f value -c Name | wc -l) groupe(s)"
    fi
done
for r in $CUSTOM_ROLES; do echo " - role $r"; done
LAB_PROJECTS=$(openstack project list -f value -c Name | grep -E '^lab-' || true)
for p in $LAB_PROJECTS; do echo " - projet $p"; done
LAB_USERS=$(openstack user list --domain admin_domain -f value -c Name | grep -E '^lab-' || true)
for u in $LAB_USERS; do echo " - utilisateur $u (admin_domain)"; done
echo "Les reseaux et groupes de securite des projets sont supprimes avec eux."
echo "Supprime d'abord a la main les VM et les volumes eventuels : ils survivraient a leur projet."

if [ "${1:-}" != "-y" ]; then
    read -r -p "Confirmer la suppression ? (oui/non) " answer
    [ "$answer" = "oui" ] || { echo "Abandon."; exit 0; }
fi

for d in $DOMAINS; do
    case " $PROTECTED_DOMAINS " in *" $d "*) continue ;; esac
    openstack domain show "$d" >/dev/null 2>&1 || continue
    # Ressources reseau des projets : elles survivraient a leur projet (orphelines).
    # Constate le 18 octobre 2026 : sans cette boucle, acme-dev-net, acme-dev-web et les groupes
    # "default" des projets supprimes restaient dans Neutron.
    for p in $(openstack project list --domain "$d" -f value -c ID); do
        for n in $(openstack network list --project "$p" -f value -c ID); do
            openstack network delete "$n" && echo "reseau $n supprime"
        done
        for sg in $(openstack security group list --project "$p" -f value -c ID); do
            openstack security group delete "$sg" && echo "groupe de securite $sg supprime"
        done
    done
    # Identifiants d'application : supprimes par Keystone avec leur proprietaire (plus bas).
    # Ne pas utiliser "application credential list --user" : le client 7.5.0 echoue
    # ('function' object has no attribute 'list'), constate le 18 octobre 2026.
    # Projets : les feuilles d'abord (un projet parent ne se supprime pas avant ses enfants).
    for _ in 1 2 3 4 5; do
        remaining=$(openstack project list --domain "$d" -f value -c ID)
        [ -z "$remaining" ] && break
        for p in $remaining; do
            if [ -z "$(openstack project list --parent "$p" -f value -c ID 2>/dev/null)" ]; then
                name=$(openstack project show "$p" -f value -c name)
                openstack project delete "$p" && echo "projet $name supprime"
            fi
        done
    done
    for u in $(openstack user list --domain "$d" -f value -c ID); do
        openstack user delete "$u" && echo "utilisateur $u ($d) supprime"
    done
    for g in $(openstack group list --domain "$d" -f value -c ID); do
        openstack group delete "$g" && echo "groupe $g ($d) supprime"
    done
    for r in $(openstack role list --domain "$d" -f value -c ID 2>/dev/null); do
        openstack role delete "$r" && echo "role propre au domaine $r supprime"
    done
    openstack domain set --disable "$d" && openstack domain delete "$d" && echo "domaine $d supprime"
done

for r in $CUSTOM_ROLES; do
    openstack role delete "$r" && echo "role $r supprime"
done
for p in $LAB_PROJECTS; do
    # Deja supprime s'il appartenait a un domaine lab-* traite plus haut.
    openstack project show "$p" >/dev/null 2>&1 || continue
    openstack project delete "$p" && echo "projet $p supprime"
done
for u in $LAB_USERS; do
    openstack user delete "$u" --domain admin_domain && echo "utilisateur $u supprime"
done

echo "Nettoyage termine. Domaines restants : $(openstack domain list -f value -c Name | tr '\n' ' ')"
