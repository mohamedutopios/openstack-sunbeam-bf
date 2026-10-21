# Lab OpenStack Sunbeam + Keycloak sur Windows 11 Pro

Guide du 9 octobre 2026 — montage pédagogique mono-nœud, sans haute disponibilité.

**But :** obtenir Horizon, Keystone, Nova, Neutron et le stockage, puis un SSO Keycloak et une instance accessible en SSH depuis Windows. Les fichiers de ce dossier accompagnent les étapes : ne lance pas toutes les commandes d'un seul bloc.

**Limite de validation :** les syntaxes Bash/Python et les formats YAML/JSON ont été contrôlés ; la génération de la CA et la signature des certificats ont été vérifiées sur des fichiers temporaires. Le Vagrantfile et les paramètres applicatifs ont été relus, mais ce montage complet n'a pas été exécuté sur ton PC. Les points de contrôle ci-dessous servent à détecter les différences de matériel, de box Vagrant et de révision Sunbeam. On ne continue pas après un contrôle en échec.

## 1. Architecture retenue et question Docker

Sur Windows, un conteneur Linux Keycloak nécessite un noyau Linux. Docker Desktop utilise habituellement WSL2 ou Hyper-V. VirtualBox peut fonctionner avec Hyper-V dans certains scénarios, mais cela ne garantit pas qu'il transmette à Ubuntu les extensions nécessaires pour que KVM lance les instances Nova.

**Pour ce guide, Docker Engine fonctionne dans une petite VM VirtualBox `services`, distincte de la VM `sunbeam`.** Les deux sont hébergées sur ton PC Windows. Le conteneur n'est donc pas directement dans Windows : c'est une adaptation volontaire de ton architecture. Elle permet de laisser Keycloak et OpenStack allumés ensemble, sans Docker Desktop ni WSL2 actifs.

Docker en lui-même n'est pas incompatible avec OpenStack. Le problème ici est l'empilement des hyperviseurs Windows → VirtualBox → KVM, auquel Docker Desktop ajouterait la dépendance Hyper-V/WSL2. Fermer la fenêtre Docker Desktop ne suffit pas forcément à retirer l'hyperviseur Windows.

| Élément | Ressources initiales | Rôle |
|---|---:|---|
| Windows 11 Pro | environ 9 Go restants sur 32 Go | navigateur, SSH, VirtualBox, Vagrant |
| VM `sunbeam`, Ubuntu 24.04 | 20 Go, 8 vCPU, disques virtuels 160 + 100 Go | control + compute + storage, Vault |
| VM `services`, Ubuntu 24.04 | 3 Go, 2 vCPU, disque virtuel 40 Go | Docker, PostgreSQL, Keycloak, DNS, passerelle |
| Instance Nova initiale | 1 vCPU, 1 Go | CirrOS pour vérifier le réseau |

La RAM d'une instance Nova est prise dans celle de `sunbeam`. 32 Go physiques restent serrés avec Vault/Ceph : ferme les applications inutiles. Si les services manquent de mémoire, il faudra réduire les usages ou passer à 64 Go ; ne considère pas ces allocations comme une garantie de capacité. Avec 64 Go, `LAB_RAM_MB=32768` est plus confortable.

Prévois environ 300 Go libres pour démarrer et garde de la marge. Les disques sont virtuels : **pas besoin d'un deuxième SSD physique**. Le disque Ceph de 100 Go doit être vide et ne doit pas être le disque système. Un SSD NVMe de 1 To convient mieux qu'un SSD de 512 Go déjà occupé.

Ce guide fixe le canal OpenStack `2024.1/stable` (Caracal), Ubuntu 24.04 et Keycloak `26.8.0`. Ce n'est pas une affirmation que Caracal est la dernière version. Les révisions du canal stable et la box peuvent évoluer : enregistre les versions effectivement installées. Ne change pas de canal OpenStack au milieu du guide.

## 2. Plan réseau

| Réseau/adresse | Fonction |
|---|---|
| NIC 1 NAT de chaque VM | téléchargement et connexion SSH Vagrant |
| Host-only `192.168.56.0/24` | management, API et Keycloak |
| Windows `192.168.56.1` | accès de l'hôte au management |
| Sunbeam `192.168.56.10` | administration de la VM Ubuntu |
| Services `192.168.56.20` | DNS + Keycloak HTTPS sur 8443 |
| `192.168.56.200–220` | plage des API OpenStack, sans DHCP VirtualBox |
| `cloud.lab.test` → `192.168.56.201` | API publiques et Horizon, adresse demandée par manifeste |
| `internal.lab.test` → `192.168.56.202` | API internes |
| `rgw.lab.test` → `192.168.56.203` | endpoint objet réservé |
| Host-only `192.168.57.0/24` | réseau provider/external de Neutron |
| Windows `192.168.57.1` | accès direct aux floating IP |
| Services `192.168.57.2` | passerelle NAT vers Internet |
| `192.168.57.100–199` | plage des floating IP et ports externes Neutron |
| `10.20.0.0/24` | réseau privé du projet demo |

Une floating IP est attachée via Neutron à une instance Nova. Depuis Windows, on se connecte à cette floating IP. Le mot « public » signifie ici externe à OpenStack, **pas accessible depuis Internet**. Les deux réseaux host-only ne sont pas pontés sur ton Wi-Fi.

