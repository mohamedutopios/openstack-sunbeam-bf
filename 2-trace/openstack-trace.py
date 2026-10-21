#!/usr/bin/env python3
"""Traceur temps reel des echanges entre composants OpenStack (lab Sunbeam).

A lancer dans Lab-Sunbeam, avec le compte vagrant (sudo sans mot de passe) :
    python3 openstack-trace.py [--port 8099]
Puis ouvrir http://192.168.56.10:8099/ depuis Windows.

Lecture seule : le script lit les logs des pods, les compteurs RabbitMQ et MySQL,
les bases OVN, les journaux de l'hyperviseur et les statistiques Ceph.
Il ne modifie aucune configuration. Aucun mot de passe n'est envoye a la page.
Bibliotheque standard Python uniquement.
"""
import argparse
import atexit
import base64
import collections
import itertools
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = "openstack"
KUBECTL = ["sudo", "k8s", "kubectl", "-n", NS]
HERE = os.path.dirname(os.path.abspath(__file__))
RABBIT_API = "http://192.168.56.211:15672/api"

# ---------------------------------------------------------------------------
# Bus d'evenements : historique borne + abonnes SSE.
# ---------------------------------------------------------------------------
_history = collections.deque(maxlen=5000)
_subscribers = []
_lock = threading.Lock()
_ids = itertools.count(1)
VERBOSE = False


_client_reqs = collections.OrderedDict()
_last_activity = [0.0]
ACTIVITY_WINDOW = 8  # secondes pendant lesquelles un echange sans identifiant est rattache au client
RE_DISCOVERY = re.compile(r"^GET (/v[\d.]+)? -> (200|300)$")


def is_noise(kind, src, label, req, noise):
    """Bruit de fond = taches periodiques, signaux de vie, decouverte de versions.
    Est retenu : ce qui vient du client, ce qui porte l'identifiant d'une de ses requetes,
    ce qui suit de pres une activite liee au client, et tout changement OVN ou libvirt."""
    now = time.time()
    if kind == "mark":
        return False
    if noise or (kind == "api" and RE_DISCOVERY.match(label)):
        return True
    if src == "client":
        if req:
            _client_reqs[req] = now
            while len(_client_reqs) > 200:
                _client_reqs.popitem(last=False)
        _last_activity[0] = now
        return False
    if (req and req in _client_reqs) or kind in ("ovn", "libvirt"):
        _last_activity[0] = now
        return False
    return now - _last_activity[0] > ACTIVITY_WINDOW


class Baseline:
    """Volume habituel de chaque source au repos (hors activite du client).
    Pendant une activite, un compteur qui ne depasse pas ce volume est un signal de vie periodique."""

    def __init__(self):
        self.idle_max = {}

    def is_background(self, key, n):
        idle = time.time() - _last_activity[0] > ACTIVITY_WINDOW
        if idle:
            self.idle_max[key] = max(self.idle_max.get(key, 0), n)
            return True
        return n <= self.idle_max.get(key, 0)


def emit(kind, src, dst, label, detail="", req=None, noise=False):
    """Publie un evenement. kind : api, rpc, db, ovn, compute, libvirt, ceph, mark."""
    noise = is_noise(kind, src, label, req, noise)
    event = {
        "id": next(_ids),
        "ts": time.time(),
        "kind": kind,
        "src": src,
        "dst": dst,
        "label": label,
        "detail": detail[:600],
        "req": req,
        "noise": noise,
    }
    data = json.dumps(event, ensure_ascii=False)
    with _lock:
        _history.append(data)
        for sub in list(_subscribers):
            sub.append(data)
    if VERBOSE:
        print(f"[{kind}] {src} -> {dst} : {label}", flush=True)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def run(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


_children = []


def stop_children(*_):
    for proc in _children:
        if proc.poll() is None:
            proc.terminate()


def follow(name, cmd, handler, restart_delay=5):
    """Lance cmd, passe chaque ligne a handler, relance si le processus s'arrete."""
    def loop():
        while True:
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True, bufsize=1, errors="replace")
                _children.append(proc)
                for line in proc.stdout:
                    try:
                        handler(line.rstrip("\n"))
                    except Exception as exc:  # une ligne inattendue ne doit pas tuer la source
                        if VERBOSE:
                            log(f"{name} : ligne ignoree ({exc})")
                proc.wait()
            except Exception as exc:
                log(f"{name} : {exc}")
            log(f"{name} : flux interrompu, relance dans {restart_delay} s")
            time.sleep(restart_delay)
    threading.Thread(target=loop, name=name, daemon=True).start()


