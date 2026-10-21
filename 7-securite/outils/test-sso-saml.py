#!/usr/bin/env python3
"""Connexion fédérée SAML à Keystone, sans navigateur (démo 2).

Joue le trajet d'un navigateur : Keystone -> Keycloak (identifiant et mot de
passe) -> assertion SAML signée -> Keystone, qui délivre un jeton.

Usage, sur Lab-Sunbeam, après `source ~/admin-openrc` (pour OS_CACERT) :
    python3 test-sso-saml.py alice
Le mot de passe est demandé sans écho. Le jeton obtenu est rangé dans
~/lab-sec-fed-token (droits 600), jamais affiché en entier.
"""
import getpass
import html
import os
import re
import sys

import requests

KEYSTONE = "https://cloud.lab.test/openstack-keystone/v3"
URL = KEYSTONE + "/OS-FEDERATION/identity_providers/keycloak/protocols/saml2/auth"

# Deux CA : celle de Sunbeam (cloud.lab.test) et celle du lab (sso.lab.test).
bundle = os.path.expanduser("~/lab-sec-bundle.pem")
with open(bundle, "w") as out:
    out.write(open(os.environ["OS_CACERT"]).read() + "\n")
    out.write(open(os.path.expanduser("~/ca.crt")).read().replace("\r", ""))

user = sys.argv[1] if len(sys.argv) > 1 else "alice"
password = getpass.getpass(f"Mot de passe Keycloak de {user} : ")

s = requests.Session()
s.verify = bundle

# 1. Keystone (mod_auth_mellon) renvoie vers la page de connexion de Keycloak.
r = s.get(URL)
print("1. Redirigé vers :", r.url.split("?")[0])
form = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', r.text)
if not form:
    sys.exit("   Pas de formulaire de connexion Keycloak.")

# 2. Identifiant et mot de passe : vérifiés par Keycloak, pas par OpenStack.
r = s.post(html.unescape(form.group(1)),
           data={"username": user, "password": password, "credentialId": ""})
if "SAMLResponse" not in r.text:
    msg = re.search(r"(Account is[^<\"]*|Invalid username or password\.|"
                    r"Update Account Information|Invalid password[^<\"]*)",
                    html.unescape(r.text))
    sys.exit("2. Keycloak refuse : " + (msg.group(1) if msg else "raison inconnue"))

# 3. Le navigateur poste l'assertion SAML signée à Keystone.
action = html.unescape(re.search(r'<form[^>]*action="([^"]+)"', r.text).group(1))
fields = {html.unescape(n): html.unescape(v) for n, v in
          re.findall(r'<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"', r.text)}
print("2. Assertion SAML reçue de Keycloak, postée vers :", action.split("/v3/")[1])
r = s.post(action, data=fields)
print("3. Réponse de Keystone :", r.status_code)

token = r.headers.get("X-Subject-Token")
if not token:
    sys.exit("   Pas de jeton : voir le journal de keystone-0 (mapping ?).")
token_file = os.path.expanduser("~/lab-sec-fed-token")
with open(token_file, "w") as f:
    f.write(token)
os.chmod(token_file, 0o600)
body = r.json()["token"]
u = body["user"]
print("4. Jeton non limité à un projet :", token[:8] + "…, expire", body["expires_at"])
print("   Utilisateur :", u["name"], "| domaine :", u["domain"]["name"])
print("   Méthode :", body["methods"], "| fournisseur :",
      u["OS-FEDERATION"]["identity_provider"]["id"],
      "| groupes (id) :", [g["id"] for g in u["OS-FEDERATION"]["groups"]])