La carte `provider0` de Sunbeam n'a pas d'adresse IP Ubuntu ; elle est confiée au réseau OpenStack. Le mode promiscuous est activé dans le Vagrantfile pour laisser circuler les adresses MAC/IP gérées derrière cette VM, ainsi que celles des API.

Avant de commencer, vérifie que ces réseaux ne chevauchent pas ceux de ton LAN, VPN, Docker ou d'autres VM. En cas de conflit, il faut changer les adresses de manière cohérente dans tous les fichiers.

## 3. Préparer Windows et le BIOS

1. BIOS/UEFI : active Intel VT-x/Virtualization Technology, ou AMD SVM/AMD-V. VT-d/IOMMU est utile mais ne remplace pas VT-x.
2. Gestionnaire des tâches → Performances → Processeur : « Virtualisation : activé ».
3. Fais les mises à jour Windows et redémarre.
4. Si BitLocker/chiffrement de l'appareil est actif, assure-toi d'avoir ta clé de récupération avant de changer les options de démarrage.

Pour conserver un démarrage normal avec WSL2/Docker Desktop, crée plutôt une entrée de démarrage dédiée au lab.

**PowerShell administrateur :**

```powershell
bcdedit /copy '{current}' /d 'Windows 11 - Lab VirtualBox'
```

La commande affiche un GUID. Remplace le GUID de l'exemple ci-dessous par celui qu'elle vient de retourner, accolades comprises :

```powershell
bcdedit /set '{GUID-RETOURNE}' hypervisorlaunchtype off
bcdedit /timeout 10
```

Redémarre et sélectionne « Windows 11 - Lab VirtualBox ». N'essaie pas de démarrer Docker Desktop ou WSL2 dans cette session. Ton entrée Windows habituelle reste disponible pour ces outils.

**Contrôle, PowerShell :**

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

On cherche `False`. Si le résultat reste `True`, examine `msinfo32` et les paramètres Sécurité Windows → Sécurité de l'appareil → Isolation du noyau. VBS, Credential Guard ou l'intégrité de la mémoire peuvent maintenir des dépendances à la virtualisation. Sur un PC personnel dédié, leur désactivation peut être nécessaire et réduit des protections Windows ; redémarre ensuite et contrôle à nouveau. Sur un PC administré par une entreprise, ne contourne pas sa politique : ce montage peut ne pas y convenir.

Même si ce contrôle est bon, le test KVM de l'étape 7 est décisif. Il faut une virtualisation **imbriquée**, pas seulement pouvoir démarrer Ubuntu.

## 4. Installer VirtualBox et Vagrant

**PowerShell administrateur**, si `winget` est disponible :

```powershell
winget install --exact --id Oracle.VirtualBox
winget install --exact --id Hashicorp.Vagrant
```

Sinon, télécharge les installateurs Windows depuis les sites officiels :

- https://www.virtualbox.org/wiki/Downloads
- https://developer.hashicorp.com/vagrant/install

Accepte l'installation des pilotes réseau VirtualBox. L'Extension Pack n'est pas nécessaire pour ce lab. Redémarre Windows si demandé, puis ouvre une nouvelle fenêtre PowerShell dans le démarrage « Lab VirtualBox ».

```powershell
vagrant --version
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' --version
```

Utilise un Vagrant récent compatible avec la version VirtualBox installée. La documentation actuelle du provider couvre notamment VirtualBox 7.1 et 7.2. Ne choisis pas une préversion. Si Vagrant indique que la gestion de disques est encore expérimentale dans ta version, définis `$env:VAGRANT_EXPERIMENTAL='disks'` dans la session PowerShell avant `vagrant validate`/`vagrant up`, ou utilise une version plus récente.

Dans VirtualBox → Outils/Fichier → Gestionnaire de réseau → Réseaux privés hôte (Host-only), crée ou configure **deux** réseaux :

- réseau A : IPv4 de l'hôte `192.168.56.1`, masque `255.255.255.0`, serveur DHCP **désactivé** ;
- réseau B : IPv4 de l'hôte `192.168.57.1`, même masque, DHCP **désactivé**.

Le nom des adaptateurs dépend de ta machine. Ce sont les sous-réseaux qui permettent à Vagrant de choisir les bons. Ne modifie pas un réseau déjà utilisé par d'autres VM sans vérifier son rôle. N'active pas le partage de connexion Internet Windows : la VM services fera le NAT.

## 5. Extraire les fichiers et démarrer la VM Docker

Extrais le ZIP dans `C:\Labs\lab-sunbeam` ; `Vagrantfile` doit se trouver directement dans ce dossier. Évite OneDrive et les dossiers synchronisés.

**PowerShell standard :**

```powershell
cd C:\Labs\lab-sunbeam
vagrant validate
vagrant up services --provider=virtualbox
vagrant box list
vagrant status
vagrant ssh services
```

Le provisionnement installe automatiquement Docker Engine depuis le dépôt Docker, le plugin Compose, dnsmasq et la passerelle. Il configure des règles NAT ciblées, compatibles avec la chaîne `DOCKER-USER`, sans désactiver globalement le filtrage Docker.

**Dans `services` :**

```bash
ip -br address
ip route
sudo systemctl is-active docker dnsmasq
sudo docker version
sudo docker compose version
getent hosts ubuntu.com
```

Tu dois trouver `mgmt0=192.168.56.20` et `provider0=192.168.57.2`. La route par défaut passe par la carte NAT, pas par `provider0`.

