# Comprendre Juju dans notre lab Sunbeam

Fiche pratique — Juju 3.6, Sunbeam et OpenStack 2024.1.

Les commandes sont à saisir dans la **VM Ubuntu Sunbeam**, avec l’utilisateur `vagrant`, sauf indication contraire. Les sorties simplifiées sont des exemples : les noms et états réels se vérifient sur votre installation.

## 1. À quoi sert Juju ?

OpenStack comporte de nombreux services : Keystone, Neutron, Nova, MySQL, RabbitMQ… Ils doivent être configurés et fonctionner ensemble.

**Juju pilote leur administration à l’aide de programmes appelés charms.** Un charm sait comment configurer une application, traiter ses dépendances, gérer ses services et annoncer son état.

Exemple : Neutron a besoin de connaître sa base de données et Keystone. Le charm reçoit les informations nécessaires via Juju, prépare la configuration et gère le service.

| Outil | Rôle dans notre lab |
|---|---|
| **Sunbeam** | Orchestre la mise en place d’OpenStack et utilise notamment Juju |
| **Juju** | Gère les applications, leur configuration et leurs relations grâce aux charms |
| **Kubernetes** | Exécute les pods du plan de contrôle |
| **OpenStack** | Fournit les API pour créer des VM, réseaux et volumes |

Juju ne remplace donc ni Kubernetes ni OpenStack. Il administre les logiciels qui les composent ou les utilisent.

## 2. Les objets à reconnaître

| Terme | Signification concrète | Exemple du lab |
|---|---|---|
| **Client Juju** | Commande utilisée par l’administrateur pour envoyer des demandes | `juju status` |
| **Contrôleur** | Service central qui conserve l’état de gestion et coordonne les agents | `sunbeam-controller` |
| **Modèle** | Environnement logique regroupant applications, configuration et relations | `openstack` |
| **Application** | Logiciel déployé et administré par Juju | `neutron` |
| **Unité** | Une instance de cette application gérée par Juju | `neutron/0` |
| **Agent** | Composant qui reçoit les événements et exécute le charm | Agent de `neutron/0` |
| **Charm** | Programme d’administration propre à une application | `neutron-k8s` |
| **Workload** | Logiciel métier que le charm administre | Le serveur Neutron |
| **Relation** | Lien permettant aux charms d’échanger des informations de configuration | Accès de Neutron à sa base de données |

**Une unité n’est pas systématiquement une VM.** Dans le modèle Kubernetes du lab, `neutron/0` est associé au pod `neutron-0`. Les VM créées dans Nova sont encore d’autres objets.

## 3. Pourquoi deux commandes `status` ?

```bash
juju status -m openstack
juju status -m admin/openstack-machines
```

Décomposition :

- `juju` : le client qui contacte le contrôleur ;
- `status` : demande l’état connu des applications et unités ;
- `-m` : abréviation de `--model`, sélectionne le modèle ;
- `openstack` ou `admin/openstack-machines` : **nom du modèle à consulter**.

⚠ Le modèle des machines appartient à l’utilisateur Juju `admin`, alors que le client est connecté en tant que `sunbeam` (`juju whoami`). Sans le préfixe, `juju status -m openstack-machines` répond `model sunbeam-controller:sunbeam/openstack-machines not found`. La commande `juju models` affiche les noms exacts.

Ces commandes consultent l’état. Elles ne démarrent et ne modifient aucun service.

| Modèle | Ce qu’il contient dans notre lab | Pourquoi le consulter ? |
|---|---|---|
| **`openstack`** | Applications du plan de contrôle dans Kubernetes : Keystone, Neutron, Nova, Horizon, MySQL, RabbitMQ, Traefik… | Vérifier les services qui reçoivent et coordonnent les demandes au cloud |
| **`admin/openstack-machines`** | Applications déployées sur les machines : hyperviseur OpenStack, MicroCeph, Cinder Volume… | Vérifier les composants qui fournissent notamment le calcul et le stockage |

**Deux modèles ne signifient pas deux machines.** Dans notre lab, ils peuvent utiliser la même VM Ubuntu Sunbeam.

Exemple : Horizon et l’API Nova fonctionnent dans `openstack`, mais l’hyperviseur est bloqué dans `admin/openstack-machines`. On peut ouvrir le tableau de bord sans réussir à démarrer une VM.

### Lire le résultat

Extrait simplifié illustratif :

```text
App        Status   Scale  Charm          Message
neutron    active       1  neutron-k8s
traefik    waiting      1  traefik-k8s     Load balancer service has not yet obtained an external address.

Unit        Workload  Agent  Address
neutron/0*  active    idle   10.1.0.71
```

