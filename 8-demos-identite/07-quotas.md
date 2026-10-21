# Démo 07 : les quotas

**Module 10 · 15 min.**
**Modifie :** les quotas des nœuds `prod` et `horsprod`, de `dev-portail`, `rec-portail` et `prod-paiement`.

Un quota est un plafond par projet et par type de ressource, tenu **par chaque service** (Nova, Neutron, Cinder). Sans lui, un projet peut consommer tout le cloud ; c'est le vrai levier de la plateforme.

```bash
source ~/demos-identite/demo-env.sh
DEV=$(projet_id dev-portail orion); REC=$(projet_id rec-portail orion); PAIE=$(projet_id prod-paiement orion)
```

⚠ `quota show` et `quota set` n'acceptent pas `--domain` : on désigne le projet par son **identifiant**. Un nom seul peut viser le mauvais projet d'un autre domaine.

## 1. Lire

```bash
openstack quota show --default -f value | grep -E '^(instances|cores|ram|networks|floating-ips|volumes|gigabytes) '
openstack quota show --usage "$DEV"
openstack registered limit list
```

✅ Défauts : `instances 10`, `cores 20`, `ram 51200`, `networks 100`, `floating-ips 50`, `volumes 10`, `gigabytes 1000`. `dev-portail` les suit, avec 1 réseau consommé (celui de Sarah). `registered limit list` est vide.

⚠ Dans `--usage`, les lignes de Neutron affichent un dictionnaire `{'limit': …, 'in_use': …}` : défaut d'affichage du client.

**À dire.**
- Un projet neuf prend les **défauts**. Un gestionnaire qui crée cent projets promet cent fois les défauts : c'est le réglage le plus important.
- Liste vide : ce cloud utilise les quotas **classiques** de chaque service, pas les limites unifiées de Keystone.

## 2. Fixer

**Pourquoi.** Les nœuds ne doivent rien porter ; le hors-production doit rester petit ; la base de paiement ne doit jamais être exposée à l'extérieur.

```bash
for n in prod horsprod; do
  openstack quota set "$(projet_id $n orion)" --instances 0 --cores 0 --ram 0 --networks 0 --floating-ips 0 --volumes 0
done
openstack quota set "$DEV" --instances 2 --cores 4 --ram 4096 --networks 1 --floating-ips 0
openstack quota set "$REC" --instances 0
openstack quota set "$PAIE" --floating-ips 0
openstack quota show "$DEV" -f value | grep -E '^(instances|cores|ram|networks|floating-ips) '
```

✅ Les nouvelles valeurs. Une seule commande `quota set` règle Nova, Neutron et Cinder : le client répartit les options.

**À dire.**
- Nœuds à zéro : on y range, on n'y crée rien.
- `floating-ips 0` : le moyen le plus simple de rendre un projet non exposable.
- Abaisser sous la consommation ne détruit rien ; les nouvelles demandes sont refusées.

## 3. Voir un quota bloquer

❓ Sarah a déjà un réseau en `dev-portail`, quota 1. Que se passe-t-il au deuxième ?

```bash
en_tant_que sarah orion projet dev-portail orion -- network create dev-portail-net2
```

⛔ `ConflictException: 409, Quota exceeded for resources: ['network'].`

Une instance en recette, où le quota est à 0 (prérequis : l'image `ubuntu` et le gabarit `m1.tiny`, voir `1-demo-openstack`) :

```bash
openstack image list -c Name -f value | grep -x ubuntu || echo "image ubuntu absente : sauter cet essai"
en_tant_que sarah orion projet rec-portail orion -- server create quota-test --flavor m1.tiny --image ubuntu --nic none
en_tant_que sarah orion projet rec-portail orion -- server list
```

⛔ `403 … Quota exceeded for instances: Requested 1, but already used 0 of 0 instances`. `server list` est vide.

**À dire.**
- Le quota est vérifié **à l'entrée** de l'API, avant toute planification : rien n'est créé.
- Ne pas confondre : « Quota exceeded » = le plafond du projet ; « No valid host » = la capacité réelle du cloud manque.
- ⚠ Toujours vérifier la valeur avec `quota show` avant l'essai : si le `quota set` a échoué, l'instance serait créée. Le cas échéant : `en_tant_que sarah orion projet rec-portail orion -- server delete quota-test`.

## 4. Qui peut changer un quota

Rappel de la démo 05 (test 7) : Lucas, gestionnaire du domaine, ne peut pas. Sarah, membre du projet, peut **lire** ses quotas, pas les modifier :

```bash
en_tant_que sarah orion projet dev-portail orion -- quota set "$DEV" --instances 50
openstack quota show "$DEV" -f value | grep '^instances '
```

⛔ Refus de la politique *(message exact non vérifié)*. ✅ `instances 2` : rien n'a changé.

**À dire.** Créer un projet peut se déléguer ; fixer sa capacité, non. C'est l'arbitrage entre organisations, il reste à la plateforme.
