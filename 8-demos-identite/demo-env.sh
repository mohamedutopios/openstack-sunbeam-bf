# Environnement commun des démos identité (modules 8, 9 et 10).
# À sourcer dans Lab-Sunbeam, au début de chaque session SSH :
#   source ~/demos-identite/demo-env.sh
#
# Ce fichier :
#  - charge les identifiants de l'administrateur du cloud (~/admin-openrc) ;
#  - demande une fois le mot de passe commun des comptes de démonstration (DEMO_PW) ;
#  - définit trois fonctions :
#      en_tant_que : exécute une commande openstack au nom d'un autre compte, avec la portée voulue ;
#      jeton_de    : affiche le jeton (id) d'un autre compte, pour les appels curl ;
#      projet_id   : affiche l'identifiant d'un projet à partir de son nom et de son domaine.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "À sourcer dans bash : source ~/demos-identite/demo-env.sh"
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source ~/admin-openrc

if [ -z "${DEMO_PW:-}" ]; then
    read -r -s -p "Mot de passe commun des comptes de démonstration : " DEMO_PW
    echo
    export DEMO_PW
fi

# Variables qui désignent l'identité et la portée de la session admin.
# On les retire le temps d'une commande pour agir sous une autre identité,
# sans toucher à la session de l'administrateur.
_DEMO_VARS=(OS_PROJECT_NAME OS_PROJECT_ID OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
            OS_DOMAIN_NAME OS_DOMAIN_ID OS_USERNAME OS_USER_ID OS_USER_DOMAIN_NAME
            OS_USER_DOMAIN_ID OS_PASSWORD OS_SYSTEM_SCOPE OS_TOKEN OS_AUTH_TYPE OS_CLOUD)

# en_tant_que <utilisateur> <domaine-utilisateur> projet <projet> <domaine-projet> -- <commande>
# en_tant_que <utilisateur> <domaine-utilisateur> domaine <domaine> -- <commande>
# en_tant_que <utilisateur> <domaine-utilisateur> systeme -- <commande>
en_tant_que() {
    if [ $# -lt 4 ]; then
        echo "usage : en_tant_que USER DOMAINE_USER (projet P DOMAINE_P | domaine D | systeme) -- commande" >&2
        return 2
    fi
    local user=$1 udom=$2 portee=$3
    shift 3
    local -a scope=()
    case $portee in
        projet)  scope=(--os-project-name "$1" --os-project-domain-name "$2"); shift 2 ;;
        domaine) scope=(--os-domain-name "$1"); shift ;;
        systeme) scope=(--os-system-scope all) ;;
        *) echo "portée inconnue : $portee (projet, domaine ou systeme)" >&2; return 2 ;;
    esac
    [ "${1:-}" = "--" ] && shift
    local -a unset_args=()
    local v
    for v in "${_DEMO_VARS[@]}"; do unset_args+=(-u "$v"); done
    env "${unset_args[@]}" openstack --os-auth-url "$OS_AUTH_URL" --os-identity-api-version 3 \
        --os-username "$user" --os-user-domain-name "$udom" --os-password "$DEMO_PW" \
        "${scope[@]}" "$@"
}

# jeton_de <mêmes arguments que en_tant_que, sans commande>
jeton_de() {
    en_tant_que "$@" -- token issue -f value -c id
}

# projet_id <projet> <domaine>
projet_id() {
    openstack project show "$1" --domain "$2" -f value -c id
}

echo "Session de démo prête : admin chargé ; en_tant_que, jeton_de et projet_id disponibles."