def poll(name, interval, func):
    def loop():
        while True:
            try:
                func()
            except Exception as exc:
                log(f"{name} : {exc}")
                time.sleep(5)
            time.sleep(interval)
    threading.Thread(target=loop, name=name, daemon=True).start()


def juju_action(unit, action):
    out = run(["juju", "run", "-m", NS, unit, action, "--format=json"], timeout=180)
    return list(json.loads(out).values())[0].get("results", {})


# ---------------------------------------------------------------------------
# Identification des appelants : IP des pods, adresses de l'hote, User-Agent.
# ---------------------------------------------------------------------------
_ip_names = {}
_host_ips = set()
POD_SERVICES = {
    "keystone": "keystone", "nova": "nova-api", "neutron": "neutron", "glance": "glance",
    "placement": "placement", "cinder": "cinder", "horizon": "horizon",
    "traefik-public": "traefik-public", "traefik": "traefik", "rabbitmq": "rabbitmq",
    "mysql": "mysql", "ovn-central": "ovn-northd", "ovn-relay": "ovn-relay",
}


def refresh_ips():
    pods = json.loads(run(KUBECTL + ["get", "pods", "-o", "json"]))
    names = {}
    for pod in pods.get("items", []):
        ip = pod.get("status", {}).get("podIP")
        base = re.sub(r"-\d+$", "", pod["metadata"]["name"])
        if base.endswith("-mysql-router"):
            continue
        if ip and base in POD_SERVICES:
            names[ip] = POD_SERVICES[base]
    _ip_names.clear()
    _ip_names.update(names)
    out = run(["ip", "-4", "-o", "addr"])
    _host_ips.clear()
    _host_ips.update(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)/", out))


def ip_name(ip):
    ip = ip.strip()
    if ip in _host_ips:
        return "host"
    return _ip_names.get(ip)


ALIASES = {"nova": "nova-api", "nova-api": "nova-api", "nova-compute": "nova-compute",
           "nova-scheduler": "nova-scheduler", "nova-conductor": "nova-conductor",
           "neutron": "neutron", "neutron-server": "neutron", "glance": "glance", "glance-api": "glance",
           "cinder": "cinder", "cinder-volume": "cinder-volume", "placement": "placement",
           "keystone": "keystone", "horizon": "horizon"}


def caller_from_ua(ua):
    u = ua.lower()
    if any(k in u for k in ("python-openstackclient", "osc-lib", "openstacksdk", "openstackclient")):
        return "client"
    if "mozilla" in u:
        return "client"
    if "nova-compute" in u:
        return "nova-compute"
    first = re.split(r"[/ ]", u, maxsplit=1)[0]
    if first in ALIASES:
        return ALIASES[first]
    if "neutronclient" in u:
        return "nova-compute"
    if "glanceclient" in u:
        return "nova-compute"
    if "keystoneclient" in u or "keystoneauth" in u:
        return None
    return None


def resolve_caller(ips, ua=None):
    """ips : liste issue de X-Forwarded-For (client reel en premier, proxy en dernier)."""
    if ua:
        who = caller_from_ua(ua)
        if who:
            return who
    first = ip_name(ips[0]) if ips else None
    proxy = ip_name(ips[-1]) if ips else None
    if first == "host" or first is None:
        if proxy == "traefik-public":
            return "client"
        if proxy == "traefik":
            return "nova-compute"
        return "host" if first == "host" else (proxy or "inconnu")
    if first in ("traefik", "traefik-public"):
        return "client" if first == "traefik-public" else "service"
    return first


