# signing/

Put the macOS provisioning profile for `com.ias.inputmethod.seto` here
(`*.provisionprofile`, with iCloud/CloudKit and the `iCloud.com.ias.seto` container).
Everything in this folder except this README is ignored by git.

With a profile here, `./build.sh` turns on iCloud sync by itself:

- uses the profile as `ICLOUD_PROFILE`,
- reads the team from the profile and writes `.build/cloudkit.entitlements`,
- signs with the keychain identity whose certificate the profile lists.

`ICLOUD_PROFILE`, `ICLOUD_ENTITLEMENTS`, `SIGNING_IDENTITY`, and `TEAM_ID` still override.
Without a profile the build is ad-hoc signed and iCloud sync is off.
