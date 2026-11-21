# Releasing Stet

A release is a DMG (drag Stet into Programme/Applications) and a ZIP of the same app, built by
`scripts/release.sh` into `build/release/`. Without an Apple Developer account the app is
signed ad hoc: fine for testing, but macOS blocks it on other Macs until someone chooses
System Settings ▸ Privacy & Security ▸ "Open Anyway". With the account it is signed with a
Developer ID and notarized by Apple, and opens without any warning.

## Test build (no account needed)

```bash
scripts/release.sh
```

Builds the Release configuration for Apple silicon and Intel, with the hardened runtime
(required for notarization), and runs nothing else. Check it with the self-tests:

```bash
build/release/Stet.app/Contents/MacOS/Stet --selftest
```

## One-time setup with the Developer account

1. **Certificate.** Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸
   "+" ▸ **Developer ID Application**. (Only the account holder can create it.) Its name:

   ```bash
   security find-identity -v -p codesigning
   ```

   It looks like `Developer ID Application: Markus Roth (AB12CD34EF)`; the part in
   parentheses is the team ID.

2. **App-specific password** for the notary service: appleid.apple.com ▸ Sign-In and
   Security ▸ App-Specific Passwords ▸ "+", name it e.g. "Stet notarization".

3. **Store it in the keychain** under a profile name (asks for the password; nothing ends up
   in the repo or the shell history):

   ```bash
   xcrun notarytool store-credentials stet-notary --apple-id <your Apple ID> --team-id <TEAMID>
   ```

## Signed and notarized release

```bash
STET_SIGN_IDENTITY="Developer ID Application: Markus Roth (TEAMID)" STET_NOTARY_PROFILE=stet-notary scripts/release.sh
```

The script builds the app, signs every part of it inside out (Sparkle's helper programs, the
frameworks, the Quick Look extensions, then the app) with a secure timestamp, sends the app to
Apple's notary service, staples the ticket to the app, builds the DMG, signs and notarizes that
too, and finally asks Gatekeeper (`spctl`) whether both would open without a warning.
Notarization usually takes a few minutes. A version other than the one in `project.yml`:
`scripts/release.sh 0.9.1`.

The first time, macOS asks whether `codesign` may use the Developer ID key: enter the login
password and choose "Always Allow" (otherwise it asks again for each part it signs).

## Updates (Sparkle)

Stet looks once a day for `appcast.xml` in the newest GitHub release
(`SUFeedURL` in `project.yml`) and offers the update; it installs only if the user agrees.
Updates are signed with an EdDSA key: its public half is `SUPublicEDKey` in `project.yml`,
the private half is in the login keychain of the Mac that builds releases (created with
Sparkle's `generate_keys`, item "Private key for signing Sparkle updates"). Keep a copy of it
somewhere safe (`generate_keys -x <file>` exports it): without it there can be no further updates
for installed copies.

`scripts/release.sh` writes `build/release/appcast.xml` for the ZIP (with `scripts/appcast.sh`,
which also redoes just the feed if that step failed, without building and notarizing again).
The first time, macOS asks whether `sign_update` may use the key: choose "Always Allow".
Upload `appcast.xml` together with the DMG and the ZIP.

## Publishing on GitHub

1. Tag the commit the release was built from: `git tag v0.9.0 && git push origin v0.9.0`.
2. GitHub ▸ Releases ▸ "Draft a new release", choose the tag, attach
   `Stet-0.9.0.dmg`, `Stet-0.9.0.zip` and `appcast.xml`, and paste the checksums from
   `Stet-0.9.0.sha256`. (The ZIP is what Sparkle downloads; the DMG is for new users.)
3. Test it the way a club member will: download the DMG on another Mac (or another user
   account), open it, drag Stet to Programme, start it. There must be no warning.

## Later: Homebrew

A tap is a separate repository named `homebrew-stet` with one file, `Casks/stet.rb`:

```ruby
cask "stet" do
  version "0.9.0"
  sha256 "<sha256 of Stet-0.9.0.zip>"

  url "https://github.com/BooneyNoobington/stet/releases/download/v#{version}/Stet-#{version}.zip"
  name "Stet"
  desc "Writing app with a lossless, branchable history"
  homepage "https://github.com/BooneyNoobington/stet"

  depends_on macos: ">= :sonoma"

  app "Stet.app"
end
```

Then `brew install --cask BooneyNoobington/stet/stet`. Homebrew expects notarized apps, so
this comes after the first notarized release.
