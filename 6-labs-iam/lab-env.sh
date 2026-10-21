# Environnement commun des TP identite. A sourcer dans Lab-Sunbeam :
#   source ~/labs-iam/lab-env.sh
# - charge les identifiants admin (~/admin-openrc) ;
# - demande une fois le mot de passe commun des comptes de TP (LAB_PW) ;
# - definit os_as, pour executer une commande openstack en tant qu'un autre utilisateur.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ce fichier doit etre source dans bash : source ~/labs-iam/lab-env.sh"
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source ~/admin-openrc

if [ -z "${LAB_PW:-}" ]; then
    read -r -s -p "Mot de passe commun des comptes de TP (sera utilise a la creation) : " LAB_PW
    echo
    export LAB_PW
fi

# Variables d'identification a neutraliser pour agir en tant qu'un autre utilisateur.
_OS_IDENTITY_VARS=(OS_PROJECT_NAME OS_PROJECT_ID OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
                   OS_DOMAIN_NAME OS_DOMAIN_ID OS_USERNAME OS_USER_ID OS_USER_DOMAIN_NAME OS_USER_DOMAIN_ID
                   OS_PASSWORD OS_SYSTEM_SCOPE OS_TOKEN OS_AUTH_TYPE OS_CLOUD
                   OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET)

# os_as <utilisateur> <domaine-utilisateur> projet <projet> <domaine-projet> -- <commande openstack>
# os_as <utilisateur> <domaine-utilisateur> domaine <domaine> -- <commande openstack>
# os_as <utilisateur> <domaine-utilisateur> systeme -- <commande openstack>
os_as() {
    if [ $# -lt 4 ]; then
        echo "usage : os_as USER DOMAINE_USER (projet PROJET DOMAINE | domaine DOMAINE | systeme) -- commande" >&2
        return 2
    fi
    local user=$1 user_domain=$2 kind=$3
    shift 3
    local -a scope=()
    case $kind in
        projet)  scope=(--os-project-name "$1" --os-project-domain-name "$2"); shift 2 ;;
        domaine) scope=(--os-domain-name "$1"); shift ;;
        systeme) scope=(--os-system-scope all) ;;
        *) echo "portee inconnue : $kind (projet, domaine ou systeme)" >&2; return 2 ;;
    esac
    [ "${1:-}" = "--" ] && shift
    local -a unset_args=()
    local v
    for v in "${_OS_IDENTITY_VARS[@]}"; do unset_args+=(-u "$v"); done
    env "${unset_args[@]}" openstack --os-auth-url "$OS_AUTH_URL" --os-identity-api-version 3 \
        --os-username "$user" --os-user-domain-name "$user_domain" --os-password "$LAB_PW" \
        "${scope[@]}" "$@"
}

# os_appcred <id> <secret> -- <commande openstack> : agit avec un identifiant d'application.
os_appcred() {
    local id=$1 secret=$2
    shift 2
    [ "${1:-}" = "--" ] && shift
    local -a unset_args=()
    local v
    for v in "${_OS_IDENTITY_VARS[@]}"; do unset_args+=(-u "$v"); done
    env "${unset_args[@]}" openstack --os-auth-url "$OS_AUTH_URL" --os-identity-api-version 3 \
        --os-auth-type v3applicationcredential \
        --os-application-credential-id "$id" --os-application-credential-secret "$secret" "$@"
}

echo "Session TP prete : admin charge, os_as et os_appcred disponibles."