```bash
bash ~/lab/scripts/init-keycloak.sh
cd ~/lab/keycloak
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=80 keycloak
```

Si l'accès au socket Docker est refusé, quitte puis reconnecte `vagrant ssh services` pour prendre en compte le groupe Docker. Ce groupe donne des privilèges élevés dans cette VM de lab.

Attends que les logs indiquent la fin du démarrage Keycloak. Une erreur « port already allocated » se traite en vérifiant le service qui occupe 8443 dans cette VM, pas en changeant l'URL au hasard.

L'initialisation génère des mots de passe aléatoires, une CA locale et un certificat HTTPS. Elle refuse d'écraser les clés existantes. PostgreSQL conserve les données dans un volume Docker. Le realm `lab` est importé au premier démarrage ; modifier `realm.json` ne met pas automatiquement à jour un realm déjà présent.

Pour connaître le mot de passe de `kcadmin`, consulte localement :

```bash
cat ~/lab/keycloak/.env
```

Ne publie pas ce fichier. Le compte d'administration Keycloak n'est pas un administrateur OpenStack.

## 6. DNS et certificats dans Windows

**PowerShell administrateur :**

```powershell
notepad C:\Windows\System32\drivers\etc\hosts
```

Ajoute une seule fois :

```text
192.168.56.20 sso.lab.test
192.168.56.201 cloud.lab.test
192.168.56.202 internal.lab.test
192.168.56.203 rgw.lab.test
```

**Depuis le dossier du lab, PowerShell standard :**

```powershell
vagrant ssh services -c 'cat /home/vagrant/lab/ca.crt' | Set-Content -Encoding ascii .\ca.crt
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\CurrentUser\Root
Test-NetConnection 192.168.56.20 -Port 8443
```

N'importe que la CA que tu viens de créer pour ce lab. Elle permet à ton navigateur d'accepter les certificats qu'elle signe. Firefox peut avoir son propre magasin de certificats : importe la même CA dans ses autorités si nécessaire.

Ouvre **https://sso.lab.test:8443/admin/**. Connecte-toi avec `kcadmin` et son mot de passe. Sélectionne le realm **lab**, puis Users → Add user :

- username `alice` ;
- renseigne prénom, nom et email si le formulaire les demande ;
- crée l'utilisateur ; Credentials → Set password ; choisis un mot de passe et désactive Temporary pour simplifier le premier test.

L'inscription libre reste désactivée. Le mapping proposé plus loin donne accès au projet à **tous les utilisateurs authentifiés de ce realm dédié**. N'utilise donc pas ce realm pour des comptes qui ne doivent pas accéder au lab.

## 7. Démarrer Ubuntu Sunbeam et vérifier KVM

**PowerShell, dossier du lab :**

```powershell
# Pour un PC de 32 Go, les valeurs par défaut suffisent pour commencer.
# Sur un PC de 64 Go, on peut définir avant la création :
# $env:LAB_RAM_MB='32768'
vagrant up sunbeam --provider=virtualbox
vagrant ssh sunbeam
```

**Dans `sunbeam` :**

```bash
ip -br address
free -h
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt /
df -h /
grep -E -c '(vmx|svm)' /proc/cpuinfo
sudo kvm-ok
ls -l /dev/kvm
dig @192.168.56.20 sso.lab.test +short
getent hosts cloud.lab.test
```

Attendu : `mgmt0=192.168.56.10`, `provider0` sans IPv4, extensions CPU présentes, `/dev/kvm` disponible et KVM utilisable. **Si KVM manque, arrête ici.** Vérifie le BIOS, le démarrage Windows sans Hyper-V et le réglage VirtualBox « Activer VT-x/AMD-V imbriqué ». Ce n'est pas un problème Keystone.

Le disque système doit disposer d'environ 160 Go utilisables. L'agrandissement du disque virtuel n'implique pas toujours celui du système de fichiers de la box. Si `df -h /` est trop petit, inspecte `lsblk` avant de continuer.

Exemple **uniquement si** `lsblk` confirme que la racine utilise le volume LVM situé sur `/dev/sda3` et que `/dev/sda` est bien le disque système :

```bash
sudo apt-get install -y cloud-guest-utils lvm2
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -r -l +100%FREE "$(findmnt -n -o SOURCE /)"
```

Si la racine est une partition ext4 directe, agrandis **sa** partition avec `growpart`, puis **son** système de fichiers avec `resize2fs`. Les noms doivent venir de `lsblk`, pas être devinés. Ne partitionne et ne formate pas le disque virtuel Ceph de 100 Go.

Enregistre la version de box affichée par `vagrant box list`. Pour reconstruire ensuite avec la même box, définis `$env:LAB_BOX_VERSION='VERSION_OBSERVEE'` avant `vagrant up`.

## 8. Installer Sunbeam et préparer le nœud

**Dans `sunbeam`, en utilisateur `vagrant` :**

```bash
sudo snap install openstack --channel=2024.1/stable
snap list openstack
sunbeam --help
sunbeam prepare-node-script --bootstrap > ~/prepare-sunbeam.sh
less ~/prepare-sunbeam.sh
bash ~/prepare-sunbeam.sh
exit
```

Reconnecte depuis Windows : `vagrant ssh sunbeam`. Cela recharge les groupes, notamment `snap_daemon`. Le script de préparation adapte l'OS pour Sunbeam. Ne lance pas le bootstrap avec `sudo` : on garde l'utilisateur préparé.

```bash
id
sunbeam cluster bootstrap --help
```