UUID = re.compile(r"[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}")


def short_path(path):
    path = re.sub(r"^/openstack-[a-z-]+", "", path)
    path = UUID.sub("{id}", path)
    return path.split("?")[0] if len(path) > 90 else path


def parse_ctx(ctx):
    """Contexte oslo : [global_req local_req user project ...] -> identifiant de correlation."""
    parts = ctx.split()
    if not parts:
        return None, False
    global_id = parts[0] if parts[0].startswith("req-") else None
    local_id = parts[1] if len(parts) > 1 and parts[1].startswith("req-") else None
    has_user = len(parts) > 2 and parts[2] not in ("-", "None")
    return global_id or local_id, has_user


def is_probe(method, path, ua=""):
    p = path.split("?")[0].rstrip("/")
    if method == "GET" and p in ("", "/healthcheck", "/v1/health"):
        return True
    return "kube-probe" in ua or "Go-http-client" in ua


# ---------------------------------------------------------------------------
# Source 1 : logs des API (kubectl logs -f).
# ---------------------------------------------------------------------------
RE_APACHE = re.compile(r'\] (?P<ip>[0-9a-fA-F.:]+) - \S+ \[[^\]]+\] "(?P<m>[A-Z]+) (?P<path>[^ "]+)[^"]*" '
                       r'(?P<st>\d{3}) \S+(?: \d+)? "[^"]*" "(?P<ua>[^"]*)"')
RE_WSGI = re.compile(r'(?:neutron\.wsgi|nova\.api\.openstack\.requestlog|placement\.requestlog|'
                     r'glance\.common\.wsgi|cinder\.api\.openstack\.wsgi|eventlet\.wsgi\.server) '
                     r'\[(?P<ctx>[^\]]*)\] (?P<ips>[0-9a-fA-F.:, ]+?) "(?P<m>[A-Z]+) (?P<path>[^ "]+)'
                     r'[^"]*" status: (?P<st>\d{3})')
RE_OSLO = re.compile(r'\d+ (?P<lvl>INFO|WARNING|ERROR) (?P<logger>[\w.]+) \[(?P<ctx>[^\]]*)\] (?P<msg>.*)')

# Services sans ligne applicative : seule la ligne Apache existe.
APACHE_SERVICES = {"keystone"}
# Services dont on montre aussi les messages INFO lies a une requete :
LOG_SERVICES = {"nova-scheduler", "nova-conductor"}

API_SOURCES = [
    ("keystone-0", "keystone", "keystone"),
    ("nova-0", "nova-api", "nova-api"),
    ("neutron-0", "neutron-server", "neutron"),
    ("glance-0", "glance-api", "glance"),
    ("placement-0", "placement-api", "placement"),
    ("cinder-0", "cinder-api", "cinder"),
    ("nova-0", "nova-scheduler", "nova-scheduler"),
    ("nova-0", "nova-conductor", "nova-conductor"),
]


_pending_req = collections.OrderedDict()


def api_handler(service):
    """Ligne applicative (identifiant de requete) puis ligne Apache (User-Agent) : on combine les deux.
    Neutron n'a pas de ligne Apache : sa ligne applicative est emise directement."""
    state = {"apache": service in APACHE_SERVICES}

    def handle(line):
        m = RE_APACHE.search(line)
        if m:
            state["apache"] = True
            if is_probe(m["m"], m["path"], m["ua"]):
                return
            req = _pending_req.pop((service, m["m"], m["path"]), None)
            src = resolve_caller([m["ip"]], m["ua"])
            path = short_path(m["path"])
            tag = " (validation du jeton)" if "auth/tokens" in path and m["m"] == "GET" else ""
            emit("api", src, service, f'{m["m"]} {path} -> {m["st"]}{tag}',
                 detail=f'User-Agent : {m["ua"]}', req=req)
            return
        m = RE_WSGI.search(line)
        if m:
            if is_probe(m["m"], m["path"]):
                return
            req, _ = parse_ctx(m["ctx"])
            if state["apache"]:
                _pending_req[(service, m["m"], m["path"])] = req
                while len(_pending_req) > 500:
                    _pending_req.popitem(last=False)
                return
            ips = [x for x in re.split(r"[ ,]+", m["ips"].strip()) if x]
            emit("api", resolve_caller(ips), service, f'{m["m"]} {short_path(m["path"])} -> {m["st"]}',
                 detail=f'Adresses : {", ".join(ips)}', req=req)
            return
        if service in LOG_SERVICES:
            m = RE_OSLO.search(line)
            if m and not m["logger"].startswith("oslo.messaging.notification"):
                req, has_user = parse_ctx(m["ctx"])
                if req and has_user:
                    emit("compute", service, service, m["msg"][:160], detail=m["logger"], req=req)
    return handle