| Élément | Comment le lire |
|---|---|
| `App` | Nom de l’application déployée |
| `Status` / `Workload` | État déclaré par le charm pour l’application ou l’unité |
| `Scale: 1` | Une unité de cette application |
| `Charm: neutron-k8s` | Nom du programme chargé d’administrer Neutron |
| `neutron/0` | Première unité de l’application Neutron |
| `*` | Unité leader de l’application ; ce n’est pas nécessairement un rôle primaire dans le logiciel métier |
| `Agent: idle` | L’agent n’exécute pas actuellement de hook ; cela ne signifie pas que Neutron est arrêté |
| `Address` | Adresse associée à l’unité ; pas nécessairement l’adresse publique de l’API |
| `Message` | Explication du statut, à lire avant toute intervention |
| `Channel` / `Rev`, si affichés | Canal et révision du charm ; à distinguer de la version d’OpenStack |
| `Exposed: no`, si affiché | L’application n’est pas exposée via le mécanisme Juju correspondant ; elle peut rester accessible via Traefik |

Dans l’exemple, Traefik attend une IP externe. Ce message oriente vers le service Kubernetes `LoadBalancer`, pas vers une réinstallation d’OpenStack.

### Comprendre les états

| État | Signification | Réaction |
|---|---|---|
| `active` | Les conditions vérifiées par le charm sont satisfaites | Poursuivre avec un test fonctionnel |
| `waiting` | Une dépendance ou une condition manque encore | Lire le message et vérifier la dépendance |
| `maintenance` | Une opération est en cours | Suivre son évolution |
| `blocked` | Une condition nécessite une intervention | Corriger la configuration ou la dépendance indiquée |
| Agent `error` | L’exécution d’un hook a échoué | Lire les logs avant de retenter |

**`active` ne garantit pas un fonctionnement de bout en bout.** Dans notre lab, des services actifs ont renvoyé des erreurs 503 à cause d’un problème d’accès à Keystone.

### Pourquoi MicroCeph apparaît aussi dans `openstack` ?

```text
SAAS       Status  Store  URL
microceph  active  local  admin/openstack-machines.microceph
```

Cette ligne désigne une **offre consommée depuis un autre modèle**, pas un second déploiement de MicroCeph.

`admin/openstack-machines.microceph` indique le propriétaire `admin`, le modèle fournisseur `openstack-machines` et l’offre `microceph`. Pour voir les unités réelles, consulter `admin/openstack-machines` (`juju status -m admin/openstack-machines`).

## 4. À quoi ressemble un charm ?

Un charm est un paquet de code et de déclarations, généralement écrit en Python avec le framework **Ops**. Il est distribué sous forme d’archive `.charm`. L’image du conteneur Neutron est un élément distinct.

| Fichier habituel | À quoi sert-il ? |
|---|---|
| `charmcraft.yaml` | Décrit le projet et sa construction ; peut centraliser les déclarations suivantes |
| `metadata.yaml` | Décrit le charm, ses conteneurs et ses points de relation |
| `config.yaml` | Définit les options proposées par `juju config` |
| `actions.yaml` | Définit les opérations proposées par `juju run` |
| `src/charm.py` | Contient le code qui réagit aux événements |
| `lib/`, `templates/` | Bibliothèques et modèles de configuration éventuels |

Selon le projet, certains YAML sont générés au moment de construire le paquet. Le dépôt source et le charm installé peuvent donc différer.

### Exemple minimal expliqué

Extrait de `config.yaml` :

```yaml
options:
  message:
    type: string
    default: Bonjour
    description: Message à prendre en compte
```

Cela déclare une option nommée `message`, de type texte, avec la valeur initiale `Bonjour`.

Extrait pédagogique de `src/charm.py` :

```python
import ops

class BonjourCharm(ops.CharmBase):
    def __init__(self, *args):
        super().__init__(*args)
        # Quand la configuration doit être traitée, appeler cette méthode.
        self.framework.observe(self.on.config_changed, self._configurer)

    def _configurer(self, event):
        # Lire la valeur transmise par Juju.
        message = self.config["message"].strip()
        if not message:
            self.unit.status = ops.BlockedStatus("Message vide")
            return
        # Annoncer que notre contrôle a réussi.
        self.unit.status = ops.ActiveStatus("Configuration valide")

if __name__ == "__main__":
    ops.main(BonjourCharm)
```

Ce code ne lance aucun serveur : il illustre uniquement l’événement, la lecture de configuration et le statut. Il manque les éléments de construction pour en faire un charm déployable.

Dans un vrai charm Kubernetes, le code peut aussi écrire des fichiers dans le conteneur du workload et gérer ses processus avec **Pebble**, un gestionnaire de services.

### Que se passe-t-il après une commande de configuration ?

Exemple fictif, à ne pas lancer sur le lab tel quel :

```bash
juju config -m apprentissage bonjour message="Salut"
```