Vérifie que l'option `--manifest` est proposée. Le fichier `~/lab/sunbeam.yaml` fixe le réseau de management, la base de données unique et les noms/IP d'ingress. S'il est rejeté par ta révision, ne supprime pas au hasard les paramètres : compare à la référence de manifeste du canal installé. Les pages de documentation versionnées peuvent elles aussi évoluer.

```bash
sunbeam cluster bootstrap --role control,compute,storage --manifest ~/lab/sunbeam.yaml
```

Pour les éventuelles questions restantes : management `192.168.56.0/24`, pas de proxy si tu n'en as pas, topologie base `single`, région `RegionOne`, plage API `192.168.56.200-192.168.56.220`. S'il demande des hostnames Traefik, utilise ceux du tableau réseau.

Lors de la sélection Ceph, choisis **uniquement le disque vide de 100 Go**, après comparaison avec `lsblk`. La sélection est destructive pour ce disque. Ne choisis jamais le disque 160 Go contenant `/`.

Laisse le bootstrap se terminer ; il télécharge beaucoup de composants. Contrôle ensuite :

```bash
sunbeam cluster list
juju status -m openstack
```

Ne poursuis pas si les composants essentiels restent `error`/`blocked` sans raison comprise. Un état `waiting` temporaire pendant les téléchargements est différent d'un échec durable.

## 9. Configurer Neutron et le projet de démonstration

```bash
sunbeam configure --openrc ~/demo-openrc
```

Réponds comme suit ; le libellé et l'ordre peuvent varier :

| Question | Valeur |
|---|---|
| Accès aux instances | **remote** : Windows est extérieur à la VM Sunbeam |
| Réseau externe | `192.168.57.0/24` |
| Passerelle | `192.168.57.2` |
| Plage d'allocation | `192.168.57.100-192.168.57.199` |
| Type | `flat` |
| Carte externe | `provider0` |
| Populate demo | oui |
| Utilisateur demo | `demo`, avec mot de passe enregistré |
| Réseau privé | `10.20.0.0/24` |
| DNS des instances | `192.168.57.2` |
| Ping et SSH | oui pour ce lab |

Le projet demo permettra le premier diagnostic Nova. Le projet SSO sera distinct.

Installe un client CLI isolé dans un venv :

```bash
python3 -m venv ~/venvs/openstack
source ~/venvs/openstack/bin/activate
pip install python-openstackclient
umask 077
sunbeam openrc > ~/admin-openrc
source ~/admin-openrc
openstack token issue
openstack compute service list
openstack network list --external
openstack image list
openstack flavor list
sunbeam dashboard url
```

Copie l'URL retournée pour Horizon, chemin compris. Ne suppose pas qu'il est simplement à la racine du domaine. À ce stade, il peut encore utiliser HTTP : on active HTTPS avant le SSO.

## 10. Vérifier le DNS à l'intérieur de Kubernetes

Les fichiers `hosts` de Windows et d'Ubuntu ne configurent pas automatiquement le DNS des pods. Il faut vérifier ce chemin avant la fédération.

Définis une fonction selon le snap effectivement installé :

```bash
if snap list k8s >/dev/null 2>&1; then
  kctl() { sudo k8s kubectl "$@"; }
else
  kctl() { sudo microk8s kubectl "$@"; }
fi
kctl get pods -A
kctl get svc -n openstack
kctl run lab-dns-check --image=busybox:1.36 --restart=Never --command -- sh -c \
  'nslookup sso.lab.test; nslookup cloud.lab.test'
kctl logs lab-dns-check
```

Attends que le pod ait téléchargé son image, puis relis ses logs. Les résultats doivent être `.20` et `.201`. Vérifie également dans les services que l'IP publique Traefik est bien celle demandée par le manifeste.

Si les noms ne sont pas résolus, inspecte la configuration DNS :

```bash
kctl -n kube-system get configmap
kctl -n kube-system get configmap coredns -o yaml > ~/coredns-before.yaml
kctl -n kube-system edit configmap coredns
```

Si la ConfigMap a un autre nom, utilise celui réellement listé. Dans `data.Corefile`, ajoute ce bloc **à côté** du bloc existant, sans remplacer la configuration Kubernetes :

```text
lab.test:53 {
    errors
    cache 30
    forward . 192.168.56.20
}
```

Le rechargement CoreDNS doit prendre effet ; sinon identifie son Deployment avec `kctl -n kube-system get deployment` et fais un `rollout restart deployment NOM_OBSERVE`. Supprime puis recrée le pod de test pour vérifier. Cette personnalisation DNS doit être recontrôlée après une mise à jour du cluster.

```bash
kctl delete pod lab-dns-check
```

## 11. Activer HTTPS avec Vault et notre CA

Dans `sunbeam`, récupère le **certificat public** de la CA (pas sa clé privée). Depuis Windows, tu peux lire `ca.crt` et copier son bloc PEM dans `~/ca.crt` avec `nano ~/ca.crt`. Il doit commencer par `-----BEGIN CERTIFICATE-----` et finir par `-----END CERTIFICATE-----`.

```bash
openssl x509 -in ~/ca.crt -noout -subject -fingerprint -sha256
sudo install -m 644 ~/ca.crt /usr/local/share/ca-certificates/sunbeam-lab.crt
sudo update-ca-certificates
curl --fail --cacert ~/ca.crt \
  https://sso.lab.test:8443/realms/lab/protocol/saml/descriptor -o ~/keycloak-idp.xml
```

