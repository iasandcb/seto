#!/usr/bin/env python3
"""Generate entitlements matching an Apple Developer macOS provisioning profile.
Usage: python3 scripts/cloudkit-entitlements.py TEAM_ID CONTAINER_ID OUTPUT
"""
import plistlib
import sys
team, container, output = sys.argv[1:]
if container != "iCloud.com.ias.seto":
    raise SystemExit("Container must be iCloud.com.ias.seto")
with open(output, 'wb') as stream:
    plistlib.dump({
        'com.apple.application-identifier': team + '.com.ias.inputmethod.seto',
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.icloud-services': ['CloudKit'],
        'com.apple.developer.icloud-container-identifiers': [container],
        'com.apple.developer.icloud-container-environment': 'Production',
    }, stream)