# ---------------------------------------------------------------------------
# Source 2 : RabbitMQ (API de gestion, compteurs de messages).
# ---------------------------------------------------------------------------
QUEUE_CONSUMERS = [
    (r"^conductor", "nova-conductor"), (r"^scheduler", "nova-scheduler"), (r"^compute", "nova-compute"),
    (r"^q-plugin", "neutron"), (r"^q-reports-plugin", "neutron"), (r"^q-server-resource-versions", "neutron"),
    (r"^q-metering", "neutron"), (r"^cinder-scheduler", "cinder"), (r"^cinder-volume", "cinder-volume"),
    (r"^reply_", "reponse RPC"), (r"^notifications|^versioned_notifications", "notifications"),
]
PROCESS_NODES = {"neutron-server": "neutron", "nova-api-metadata": "metadata", "nova-api": "nova-api",
                 "mod_wsgi": "nova-api",  # nova-api tourne sous Apache mod_wsgi
                 "nova-conductor": "nova-conductor", "nova-scheduler": "nova-scheduler",
                 "nova-compute": "nova-compute", "cinder-volume": "cinder-volume",
                 "cinder-scheduler": "cinder", "cinder-api": "cinder"}
NOISY_QUEUES = re.compile(r"^(q-reports-plugin|q-server-resource-versions|cinder-|scheduler_fanout)")


def as_dict(value):
    """L'API RabbitMQ renvoie [] au lieu de {} quand un compteur est vide."""
    return value if isinstance(value, dict) else {}


def queue_consumer(name):
    for pattern, consumer in QUEUE_CONSUMERS:
        if re.search(pattern, name):
            return consumer
    return "inconnu"


def queue_family(name):
    name = re.sub(r"_fanout_[0-9a-f]+$", " (fanout)", name)
    if name.startswith("reply_"):
        return "reply_*"
    return name


class Rabbit:
    def __init__(self):
        info = juju_action("rabbitmq/0", "get-operator-info")
        user, password = info["operator-user"], info["operator-password"]
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.queues = {}
        self.channels = {}
        self.processes = {}
        self.baseline = Baseline()
        self.last_connections = 0

    def refresh_connections(self):
        """Nom de processus annonce par oslo.messaging (nova-conductor, neutron-server...)."""
        names = {}
        for conn in self.get("/connections?columns=name,client_properties.connection_name"):
            process = as_dict(conn.get("client_properties")).get("connection_name", "")
            if process:
                names[conn["name"]] = PROCESS_NODES.get(process.split(":")[0], process.split(":")[0])
        self.processes = names
        self.last_connections = time.time()

    def get(self, path):
        req = urllib.request.Request(RABBIT_API + path, headers={"Authorization": self.auth})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)

    def tick(self):
        # Publication : qui envoie des messages (canal -> IP du client -> service).
        if time.time() - self.last_connections > 10:
            self.refresh_connections()
        published = collections.Counter()
        for ch in self.get("/channels?columns=name,connection_details,message_stats.publish"):
            count = as_dict(ch.get("message_stats")).get("publish", 0)
            previous = self.channels.get(ch["name"])
            self.channels[ch["name"]] = count
            if previous is not None and count > previous:
                details = as_dict(ch.get("connection_details"))
                who = self.processes.get(details.get("name", ""))
                if not who:
                    self.last_connections = 0  # nouvelle connexion : relire les noms au prochain tour
                    who = ip_name(details.get("peer_host", "")) or "inconnu"
                published[who] += count - previous
        for who, n in published.items():
            emit("rpc", who, "rabbitmq", f"publie {n} message(s)",
                 detail="Compteur message_stats.publish des canaux AMQP de ce processus",
                 noise=self.baseline.is_background(("pub", who), n))
        # Livraison : vers quelle file, donc quel consommateur.
        delivered = collections.Counter()
        for q in self.get("/queues/" + urllib.request.quote(NS, safe="") +
                          "?columns=name,message_stats.publish"):
            count = as_dict(q.get("message_stats")).get("publish", 0)
            previous = self.queues.get(q["name"])
            self.queues[q["name"]] = count
            if previous is not None and count > previous:
                delivered[queue_family(q["name"])] += count - previous
        for family, n in delivered.items():
            background = self.baseline.is_background(("queue", family), n)
            emit("rpc", "rabbitmq", queue_consumer(family), f"file {family} : {n} message(s)",
                 detail="Compteur message_stats.publish de la file",
                 noise=background or bool(NOISY_QUEUES.search(family)))