Compare l'empreinte avec celle obtenue dans `services`. Le `curl` doit réussir avec vérification TLS, sans `-k`.

**Initialisation Vault, une seule fois :**

```bash
sunbeam enable vault
sunbeam vault init 1 1
```

Le choix 1 clé / seuil 1 simplifie un lab personnel ; ce n'est pas un modèle de sécurité de production. Conserve la clé d'unseal et le root token dans un gestionnaire de secrets. Ne relance pas `init` sur un Vault déjà initialisé.

Pour éviter de mettre les secrets dans l'historique :

```bash
read -rsp 'Unseal key: ' LAB_UNSEAL; echo
printf '%s\n' "$LAB_UNSEAL" | sunbeam vault unseal -
# Si la sortie demande de déverrouiller les autres unités, répète :
printf '%s\n' "$LAB_UNSEAL" | sunbeam vault unseal -
unset LAB_UNSEAL
read -rsp 'Vault root token: ' LAB_TOKEN; echo
printf '%s\n' "$LAB_TOKEN" | sunbeam vault authorize-charm -
unset LAB_TOKEN
sunbeam vault status
juju status -m openstack vault
```

Toutes les unités doivent être initialisées et déverrouillées. Active les certificats des endpoints publics :

```bash
sunbeam enable tls vault --ca "$(base64 -w0 ~/ca.crt)" --endpoint public
sunbeam tls vault list_outstanding_csrs --format yaml > ~/vault-csrs.yaml
less ~/vault-csrs.yaml
```

Le certificat à signer ici est celui d'une **CA intermédiaire Vault**, pas celui d'un serveur web. Extrais le bloc PEM de la CSR de `vault/0` dans `~/vault.csr`. Copie ce bloc, sans indentation YAML, dans un fichier `~/vault.csr` de la VM `services` (`nano ~/vault.csr`). Il ne contient pas de clé privée.

**Dans `services` :**

```bash
bash ~/lab/scripts/sign-vault.sh ~/vault.csr
```

Le script signe cette CSR avec la CA locale, comme CA intermédiaire avec `CA:TRUE`, puis affiche le certificat encodé en base64 sur une seule ligne. Copie cette ligne.

**Dans `sunbeam` :**

```bash
sunbeam tls vault unit_certs
```

Colle la ligne au prompt correspondant à la CSR signée. S'il y a plusieurs CSR, signe chacune et associe chaque certificat au bon identifiant ; ne réutilise pas un certificat pour une autre CSR. Vault peut ensuite émettre les certificats des endpoints publics.

```bash
sunbeam openrc > ~/admin-openrc
source ~/admin-openrc
openstack token issue
sunbeam dashboard url
```

L'URL d'authentification doit maintenant commencer par `https://cloud.lab.test/…`, et l'openrc doit contenir `OS_CACERT`. Contrôle le navigateur : Horizon doit s'ouvrir sans avertissement TLS. Si l'IP/FQDN réel diffère, corrige d'abord le manifeste, les enregistrements DNS et les certificats de manière cohérente. N'utilise pas `--insecure` comme solution permanente.

Le guide sécurise l'endpoint public utilisé pour le SSO. Il ne prétend pas chiffrer tout le trafic interne du lab. Les options `--endpoint internal`/`rgw` demanderaient d'étendre et de vérifier cette configuration.

## 12. Relier Keycloak à Keystone en SAML

On utilise SAML2, accepté par Keycloak et Sunbeam. L'OIDC générique de Sunbeam exige une CA déjà approuvée par le déploiement ; SAML permet ici de fournir la chaîne CA explicitement. N'édite pas directement les fichiers Keystone/Apache/Horizon dans les pods : Sunbeam et les charms les gèrent.

**Dans `sunbeam` :**

```bash
umask 077
mkdir -p ~/saml
openssl req -x509 -newkey rsa:3072 -nodes -days 365 \
  -keyout ~/saml/sp.key -out ~/saml/sp.crt -subj '/CN=Keystone SAML Lab'
sunbeam identity set-saml-x509 ~/saml/sp.crt ~/saml/sp.key
cat > ~/keycloak-saml.yaml <<YAML
metadata-url: https://sso.lab.test:8443/realms/lab/protocol/saml/descriptor
ca-chain: $(base64 -w0 ~/ca.crt)
label: 'Keycloak - Lab'
YAML
sunbeam identity provider add generic saml2 keycloak --config ~/keycloak-saml.yaml
sunbeam identity provider list
```

Le certificat SP ci-dessus sert à la signature SAML, distincte du certificat HTTPS. Les métadonnées du realm Keycloak sont disponibles même avant la création du client Keystone.

Télécharge ensuite les métadonnées de Keystone :

```bash
curl --fail --cacert "$OS_CACERT" \
 'https://cloud.lab.test/openstack-keystone/v3/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth/mellon/metadata' \
 -o ~/keystone-sp.xml
python3 ~/lab/scripts/extract-sp.py ~/keystone-sp.xml
```

Les valeurs affichées sont les références : **ne devine pas l'Entity ID ou l'ACS** à partir d'une URL de connexion Horizon.

Dans Keycloak, realm **lab**, Clients → Import client (ou Create client avec import), importe le fichier XML `keystone-sp.xml`. Pour le récupérer sur Windows :

