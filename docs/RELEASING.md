# Releasing Zadur

A release is a DMG (drag Zadur into Programme/Applications) and a ZIP of the same app, built by
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
build/release/Zadur.app/Contents/MacOS/Zadur --selftest
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
   Security ▸ App-Specific Passwords ▸ "+", name it e.g. "Zadur notarization".

3. **Store it in the keychain** under a profile name (asks for the password; nothing ends up
   in the repo or the shell history):

   ```bash
   xcrun notarytool store-credentials stet-notary --apple-id <your Apple ID> --team-id <TEAMID>
   ```

## Signed and notarized release

```bash
ZADUR_SIGN_IDENTITY="Developer ID Application: Markus Roth (TEAMID)" ZADUR_NOTARY_PROFILE=stet-notary scripts/release.sh
```

The script builds the app, signs every part of it inside out (Sparkle's helper programs, the
frameworks, the Quick Look extensions, then the app) with a secure timestamp, sends the app to
Apple's notary service, staples the ticket to the app, builds the DMG, signs and notarizes that
too, and finally asks Gatekeeper (`spctl`) whether both would open without a warning.
Notarization usually takes a few minutes. (`STET_SIGN_IDENTITY` and `STET_NOTARY_PROFILE`, the
names from when Zadur was called Stet, work as well.) A version other than the one in `project.yml`:
`scripts/release.sh 0.9.1`.

The first time, macOS asks whether `codesign` may use the Developer ID key: enter the login
password and choose "Always Allow" (otherwise it asks again for each part it signs).

## Updates (Sparkle)

Zadur looks once a day for `appcast.xml` in the newest GitHub release
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

0. Before building: set the new `MARKETING_VERSION` in `project.yml` and commit everything.
   The build number is the number of commits, so a release built from a clean, committed
   tree belongs to exactly one commit (`release.sh` warns otherwise).
1. Push it and tag the commit the release was built from:

   ```bash
   git push origin main
   git tag -a v0.9.0 -m "Zadur 0.9.0"
   git push origin v0.9.0
   ```

2. GitHub ▸ Releases ▸ "Draft a new release", choose the tag, title "Zadur 0.9.0", attach
   `Zadur-0.9.0.dmg`, `Zadur-0.9.0.zip` and `appcast.xml`, and paste the checksums from
   `Zadur-0.9.0.sha256`. (The ZIP is what Sparkle downloads; the DMG is for new users.)
   Leave "Set as the latest release" on and "Set as a pre-release" off, then publish.
3. Test it the way a club member will: download the DMG on another Mac (or another user
   account), open it, drag Zadur to Programme, start it. There must be no warning.
4. Check that the feed is reachable (it should end in `200`):

   ```bash
   curl -sIL https://github.com/BooneyNoobington/stet/releases/latest/download/appcast.xml | grep HTTP
   ```

The release notes are what writers read: Sparkle shows the release's GitHub page in its update
window. Write them in German and without technical terms (what's new, what got fixed), plus one
line on installing ("DMG öffnen, Zadur in den Ordner Programme ziehen"). The link to hand out is
`https://github.com/BooneyNoobington/stet/releases/latest`; it always shows the newest version.

### How an update finds its way, and what breaks it

Installed copies ask `…/releases/latest/download/appcast.xml` once a day; GitHub redirects that
to the newest published release. The feed names the ZIP as
`…/releases/download/v<version>/Zadur-<version>.zip`; Sparkle downloads it and installs it only if
its EdDSA signature and length match the feed and the new app is signed by the same Developer ID.
So:

- **The tag must be exactly `v<version>`, and the files keep their names.** Otherwise the feed
  points nowhere.
- **No drafts, no pre-releases.** "Latest" only counts published, final releases; with a
  pre-release on top, installed copies don't find the new feed and quietly get no update.
- **Every release needs its own `appcast.xml`.** "Latest" moves to each new release; one
  without a feed leaves every installed copy without updates.
- **Never replace the ZIP alone.** A new ZIP needs a new feed: run `scripts/appcast.sh` and
  replace `appcast.xml` too, or Sparkle rejects the download.
- **Never change the bundle identifier** (`io.github.booneynoobington.stet`, from when Zadur was
  called Stet): Sparkle recognizes the renamed app only by it, and no installed copy would update
  any more. Updated copies keep their file name (`Stet.app`) until someone renames them in Finder.
- **If the repository is renamed on GitHub**, the old address forwards to the new one, so installed
  copies keep finding the feed. Never create another repository under the old name.
- **Never lose the update key or change `SUPublicEDKey`.** Installed copies only accept updates
  signed with the key they know.

## Later: Homebrew

A tap is a separate repository named `homebrew-zadur` with one file, `Casks/zadur.rb`:

```ruby
cask "zadur" do
  version "0.9.0"
  sha256 "<sha256 of Zadur-0.9.0.zip>"

  url "https://github.com/BooneyNoobington/stet/releases/download/v#{version}/Zadur-#{version}.zip"
  name "Zadur"
  desc "Writing app with a lossless, branchable history"
  homepage "https://github.com/BooneyNoobington/stet"

  depends_on macos: ">= :sonoma"

  app "Zadur.app"
end
```

Then `brew install --cask BooneyNoobington/zadur/zadur`. Homebrew expects notarized apps, so
this comes after the first notarized release.