# ---------------------------------------------------------------------------
# Source 3 : MySQL (performance_schema, compteurs de requetes par base).
# ---------------------------------------------------------------------------
SCHEMA_SERVICES = {
    "keystone": "keystone", "nova": "nova-conductor", "nova_api": "nova-api", "nova_cell0": "nova-conductor",
    "neutron_server": "neutron", "placement_api": "placement", "glance": "glance", "cinder": "cinder",
    "horizon": "horizon",
}
SQL = ("SELECT SCHEMA_NAME, UPPER(SUBSTRING_INDEX(TRIM(DIGEST_TEXT), ' ', 1)), SUM(COUNT_STAR) "
       "FROM performance_schema.events_statements_summary_by_digest "
       "WHERE SCHEMA_NAME IN ({}) GROUP BY 1, 2; SELECT '__FIN__';\n").format(
           ", ".join(f"'{s}'" for s in SCHEMA_SERVICES))


class MySQL:
    def __init__(self):
        info = juju_action("mysql/0", "get-password")
        self.user, self.password = info["username"], info["password"]
        self.proc = None
        self.counts = {}
        self.baseline = Baseline()

    def start(self):
        cmd = KUBECTL + ["exec", "-i", "mysql-0", "-c", "mysql", "--", "env", f"MYSQL_PWD={self.password}",
                         "mysql", f"-u{self.user}", "-N", "-B", "--unbuffered"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        _children.append(self.proc)

    def tick(self):
        if self.proc is None or self.proc.poll() is not None:
            self.start()
        self.proc.stdin.write(SQL)
        self.proc.stdin.flush()
        rows = []
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            if line == "__FIN__":
                break
            rows.append(line.split("\t"))
        changes = collections.defaultdict(collections.Counter)
        for schema, verb, total in rows:
            if verb in ("SET", "COMMIT", "ROLLBACK", "SHOW", "START", "BEGIN", "XA"):
                continue  # gestion de session et de transaction, sans interet pedagogique
            key = (schema, verb)
            total = int(total)
            previous = self.counts.get(key)
            self.counts[key] = total
            if previous is not None and total > previous:
                changes[schema][verb] += total - previous
        for schema, verbs in changes.items():
            writes = sum(n for v, n in verbs.items() if v in ("INSERT", "UPDATE", "DELETE", "REPLACE"))
            text = ", ".join(f"{n} {v}" for v, n in verbs.most_common())
            # Le volume d'ecritures distingue un vrai changement d'un signal de vie (UPDATE services...).
            background = self.baseline.is_background(("db", schema, "w"), writes) and \
                self.baseline.is_background(("db", schema, "r"), sum(verbs.values()) - writes)
            emit("db", SCHEMA_SERVICES.get(schema, schema), "mysql", f"base {schema} : {text}",
                 detail=f"{writes} ecriture(s). Compteurs performance_schema.events_statements_summary_by_digest",
                 noise=background)


# ---------------------------------------------------------------------------
# Source 4 : bases OVN Northbound et Southbound (ovsdb-client monitor).
# ---------------------------------------------------------------------------
NB_TABLES = {"Logical_Switch", "Logical_Switch_Port", "Logical_Router", "Logical_Router_Port",
             "Logical_Router_Static_Route", "NAT", "ACL", "Port_Group", "DHCP_Options", "Address_Set",
             "Load_Balancer", "Gateway_Chassis", "HA_Chassis_Group"}
SB_TABLES = {"Port_Binding", "Datapath_Binding", "MAC_Binding", "Chassis"}
ACTIONS = {"insert": "ajout", "delete": "suppression", "old": "avant", "new": "modification"}


def ovsdb_value(v):
    """Decode le JSON OVSDB : ["set", [...]], ["map", [[k, v], ...]], ["uuid", "..."]."""
    if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str):
        kind, inner = v
        if kind == "set":
            items = [ovsdb_value(x) for x in inner]
            return items[0] if len(items) == 1 else ("" if not items else items)
        if kind == "map":
            return {str(k): ovsdb_value(x) for k, x in inner}
        if kind in ("uuid", "named-uuid"):
            return inner[:8]
    return v


