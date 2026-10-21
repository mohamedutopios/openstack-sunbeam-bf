#!/usr/bin/env python3
"""Read Keystone SAML metadata, show actual entityID / ACS / signing certificate."""
import sys
import xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
ns={'md':'urn:oasis:names:tc:SAML:2.0:metadata','ds':'http://www.w3.org/2000/09/xmldsig#'}
print('Client ID / Entity ID:',root.attrib['entityID'])
for node in root.findall('.//md:AssertionConsumerService',ns):
    print('ACS',node.attrib.get('Binding'),node.attrib['Location'])
for node in root.findall('.//md:SingleLogoutService',ns):
    print('SLO',node.attrib.get('Binding'),node.attrib['Location'])
for node in root.findall('.//ds:X509Certificate',ns):
    print('SP X509 certificate (base64):', ''.join(node.text.split()))
