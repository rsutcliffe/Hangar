# Releasing Hangar

A release is a disk image, `Hangar-<version>.dmg`, signed with a Developer ID certificate and notarised by Apple, so it opens on anyone's Mac without a security warning. `scripts/release.sh` does the whole job. Hangar is not sandboxed (it runs `ssh` and `colima`), so this is the route for a download from a GitHub release.

## One-off setup

1. **Developer ID Application certificate.** In Xcode: Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸ + ▸ Developer ID Application. Only the account holder can create one. It lands in your login keychain; keep a backup, since it signs every release.
2. **Your signing team.** Put `DEVELOPMENT_TEAM = <team id>` in the git-ignored `Local.xcconfig` (or set `HANGAR_TEAM`). See `Local.xcconfig.example`.
3. **Notarisation login in the keychain.** Make an app-specific password at account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords, then run this once and paste the password when asked:

   ```bash
   xcrun notarytool store-credentials hangar-notary --apple-id <your Apple ID> --team-id <your team ID>
   ```

   The password stays in your keychain; the script never sees it. The login belongs to the Apple ID and team, not the app, so a login made for another app on the same team also works: the script tries `HANGAR_NOTARY_PROFILE`, then `hangar-notary`, then `nightwatch-notary`.

## Each release

1. Add a `## <version> - <date>` section to `docs/CHANGELOG.md`. It becomes the GitHub release notes, so describe what changed for people using the app. A release with no section is refused.
2. Set `MARKETING_VERSION` in `project.yml`, commit, and tag that commit: `git tag -a v0.1.0 -m "Don't Panic" && git push origin v0.1.0`. The first line of the tag message is the release's name (the title becomes "Hangar 0.1.0: Don't Panic"); releases so far are named after The Hitchhiker's Guide to the Galaxy.
3. With the tag checked out and nothing uncommitted, run one of:

   ```bash
   scripts/release.sh                       # build, sign, notarise, staple and verify build/release/Hangar-<v>.dmg
   scripts/release.sh --publish --draft     # the same, then attach it to a DRAFT GitHub release for you to review
   scripts/release.sh --publish             # the same, attached to a public release
   scripts/release.sh --skip-notarise       # signing and packaging check only; not for distribution
   ```

   The script builds a Release signed with the hardened runtime and a secure timestamp, packages the DMG with an Applications shortcut and signs it, submits it to Apple and waits (usually a few minutes; on a rejection it prints Apple's log), staples the ticket, checks the DMG as Gatekeeper will, then mounts it read-only and checks the app inside. It writes `Hangar-<v>.dmg.sha256` and a copy named `Hangar.dmg` (with its checksum) so a website can link to `https://github.com/rsutcliffe/Hangar/releases/latest/download/Hangar.dmg` once.

`--publish` refuses to run unless the tag exists on the current commit, the working tree is clean, the DMG is notarised and the changelog section exists.

## Releasing from Xcode instead

Product ▸ Archive, then in the Organizer Distribute App ▸ Direct Distribution, upload for notarisation and Export once Apple approves. This notarises the app but not a DMG; check the result with:

```bash
codesign --verify --deep --strict Hangar.app
spctl --assess --type execute --verbose=2 Hangar.app   # expect: accepted, source=Notarized Developer ID
```

## First run on a new Mac

Run Hangar from `/Applications` rather than a build folder. macOS asks for **Local Network** access the first time it connects to another machine over SSH, and for **Notifications**; allow both. Changing the app's bundle ID resets these permissions, so it is fixed at `io.github.rsutcliffe.hangar`.