```powershell
vagrant ssh sunbeam -c 'cat /home/vagrant/keystone-sp.xml' | Set-Content -Encoding utf8 .\keystone-sp.xml
```

Si ton interface ne propose pas l'import XML, crée un client de type **SAML**, puis recopie :

| Paramètre Keycloak | Valeur |
|---|---|
| Client ID | `entityID` exact du XML SP |
| Valid redirect URIs | URL ACS HTTP-POST exacte du XML, sans wildcard global |
| Master SAML Processing URL / ACS POST | cette même URL ACS |
| Name ID format | `persistent` |
| Force Name ID format | activé |
| Force POST binding | activé |
| Sign documents | activé |
| Sign assertions | activé |
| Signature algorithm | `RSA_SHA256` |
| Encrypt assertions | désactivé dans ce lab |
| Client signature required | activé ; certificat public SP importé dans Keys |

Après import, contrôle aussi ces réglages. La clé publique du client doit correspondre au certificat du XML SP/`sp.crt`, **pas** à la CA TLS. Pour la déconnexion, renseigne le SLO exact si présent dans le XML ; le test principal porte d'abord sur la connexion.

Le format persistent donne un identifiant stable, pas nécessairement le texte `alice`. C'est normal : Keystone utilise l'identité transmise par le protocole.

## 13. Créer les autorisations dans Keystone

L'ajout du fournisseur configure la fédération ; il ne crée pas à lui seul les droits sur un projet. **Dans `sunbeam`, avec les credentials admin :**

```bash
source ~/venvs/openstack/bin/activate
source ~/admin-openrc
openstack domain create keycloak
openstack group create --domain keycloak lab_members
openstack project create --domain keycloak formation
```

Extrais l'identifiant réel du fournisseur Keycloak depuis ses métadonnées :

```bash
REMOTE_ID=$(python3 -c 'import xml.etree.ElementTree as E; print(E.parse("/home/vagrant/keycloak-idp.xml").getroot().attrib["entityID"])')
openstack identity provider create --remote-id "$REMOTE_ID" --domain keycloak keycloak
openstack role add --group lab_members --group-domain keycloak \
  --project formation --project-domain keycloak member
openstack mapping create --rules ~/lab/mapping.json keycloak_saml
openstack federation protocol create --identity-provider keycloak --mapping keycloak_saml saml2
openstack federation protocol list --identity-provider keycloak
openstack role assignment list --group lab_members --group-domain keycloak --names
```

Pour conserver un contexte CLI propre lors d'un changement de projet, utilise de préférence un nouveau terminal. Les variables d'un précédent openrc (par exemple `OS_PROJECT_ID`, `OS_TOKEN`, `OS_CLOUD` ou `OS_AUTH_TYPE`) peuvent prendre le pas sur les credentials nouvellement chargés ; supprime les valeurs étrangères à la session si nécessaire et contrôle `openstack token issue`.

Ces commandes sont à lancer une fois ; les erreurs « already exists » ne justifient pas de supprimer tes projets. Le mapping transmet l'utilisateur authentifié au groupe Keystone `lab_members`, qui a le rôle `member` sur `formation`, sans rôle admin.

**Test SSO :** nouvelle fenêtre privée du navigateur → URL Horizon obtenue avec `sunbeam dashboard url` → méthode « Keycloak - Lab » → utilisateur `alice` du realm `lab` → retour dans Horizon → projet `formation`.

Le compte admin local Keystone reste utile pour réparer une fédération défaillante. L'authentification CLI par mot de passe Keycloak n'apparaît pas magiquement avec ce SSO navigateur. Pour automatiser ensuite avec un utilisateur fédéré, utilise un flux fédéré compatible ou des application credentials autorisés par la politique, pas le mot de passe admin Keycloak.

## 14. Premier test Nova depuis le projet demo

On vérifie d'abord Nova/Neutron avec le projet local demo, pour distinguer un problème réseau d'un problème SSO.

Dans Windows, génère une clé SSH distincte pour le lab :

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\sunbeam-lab"
Get-Content "$env:USERPROFILE\.ssh\sunbeam-lab.pub"
```

Choisis une passphrase. Copie **la clé publique uniquement** dans `~/windows-lab.pub` sur Sunbeam avec `nano`. Ne copie pas la clé privée sur les VM.

Le fichier demo-openrc a été produit avant TLS : recrée-le via les options d'export demo si ta révision les propose, ou actualise ses deux paramètres d'endpoint/CA à partir de l'openrc admin. Voici une façon de garder ses credentials demo tout en reprenant le endpoint courant :

```bash
source ~/admin-openrc
LAB_AUTH_URL="$OS_AUTH_URL"
LAB_CA="$OS_CACERT"
source ~/demo-openrc
export OS_AUTH_URL="$LAB_AUTH_URL"
export OS_CACERT="$LAB_CA"
openstack token issue
openstack keypair create --public-key ~/windows-lab.pub windows-lab
openstack network list
openstack image list
openstack flavor list
openstack security group list
```

Note les IDs du réseau **privé** demo, d'une image CirrOS active, d'un flavor léger (1 vCPU, 1 Go, disque compatible avec l'image) et du groupe de sécurité autorisant ICMP/SSH. Le nom des objets dépend de la révision : utilise les IDs affichés.

Si aucun flavor approprié n'existe, crée-le avec les credentials admin puis reviens aux credentials demo et aux paramètres TLS ci-dessus :

```bash
# Session admin uniquement :
openstack flavor create --public --vcpus 1 --ram 1024 --disk 5 lab.small
```

S'il n'y a aucune image légère, importe CirrOS avec les credentials admin :

```bash
curl -fL https://download.cirros-cloud.net/0.6.3/cirros-0.6.3-x86_64-disk.img -o ~/cirros.img
openstack image create cirros-lab --file ~/cirros.img --disk-format qcow2 --container-format bare --public
```

CirrOS sert uniquement au diagnostic, pas à héberger tes applications. Pour Ubuntu ensuite, utilise une image cloud officielle et un flavor disposant d'un disque assez grand ; le compte SSH sera `ubuntu` au lieu de `cirros`.

**Avec les credentials demo :** remplace les valeurs en majuscules avant exécution.

```bash
openstack server create lab-vm --image ID_IMAGE --flavor ID_FLAVOR \
  --network ID_RESEAU_PRIVE --security-group ID_GROUPE --key-name windows-lab