def ext_id(cols, key):
    ext = cols.get("external_ids")
    return ext.get(key, "") if isinstance(ext, dict) else ""


def describe_row(table, cols):
    """Resume lisible d'une ligne OVN, selon la table."""
    owner = ext_id(cols, "neutron:device_owner")
    if table == "Logical_Switch":
        return f'reseau {ext_id(cols, "neutron:network_name") or cols.get("name", "")}'
    if table == "Logical_Router":
        return f'routeur {ext_id(cols, "neutron:router_name") or cols.get("name", "")}'
    if table == "Logical_Switch_Port":
        kind = owner or cols.get("type") or "port"
        return f'{kind} port {str(cols.get("name", ""))[:8]} {cols.get("addresses") or ""}'.strip()
    if table == "Logical_Router_Port":
        return f'port de routeur {cols.get("networks") or ""}'.strip()
    if table == "Port_Binding":
        return f'port {str(cols.get("logical_port", ""))[:16]} {cols.get("type") or ""}'.strip()
    if table == "ACL":
        return f'{cols.get("direction", "")} {cols.get("action", "")} : {str(cols.get("match", ""))[:90]}'
    if table == "NAT":
        return f'{cols.get("type", "")} {cols.get("external_ip", "")} <-> {cols.get("logical_ip", "")}'
    if table == "Port_Group":
        return f'groupe de securite {ext_id(cols, "neutron:security_group_id")[:8]}'
    if table == "DHCP_Options":
        return f'DHCP {cols.get("cidr", "")}'
    for col in ("name", "logical_port", "ip_prefix", "logical_ip", "ip", "chassis_name"):
        value = cols.get(col)
        if value not in (None, "", [], {}):
            return f"{col}={str(value)[:80]}"
    return ""


# Colonnes de Port_Binding ecrites par ovn-controller (hyperviseur), et non par ovn-northd.
CONTROLLER_COLUMNS = {"chassis", "up", "encap", "additional_chassis", "additional_encap", "virtual_parent"}
IGNORED_CHANGES = {"_version", "nb_cfg", "nb_cfg_timestamp", "external_ids", "hv_cfg", "hv_cfg_timestamp",
                   "options"}


