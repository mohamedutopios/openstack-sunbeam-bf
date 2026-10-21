#!/usr/bin/env bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Lancer avec sudo : sudo bash $0" >&2
    exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ca_path=${1:-"$script_dir/ca.crt"}

# Valider le certificat avant toute modification.
if [ ! -f "$ca_path" ]; then
    echo "Certificat absent : $ca_path. Copier le ca.crt du formateur a cote du script." >&2
    exit 1
fi
if ! openssl x509 -in "$ca_path" -noout 2>/dev/null; then
    echo "Le fichier $ca_path n'est pas un certificat PEM valide." >&2
    exit 1
fi
if ! openssl x509 -in "$ca_path" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE"; then
    echo "Le certificat fourni ne correspond pas a une autorite CA." >&2
    exit 1
fi
if ! openssl x509 -in "$ca_path" -noout -checkend 0 >/dev/null; then
    echo "La CA est expiree. Verifier aussi la date du systeme." >&2
    exit 1
fi
echo "CA du lab : $(openssl x509 -in "$ca_path" -noout -subject | sed 's/^subject=//')"
echo "Empreinte : $(openssl x509 -in "$ca_path" -noout -fingerprint -sha1 | cut -d= -f2)"

declare -A entries=(
    [sso.lab.test]=192.168.56.20
    [cloud.lab.test]=192.168.56.201
    [internal.lab.test]=192.168.56.202
    [rgw.lab.test]=192.168.56.203
)
names=(sso.lab.test cloud.lab.test internal.lab.test rgw.lab.test)

# Reecrire /etc/hosts : retirer les noms du lab des lignes existantes, puis les ajouter.
hosts=/etc/hosts
tmp=$(mktemp)
awk -v names="${names[*]}" '
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) lab[list[i]] = 1 }
    {
        line = $0; comment = ""
        pos = index(line, "#")
        if (pos > 0) { comment = substr(line, pos); line = substr(line, 1, pos - 1) }
        count = split(line, tok, /[ \t]+/)
        start = (tok[1] == "") ? 2 : 1
        if (count - start + 1 < 2) { print $0; next }
        kept = ""; removed = 0
        for (i = start + 1; i <= count; i++) {
            if (tok[i] == "") continue
            if (tolower(tok[i]) in lab) { removed++ } else { kept = kept " " tok[i] }
        }
        if (removed == 0) { print $0 }
        else if (kept != "") { print tok[start] "\t" substr(kept, 2) (comment != "" ? " " comment : "") }
        else if (comment != "") { print comment }
    }' "$hosts" > "$tmp"
for name in "${names[@]}"; do
    printf '%s\t%s\n' "${entries[$name]}" "$name" >> "$tmp"
done
if ! cmp -s "$tmp" "$hosts"; then
    backup="$hosts.sunbeam-$(date +%Y%m%d-%H%M%S).bak"
    cp -p "$hosts" "$backup"
    cat "$tmp" > "$hosts"
    echo "Fichier hosts configure. Sauvegarde : $backup"
else
    echo "Fichier hosts deja configure."
fi
rm -f "$tmp"

# Approuver la CA pour le systeme (curl, openssl, outils en ligne de commande).
ca_dest=/usr/local/share/ca-certificates/sunbeam-lab-ca.crt
if ! cmp -s "$ca_path" "$ca_dest" 2>/dev/null; then
    install -m 0644 "$ca_path" "$ca_dest"
    update-ca-certificates >/dev/null
    echo "CA importee dans le magasin systeme."
else
    echo "CA deja presente."
fi

echo
echo "Verification de la resolution des noms :"
for name in "${names[@]}"; do
    resolved=$(getent ahostsv4 "$name" | awk 'NR==1 {print $1}')
    if [ "$resolved" = "${entries[$name]}" ]; then
        echo "OK : $name -> $resolved"
    else
        echo "AVERTISSEMENT : resolution inattendue pour $name : ${resolved:-aucune}"
    fi
done

echo
echo "Reseaux host-only de VirtualBox sur l'hote :"
for ip in 192.168.56.1 192.168.57.1; do
    iface=$(ip -br -4 addr | awk -v ip="$ip/24" '$0 ~ ip {print $1; exit}')
    if [ -n "$iface" ]; then
        echo "OK : $ip sur $iface"
    else
        echo "AVERTISSEMENT : aucune interface en $ip. Creer le reseau host-only (etape 4), puis demarrer une VM qui l'utilise."
    fi
done

echo
echo "Mise en veille de l'hote :"
if [ "$(systemctl is-enabled suspend.target 2>/dev/null)" = "masked" ]; then
    echo "OK : mise en veille desactivee."
else
    echo "AVERTISSEMENT : la mise en veille est possible ; elle fige les VM (etape 8.0)."
fi

echo
echo "Tests TCP (les VM doivent etre demarrees) :"
check_port() {
    if timeout 3 bash -c "</dev/tcp/$2/$3" 2>/dev/null; then
        echo "OK : $1, port $3 accessible."
    else
        echo "AVERTISSEMENT : $1 ($2:$3) inaccessible. $4"
    fi
}
check_port "Keycloak" 192.168.56.20 8443 "Verifier Lab-Services et ses cartes host-only."
check_port "Horizon HTTP" 192.168.56.201 80 "Attendre 10 a 15 min apres le demarrage de Lab-Sunbeam."
check_port "OpenStack HTTPS" 192.168.56.201 443 "Attendu tant qu'Horizon est en HTTP."

echo
echo "Configuration Ubuntu terminee. Les tests ci-dessus portent sur le reseau, pas sur le SSO."
echo "Importer aussi $ca_path dans le magasin de certificats du navigateur."
echo "Keycloak : https://sso.lab.test:8443/admin/"
echo "Horizon : http://cloud.lab.test/openstack-horizon"