openstack server show lab-vm
openstack console log show lab-vm
openstack network list --external
openstack floating ip create ID_RESEAU_EXTERNE
```

Note l'adresse attribuée, par exemple `192.168.57.100` (ce n'est pas une adresse garantie) :

```bash
openstack server add floating ip lab-vm ADRESSE_ATTRIBUEE
openstack server show lab-vm -c status -c addresses
```

Une VM ACTIVE ne garantit pas que son réseau a fini de démarrer. Attends la fin du démarrage dans la console.

**Windows :**

```powershell
Test-NetConnection ADRESSE_ATTRIBUEE -Port 22
ssh -i "$env:USERPROFILE\.ssh\sunbeam-lab" cirros@ADRESSE_ATTRIBUEE
```

Tu passes alors directement de Windows à une VM Nova via Neutron. Il n'y a pas de redirection VirtualBox supplémentaire pour cette connexion.

## 15. Créer une instance depuis Horizon avec le compte SSO

Dans Horizon, connecté via Keycloak au projet `formation` :

1. Réseau → Réseaux : crée `formation-net`, sous-réseau `10.30.0.0/24`, passerelle `10.30.0.1`, DHCP activé, DNS `192.168.57.2`.
2. Réseau → Routeurs : crée `formation-router`, sélectionne le réseau externe existant, puis ajoute une interface sur le sous-réseau `formation-net`.
3. Compute → Paires de clés : importe `sunbeam-lab.pub` depuis Windows.
4. Réseau → Groupes de sécurité : crée `formation-ssh`. Ajoute TCP entrant port 22, source `192.168.57.1/32`, et ICMP entrant depuis cette même source. Garde les sorties autorisées pour DNS/Internet.
5. Compute → Instances → Lancer : image CirrOS/Ubuntu publique, flavor adapté, réseau `formation-net`, clé importée, groupe `formation-ssh`. Pour le premier test, choisis une racine sur image plutôt qu'un volume si l'interface propose les deux.
6. Réseau → IP flottantes : alloue une IP du réseau externe et associe-la au port de l'instance.
7. Depuis Windows, utilise la floating IP obtenue avec `ssh -i ... cirros@IP` ou `ubuntu@IP`.

Si l'utilisateur ne voit pas le réseau externe, l'administrateur peut autoriser précisément ce projet. Dans Sunbeam, avec l'openrc admin, récupère les IDs puis crée la règle RBAC si elle n'existe pas déjà :

```bash
source ~/admin-openrc
openstack network list --external
openstack network rbac list
PROJECT_ID=$(openstack project show --domain keycloak formation -f value -c id)
openstack network rbac create --type network --action access_as_external \
  --target-project "$PROJECT_ID" ID_RESEAU_EXTERNE