def ovsdb_handler(db, tables, src, dst):
    """Une modification arrive en deux lignes : 'old' (colonnes modifiees, les autres a null)
    puis 'new' (ligne complete, uuid vide). On les associe par ordre d'arrivee."""
    previous = {"changed": set()}

    def handle(line):
        line = line.strip()
        if not line:
            return
        data = json.loads(line)
        table = (data.get("caption") or "").split(" ")[0]
        headings = data.get("headings")
        if table not in tables or not headings:
            return
        for values in data.get("data", []):
            row_id, action = str(values[0])[:8], values[1]
            raw = dict(zip(headings[2:], values[2:]))
            if action == "initial":
                continue
            if action == "old":
                previous["changed"] = {k for k, v in raw.items() if v is not None} - IGNORED_CHANGES
                continue
            cols = {h: ovsdb_value(v) for h, v in raw.items()}
            what = describe_row(table, cols)
            writer = src
            if action == "new":
                diff, previous["changed"] = previous["changed"], set()
                if not diff:
                    continue  # compteurs ou identifiants internes seulement
                what += " : " + ", ".join(f"{k}={str(cols.get(k))[:40]}" for k in sorted(diff))
                if table == "Port_Binding" and diff & CONTROLLER_COLUMNS:
                    writer = "ovn-controller"  # l'hyperviseur declare qu'il prend le port en charge
            emit("ovn", writer, dst, f"{table} : {ACTIONS.get(action, action)} {what}".strip(),
                 detail=f"Base {db}" + (f", ligne {row_id}" if row_id else ""))
    return handle


def ovn_controller_handler(line):
    """Fichier de log d'ovn-controller : prise en charge des ports par l'hyperviseur."""
    parts = line.split("|")
    if len(parts) < 5 or parts[2] != "binding":
        return
    emit("ovn", "ovn-sb", "ovn-controller", parts[4][:160],
         detail="ovn-controller lit la base Southbound et programme Open vSwitch (br-int)")


def ovsdb_cmd(container, sock, db):
    return KUBECTL + ["exec", "ovn-central-0", "-c", container, "--", "ovsdb-client", "monitor",
                      "--format=json", f"unix:{sock}", db, "ALL"]


# ---------------------------------------------------------------------------
# Source 5 : hyperviseur (journaux snap, libvirt) et Ceph.
# ---------------------------------------------------------------------------
JOURNAL_UNITS = {
    "snap.openstack-hypervisor.nova-compute.service": "nova-compute",
    "snap.openstack-hypervisor.neutron-ovn-metadata-agent.service": "metadata",
}
OVN_CONTROLLER_LOG = "/var/snap/openstack-hypervisor/common/log/ovn/ovn-controller.log"
NOISY_LOGS = re.compile(r"privsep|Placement PCI resource view|Active base files|image .* at \(|"
                        r"Running cmd|rootwrap|Removable base files|Skipping periodic", re.I)