1. Le client demande au contrôleur de modifier l’option `message` de l’application `bonjour` du modèle `apprentissage`.
2. Juju enregistre la configuration et fait traiter un événement `config-changed` par l’agent.
3. Le charm lit la nouvelle valeur et exécute son code.
4. Le charm met à jour son statut, visible dans `juju status`.

La commande peut terminer avant que le charm ait fini son travail. Juju traite aussi d’autres événements : installation, changement d’une relation, disponibilité d’un conteneur…

## 5. Où trouver et voir les vrais charms ?

Les charms publiés sont consultables dans [Charmhub](https://charmhub.io/), par exemple [neutron-k8s](https://charmhub.io/neutron-k8s). La fiche du charm permet de retrouver son dépôt source. La branche courante du dépôt peut différer de la révision installée.

Pour observer le charm déployé dans notre lab :

```bash
juju ssh -m openstack --container charm neutron/0
```

**But :** ouvrir un shell dans le conteneur qui héberge l’opérateur de l’unité Neutron.

- `ssh` : ouvre une session via Juju ;
- `-m openstack` : sélectionne le modèle ;
- `--container charm` : choisit le conteneur de l’opérateur ;
- `neutron/0` : choisit l’unité.

Dans cette session :

```bash
ls -la /var/lib/juju/agents/unit-neutron-0/charm
```

**Attendu :** les fichiers du charm installé. Le chemin est courant pour cette unité ; si absent, le rechercher :

```bash
find /var/lib/juju/agents -maxdepth 5 -type f -name metadata.yaml 2>/dev/null
```

`find` cherche sous le répertoire des agents ; `-type f` limite aux fichiers ; `-name` filtre leur nom. `2>/dev/null` masque les erreurs de parcours.

Pour lire le début du code, si ce fichier est présent :

```bash
sed -n '1,120p' /var/lib/juju/agents/unit-neutron-0/charm/src/charm.py
exit
```

`sed` affiche les lignes 1 à 120 ; `exit` ferme la session. Le code peut déléguer une partie du travail à des bibliothèques.

**Observer sans modifier ces fichiers.** Les modifier directement ne constitue pas une configuration durable gérée par Sunbeam.

## 6. Les commandes utiles, expliquées

### A. Retrouver le contrôleur et les modèles

```bash
juju controllers
juju models
```

**But :** vérifier à quel environnement le client est connecté.

**Attendu :** une liste de contrôleurs, puis les modèles accessibles du contrôleur courant, dont `openstack` et `admin/openstack-machines`. Le contrôleur du lab s’appelle `sunbeam-controller`.

Si un modèle est introuvable, commencer ici : on peut utiliser le mauvais compte Linux ou le mauvais contrôleur.

### B. Suivre l’état pendant un démarrage

```bash
watch -n 5 juju status -m openstack
```

**But :** relancer l’affichage toutes les cinq secondes. `watch` est une commande Linux ; `-n 5` définit l’intervalle. Les options après `juju status` appartiennent à Juju.

**Attendu :** les mêmes tableaux que `status`, rafraîchis. Arrêter avec `Ctrl+C`. Ce suivi ne conserve pas d’historique.

### C. Voir les relations entre applications

```bash
juju status -m openstack --relations
```

**But :** afficher aussi les liens configurés entre applications. `--relations` ajoute ces informations au statut.

**Attendu :** des relations avec des extrémités fournisseur/consommateur et des noms d’interface. Par exemple, une relation de base de données permet l’échange des paramètres de connexion.

La relation ne transporte pas les requêtes SQL : le service se connecte ensuite à la base avec les informations reçues. Sa présence ne prouve pas que le réseau fonctionne.

### D. Examiner une application ou une unité

```bash
juju show-application -m openstack neutron
juju show-unit -m openstack neutron/0
```

**But :** obtenir plus de détails qu’avec le tableau global.

- `neutron` sélectionne l’application ;
- `neutron/0` sélectionne une unité précise.

**Attendu :** une sortie structurée décrivant l’objet, notamment ses informations de déploiement ou de relation. Utiliser ces commandes pour identifier précisément l’élément à diagnostiquer.

### E. Lire les options configurables

```bash
juju config -m openstack neutron
```

**But :** consulter les options que le charm Neutron expose à l’administrateur.

**Attendu :** noms, descriptions, types et valeurs des options. Ce n’est pas une copie complète de `neutron.conf` : une partie de ce fichier est produite à partir des relations.

Sans affectation, cette commande lit la configuration. Avec `option=valeur`, elle la modifie et peut déclencher une reconfiguration. Dans le lab, consulter les options avant toute modification et tenir compte du manifeste Sunbeam qui pilote le déploiement.

### F. Lire les logs du charm

```bash
juju debug-log -m openstack --include unit-neutron-0 --replay --no-tail
```

**But :** retrouver ce que l’agent et le charm ont fait, notamment les erreurs de hooks.

| Option | Effet |
|---|---|
| `--include unit-neutron-0` | Sélectionne l’entité de logs de l’unité `neutron/0` |
| `--replay` | Relit les logs conservés |
| `--no-tail` | Termine après la lecture, sans attendre les nouveaux messages |

**Attendu :** des lignes horodatées avec niveaux et messages. Chercher l’erreur et son contexte. Retirer `--no-tail` pour continuer à suivre les nouveaux logs ; arrêter avec `Ctrl+C`.

Les logs du charm ne sont pas tous les logs du serveur Neutron. Pour ces derniers :

```bash
sudo k8s kubectl logs -n openstack neutron-0 -c neutron-server --since=15m --tail=100
```

Ici, `-n` désigne le namespace Kubernetes, `-c` le conteneur, `--since` la période et `--tail` le maximum de lignes. **Ce n’est pas une commande Juju.**

### G. Consulter les changements de statut

```bash
juju show-status-log -m openstack neutron/0
```

**But :** voir comment le statut de l’unité a évolué.

**Attendu :** une chronologie de statuts et de messages, par exemple `waiting` puis `active`. Elle aide à dater le problème ; les détails techniques se recherchent ensuite dans les logs.

### H. Ouvrir le conteneur du service

```bash
juju ssh -m openstack --container neutron-server neutron/0
```

**But :** examiner l’environnement où tourne Neutron. Contrairement à `--container charm`, on entre ici dans le conteneur du workload.

Exemple de diagnostic, si `getent` est disponible :

```bash
getent hosts internal.lab.test
exit
```

**Attendu dans notre lab :** résolution vers `192.168.56.202`. Cela teste le DNS depuis le conteneur ; cela ne teste ni l’authentification ni la disponibilité complète de Keystone. Des outils comme `curl` peuvent être absents.

### I. Découvrir les actions disponibles

```bash
juju actions -m openstack keystone
```

**But :** lister les opérations prévues par le charm Keystone. Une action est une fonction d’administration, distincte d’une option de configuration.

**Attendu :** les noms et descriptions des actions exposées par la révision installée. Ne pas supposer qu’une action existe sans la vérifier.

Syntaxes à adapter, sans recopier les éléments entre chevrons :

```text
juju show-action -m openstack keystone <nom-action>
juju run -m openstack keystone/0 <nom-action>
```

`show-action` décrit l’action et ses paramètres. `run` l’exécute sur l’unité : **elle peut modifier le système ou retourner des informations sensibles**. Lire sa description avant de la lancer.

### J. Retenter un hook après correction

```bash
juju resolved -m openstack neutron/0
```

**À utiliser seulement si l’agent est en `error`, après avoir corrigé la cause.** Cette commande marque l’erreur comme résolue et retente normalement le hook en échec.

**Attendu :** l’agent reprend son traitement ; vérifier ensuite le statut et les logs. Si la cause persiste, l’erreur réapparaît.

Ce n’est pas une commande de redémarrage et elle ne corrige pas automatiquement un statut `blocked`. L’option `--no-retry` évite la nouvelle tentative ; elle n’est pas à ajouter par défaut.

## 7. Routine courte après démarrage des OVA

| Étape | Commande ou test | Ce qu’on vérifie |
|---|---|---|
| 1 | `juju models` | Le client accède aux bons modèles |
| 2 | `juju status -m openstack` | État du plan de contrôle |
| 3 | `juju status -m admin/openstack-machines` | État des composants de calcul et de stockage |
| 4 | En cas d’anomalie : message, `show-status-log`, `debug-log` | Cause du blocage ou de l’erreur |
| 5 | Connexion Horizon, création d’une VM, accès SSH et test réseau | Fonctionnement réel du cloud |

**Juju renseigne sur le déploiement et l’administration des services.** Pour la consommation CPU/RAM détaillée, les alertes et l’historique des performances, il faut une supervision complémentaire. Pour l’état des VM créées dans Nova, utiliser Horizon ou le client OpenStack.

## Références officielles

- [Documentation Juju 3.6 et commandes CLI](https://documentation.ubuntu.com/juju/3.6/)
- [Framework Ops : développement des charms](https://canonical.com/juju/docs/ops/latest/)
- [Charmcraft : structure du projet et construction](https://canonical.com/juju/docs/charmcraft/4.3/reference/files/charmcraft-yaml-file/)
- [Charm Neutron Kubernetes](https://charmhub.io/neutron-k8s)

Pour vérifier une option de la version installée : `juju help status`, `juju help debug-log` ou `juju help ssh`. `help` affiche l’aide sans modifier le déploiement.