```

Remplace `ID_RESEAU_EXTERNE` par celui qui existe déjà. Ne crée pas un second réseau flat avec la même plage d'adresses.

À ce stade, tu as testé toute la chaîne : utilisateur Keycloak → Keystone → projet → création Nova → réseau Neutron → SSH Windows.

## 16. Option : une redirection localhost:2222

L'accès par floating IP suffit. Si tu préfères une adresse locale stable pour ton client SSH, Windows peut relayer un port TCP. Ce n'est pas une règle NAT VirtualBox.

**PowerShell administrateur**, remplace l'adresse par la floating IP réelle :

```powershell
Start-Service iphlpsvc
netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=2222 connectaddress=192.168.57.100 connectport=22
netsh interface portproxy show all
```

**PowerShell standard :**

```powershell
ssh -i "$env:USERPROFILE\.ssh\sunbeam-lab" -p 2222 cirros@127.0.0.1
```

Pour une seconde VM, utilise par exemple 2223 et sa propre floating IP. Cette règle est TCP, pas UDP. Elle n'expose que la boucle locale ; inutile d'ouvrir ce port à ton LAN. Si l'IP change, supprime puis recrée la règle :

```powershell
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=2222
```

Une règle NAT VirtualBox qui pointe seulement vers le port 22 de `sunbeam` ouvre le SSH de **la VM Ubuntu Sunbeam**, pas celui d'une instance Nova. Il faudrait un relais/DNAT supplémentaire ; le réseau host-only évite cette complication. Neutron possède aussi une fonctionnalité de port forwarding de floating IP, mais elle dépend de l'extension effectivement activée et n'est pas nécessaire ici.

## 17. Arrêt, redémarrage et conservation

Arrête d'abord les instances de travail via Horizon ou `openstack server stop NOM`. Puis, depuis Windows :

```powershell
vagrant halt sunbeam
vagrant halt services
```

Au redémarrage, démarre le DNS et Keycloak avant OpenStack :

```powershell
vagrant up services
vagrant up sunbeam
vagrant ssh sunbeam
```

Contrôle `sunbeam vault status`. Vault peut être scellé après redémarrage : utilise les clés conservées pour `sunbeam vault unseal -` jusqu'à ce que les unités soient déverrouillées. Ne refais ni `init` ni la création des CA. Attends ensuite la reprise des services avant de redémarrer les instances Nova.

Le volume PostgreSQL conserve Keycloak ; les disques Sunbeam conservent OpenStack. `docker compose down` conserve normalement les volumes nommés ; `docker compose down -v` les supprime. `vagrant destroy` détruit les VM et leurs données : ce n'est pas une commande d'arrêt.

Sauvegarde les données, mots de passe, clés Vault, CA et clés SAML de façon privée. Pour une copie des VM, préfère un arrêt propre des deux machines ; un snapshot à chaud n'est pas une sauvegarde cohérente de toute la plateforme.

Les certificats serveur/intermédiaire de ce lab expirent après un an : planifie leur renouvellement si tu le gardes. Les snaps et images peuvent évoluer ; conserve `snap list`, `juju status`, `vagrant box list` et `docker compose images` avec tes notes.

## 18. Dépannage ciblé

| Symptôme | Vérifier d'abord |
|---|---|
| VM Ubuntu fonctionne, mais `/dev/kvm` absent | Hyper-V/VBS encore actif, BIOS, option nested de VirtualBox |
| Bootstrap se bloque, pods Pending/OOMKilled | RAM réellement disponible, `free -h`, `df -h`, `kctl describe pod` |
| API `.201` inaccessible depuis Windows | réseau host-only `.56`, IP ingress réellement attribuée, promiscuous NIC 2 |
| Métadonnées Keycloak inaccessibles | `curl --cacert`, DNS du pod, port 8443 publié, logs Compose |
| `certificate verify failed` | CA, chaîne intermédiaire, SAN du certificat, horloges ; ne pas masquer avec `-k` |
| Keycloak `client not found` / redirection invalide | Entity ID et ACS exacts issus du XML SP |
| Signature SAML invalide | certificat SP importé, clés du realm, options signature, horloges |
| Connexion SSO réussie mais aucun projet | remote ID, mapping, noms IdP/protocole, rôle du groupe sur `formation` |
| Instance ERROR / No valid host | ressources Nova, service compute, KVM, taille flavor, disque/Ceph |
| Floating IP allouée, SSH impossible | instance démarrée, association au bon port, routeur, security group, NIC 3 promiscuous |
| SSH depuis Windows OK, Internet invité KO | gateway `.57.2`, `sysctl net.ipv4.ip_forward`, NAT et DOCKER-USER dans services |
| Panne après redémarrage | démarrer services d'abord, déverrouiller Vault, vérifier heure/DNS |
| Tout rame | pagination Windows et pression mémoire ; ne pas augmenter les vCPU comme remède à un manque de RAM |

Commandes utiles dans `services` :

```bash
cd ~/lab/keycloak
docker compose ps
docker compose logs --tail=100 keycloak
sudo iptables -t nat -S
sudo iptables -S DOCKER-USER
sysctl net.ipv4.ip_forward
```

Dans `sunbeam` :

```bash
juju status -m openstack
sunbeam vault status
openstack compute service list
openstack router list
openstack floating ip list
openstack server show lab-vm
```

Ces dernières commandes utilisent le projet de l'openrc chargé. Le SSO ne change pas le périmètre d'une session CLI déjà ouverte.

## Sources techniques

Consultées pour préparer le guide ; les scripts réseau, le plan d'adressage et l'assemblage constituent une proposition de lab, pas une architecture VirtualBox certifiée par Canonical.

- Canonical, [installation manuelle](https://canonical.com/openstack/docs/2024.1/how-to/install/install-canonical-openstack-using-the-manual-bare-metal-provider/).
- Canonical, [référence de manifeste](https://canonical.com/openstack/docs/2024.1/reference/manifest-file-reference/) et [questions interactives](https://canonical.com/openstack/docs/2024.1/reference/interactive-configuration-prompts/).
- Canonical, [Vault](https://canonical.com/openstack/docs/2024.1/how-to/features/vault/), [TLS Vault](https://canonical.com/openstack/docs/latest/how-to/features/managing-tls/tls-vault/) et [signature par CA externe](https://canonical.com/openstack/docs/latest/how-to/features/managing-tls/implement-tls-using-a-third-party-ca/).
- Canonical, [fournisseurs d'identité](https://canonical.com/openstack/docs/2024.1/how-to/misc/identity-provider-enablement/).
- OpenStack, [fédération Keystone](https://docs.openstack.org/keystone/latest/admin/federation/configure_federation.html).
- Docker, [installation Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
- Keycloak, [conteneurs](https://www.keycloak.org/server/containers), [administration et clients SAML](https://www.keycloak.org/docs/latest/server_admin/index.html), [version 26.8.0](https://www.keycloak.org/2026/10/keycloak-2680-released).
- HashiCorp, [provider VirtualBox](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox), [disques Vagrant](https://developer.hashicorp.com/vagrant/docs/disks/usage).
- Oracle, [manuel VirtualBox](https://www.virtualbox.org/manual/).