def journal_handler(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return
    unit = JOURNAL_UNITS.get(entry.get("_SYSTEMD_UNIT", ""))
    msg = entry.get("MESSAGE", "")
    if not unit or not isinstance(msg, str):
        return
    m = RE_OSLO.search(msg)
    if not m or m["lvl"] == "WARNING" and "instance" not in msg:
        return
    req, _ = parse_ctx(m["ctx"])
    text = m["msg"]
    if unit == "nova-compute" and "[instance:" not in text and not req:
        return
    emit("compute", unit, unit, text[:180], detail=m["logger"], req=req,
         noise=bool(NOISY_LOGS.search(text)))


def libvirt_handler(line):
    m = re.search(r"event '(\w+)' for domain '?([\w-]+)'?:? ?(.*)", line)
    if m:
        emit("libvirt", "nova-compute", "libvirt", f"{m.group(2)} : {m.group(1)} {m.group(3)}".strip(),
             detail="virsh event (QEMU/KVM)")


class Ceph:
    def __init__(self):
        self.last = {}

    def tick(self):
        stats = json.loads(run(["sudo", "ceph", "osd", "pool", "stats", "-f", "json"], timeout=20))
        for pool in stats:
            io = pool.get("client_io_rate", {})
            rd, wr = io.get("read_op_per_sec", 0), io.get("write_op_per_sec", 0)
            if not rd and not wr:
                continue
            name = pool["pool_name"]
            client = {"glance": "glance", "cinder-volume-ceph": "cinder-volume"}.get(name, "client")
            emit("ceph", client, "ceph", f"pool {name} : {rd} lecture(s)/s, {wr} ecriture(s)/s",
                 detail="ceph osd pool stats (moyenne glissante)",
                 noise=name.startswith(("default.rgw", ".rgw", ".mgr")))


# ---------------------------------------------------------------------------
# Serveur HTTP : page, flux SSE, historique, marqueurs d'etape.
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_body(self, body, ctype, code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self.send_body(f.read(), "text/html; charset=utf-8")
        elif self.path == "/history":
            with _lock:
                body = "[" + ",".join(_history) + "]"
            self.send_body(body.encode(), "application/json")
        elif self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            box = collections.deque()
            with _lock:
                _subscribers.append(box)
            try:
                last_ping = time.time()
                while True:
                    while box:
                        self.wfile.write(f"data: {box.popleft()}\n\n".encode())
                    if time.time() - last_ping > 15:
                        self.wfile.write(b": ping\n\n")
                        last_ping = time.time()
                    self.wfile.flush()
                    time.sleep(0.2)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with _lock:
                    _subscribers.remove(box)
        else:
            self.send_body(b"Not found", "text/plain", 404)

    def do_POST(self):
        if self.path == "/mark":
            length = int(self.headers.get("Content-Length", 0))
            label = json.loads(self.rfile.read(length) or b"{}").get("label", "").strip()[:120]
            if label:
                emit("mark", "", "", label)
            self.send_body(b"{}", "application/json")
        elif self.path == "/clear":
            with _lock:
                _history.clear()
            self.send_body(b"{}", "application/json")
        else:
            self.send_body(b"Not found", "text/plain", 404)


def main():
    global VERBOSE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--no-rabbit", action="store_true")
    parser.add_argument("--no-mysql", action="store_true")
    parser.add_argument("--no-ceph", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true", help="affiche aussi les evenements dans le terminal")
    args = parser.parse_args()
    VERBOSE = args.verbose
    atexit.register(stop_children)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    log("Lecture des adresses des pods...")
    refresh_ips()
    poll("ips", 60, refresh_ips)

    for pod, container, service in API_SOURCES:
        follow(f"logs {service}", KUBECTL + ["logs", "-f", "--tail=0", pod, "-c", container], api_handler(service))

    follow("ovn nb", ovsdb_cmd("ovn-nb-db-server", "/var/run/ovn/ovnnb_db.sock", "OVN_Northbound"),
           ovsdb_handler("OVN_Northbound", NB_TABLES, "neutron", "ovn-nb"))
    follow("ovn sb", ovsdb_cmd("ovn-sb-db-server", "/var/run/ovn/ovnsb_db.sock", "OVN_Southbound"),
           ovsdb_handler("OVN_Southbound", SB_TABLES, "ovn-northd", "ovn-sb"))

    journal = ["sudo", "journalctl", "-f", "-n", "0", "-o", "json"]
    for unit in JOURNAL_UNITS:
        journal += ["-u", unit]
    follow("journal hyperviseur", journal, journal_handler)
    follow("ovn-controller", ["sudo", "tail", "-F", "-n", "0", OVN_CONTROLLER_LOG], ovn_controller_handler)
    follow("libvirt", ["sudo", "openstack-hypervisor.virsh", "event", "--all", "--loop"], libvirt_handler)

    if not args.no_rabbit:
        log("Lecture des identifiants RabbitMQ (action Juju)...")
        rabbit = Rabbit()
        rabbit.tick()
        poll("rabbitmq", 1, rabbit.tick)
    if not args.no_mysql:
        log("Lecture des identifiants MySQL (action Juju)...")
        mysql = MySQL()
        mysql.tick()
        poll("mysql", 2, mysql.tick)
    if not args.no_ceph:
        poll("ceph", 2, Ceph().tick)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True
    log(f"Pret : ouvrir http://192.168.56.10:{args.port}/ depuis Windows (Ctrl+C pour arreter)")
    emit("mark", "", "", "Traceur demarre")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Arret.")


if __name__ == "__main__":
    main()
