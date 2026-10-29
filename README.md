<div align="center">

<img src="app-icon.png" alt="SideInstaller" width="120" />

# SideInstaller

**Install SideStore and LiveContainer directly on your iPhone. No PC required.**

[![Install](https://img.shields.io/badge/Install-SideInstaller-2ea44f?style=for-the-badge)](https://sideinstaller.net/)
[![Version](https://img.shields.io/badge/version-1.6.1-blue?style=for-the-badge)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-iOS-lightgrey?style=for-the-badge&logo=apple)](#requirements)
[![License](https://img.shields.io/badge/license-Custom-orange?style=for-the-badge)](LICENSE.md)


</div>

---

> [!CAUTION]
> **Only install SideInstaller from the official source.**
>
> This project is open source, which means anyone can fork the code, insert a credential stealer that
> uploads your Apple ID and password to their own server, rebuild it, and redistribute it under the same
> name and icon. A malicious fork looks identical to the real app from the outside.
>
> The **only** builds I publish are:
> - **Website:** https://sideinstaller.net/
> - **Repository:** https://github.com/FrizzleM/SideInstaller
>
> Do not install SideInstaller from any other site, AltStore source, Telegram channel, Discord server,
> app repo, or mirror, no matter how official it looks. Redistributing my builds without explicit consent is also prohibited by
> the [license](LICENSE.md).
>
> There is a fake site called “sideinstaller.com”. This site is **not legit**, and is likely providing malware. Please make sure
> you only download from the **official sources** listed above.
---

## What it is

SideStore and LiveContainer are currently the best way to sideload on iOS. However, there's one big
problem: installing them requires a PC, which many people don't have. That's why I made SideInstaller,
a free and open-source iOS app that installs them directly on your iPhone, no PC required.

SideInstaller handles the entire setup process on-device. It takes care of the pairing, provisioning, and
installation steps that normally force you to plug into a computer and run desktop tools, all from a single
app running on the phone itself. Once it's done, you get a fully working SideStore and LiveContainer
setup ready to sideload your own apps.

The whole thing is built to be simple. There's no complicated configuration, no command line, and no need
to understand how any of the underlying machinery works. You just open the app, follow a few steps, and let
it do the rest. For anyone who's ever wanted to sideload but didn't own a Mac or PC, this removes the
biggest barrier to getting started.

And because it's open source, you don't have to take my word for any of it. The full code is available for
anyone to read, audit, or contribute to, so you can see exactly what's running on your device.

## Requirements

- An iPhone (the iPhone Duo too, open or closed) or iPad on iOS 27+ (iOS 17.4+ with a pairing file
  made on a computer; from iOS 26.4, a [remote pairing one](#ios-264-to-26x-a-remote-pairing-file))
- Wi-Fi (first time only)
- Your Apple account credentials (not collected)


## How to use it

1. Open [the official install page](https://sideinstaller.net/) and install the app using any
   of the certificates.
2. Once it's installed, open it.
3. Connect the device to LocalDevVPN (or any alternative)
4. Log in with your Apple account credentials.
5. Tap **Install SideStore** or **Install SideStore + LiveContainer**.
6. Wait while your selection installs.
7. That's it. No PC and no extra steps required.

### Links

SideInstaller opens three kinds of `sideinstaller://` link, and asks before acting on any of them:

- `sideinstaller://install?url=<percent-encoded https link to an .ipa>` downloads the IPA as the
  custom .ipa and installs it, for one-tap installs from a website.
- `sideinstaller://source?url=<percent-encoded https link to a source>` opens **Tools › Sources** with
  that AltStore source ready to add.
- `sideinstaller://pairingFile?data=<base64 pairing file>` imports a pairing file. SideStore sends
  one back when asked with `sidestore://pairing?urlname=sideinstaller`, which is what **Get it from
  SideStore** on the Pairing file card does.
- `sideinstaller://certificate?data=<base64 PKCS#12>&password=<password>` makes SideInstaller sign
  with that certificate from then on, once Apple lists it among your Apple ID's certificates.
  **Use SideStore's certificate** (on the “A certificate already exists” popup and the Certificates
  page) asks SideStore for its own with
  `sidestore://certificate?callback_template=sideinstaller://certificate?data=$(BASE64_CERT)&password=$(PASSWORD)`
  (percent-encoded), so a free Apple ID's one certificate serves both apps. That reply is the one
  link that doesn't ask again: SideStore has just asked whether to export it.

Discord and most chat apps only make `https://` links tappable, so to post an install link there use
`https://sideinstaller.net/open.html?url=<percent-encoded https link to an .ipa>`. That page shows
where the IPA downloads from and hands it to `sideinstaller://install`, with a button for when iOS
doesn't open the app on its own.


## Marketplace

The **Marketplace** tab browses every AltStore-format source you add, as compact rows — icon, name,
developer, category, newest version — with an install button on each row — the same JSON catalogues
AltStore and SideStore read. Its left rail lists the categories the sources file apps under (Utilities, Games, Developer, …) and
each source, and the list beside it shows what matches: search across every source, tap an app for
its screenshots and every release, or install the newest one straight from the row. Add a source by pasting its link (AltStore's own, `apps.altstore.io`, is
there to start with).

It's the same run as any other install: the `.ipa` is downloaded, signed with your Apple ID's
certificate and put on the iPhone. Nothing else has to be installed first, and no computer is involved.
Each source is cached, so the list opens without a network and says so when a refresh fails.

## Inspect an .ipa

**Tools › Inspect .ipa** reads an archive without unpacking it and shows what installing it would do:

- **Identity** — bundle ID, name, version and build, size, file count, SHA-256.
- **Compatibility** — the minimum iOS from both the plist and the executable's own header, supported
  platforms and devices, every architecture in the binary, and whether its code is still encrypted.
- **Signing** — the embedded provisioning profile and its expiry, and every app extension inside.
- **Before you install** — the things that quietly break a sideloaded app, marked as a blocker
  (App Store-encrypted code, a build for a newer iOS, no arm64 slice, no bundle ID) or a warning
  (an extension with no profile of its own, a release listing another device family).

Builds downloaded from a link or a source are put through the same check before signing, so an
encrypted App Store copy is refused instead of using up an App ID.

## Tweak browser

**Tools › Tweak browser** is the same list **App configuration › Tweaks & injectors › Browse**
opens: every package the repositories you add publish, searchable by name, bundle identifier,
developer or section, with each repository's index kept on the device so the list is there offline.

What a package says about itself is kept: its identifier, its version and the repository it came
from. The tweak list then reads `1.4 · havoc.app`, and when that repository publishes a newer release
the row offers **Update to 1.6** — downloaded, checksum-checked and swapped in, keeping the
"optional" choice. The browser itself marks a package as new, already added, or updatable, and
replacing a package replaces its earlier build instead of loading two copies of the same tweak.

A package is added the way a `.deb` picked from Files is — its libraries are taken out and loaded by
the app at launch — and nothing is installed to the system or to another app. The download is
checked against the index's SHA-256 when the repository publishes one, and a package built for
another platform is left out of the list rather than offered. Anything that names ElleKit,
Substrate, libhooker or Substitute in its dependencies picks which framework the app loads beside it,
so the missing-injector warning on the configuration page still applies.

## App configuration

**Install › Advanced › App configuration** changes what goes into a custom `.ipa` before it's
signed. Every field is optional, and the configuration stays until it's cleared, so the same build
is prepared the same way each time.

- **Identity** — a new bundle ID (installs alongside the original; extensions are re-prefixed to
  match, and the new ID is registered as its own App ID), display name, version and build number.
- **Structure** — drop the app's extensions, or its Watch app.
- **Info.plist and entitlements** — any top-level key, as text, switch, number or list, and any
  entitlement written into the app's archived entitlements file (the profile your Apple ID issues
  still decides what's actually granted).
- **Extensions** — switch off individual extensions, or remove them all, and drop the Watch app.
- **Tweaks** — add `.dylib` files or `.deb` packages (each packaged tweak keeps its identifier and
  version, so a newer release can be offered), or pick one out of a repository with
  **Browse**: any Sileo/Cydia repository (Havoc and Chariz are there to start with) is read and
  searched by name, identifier, developer or section, and a package's dependencies are shown before
  it's added. A package is unpacked and the libraries it
  installs are taken; each library is copied into the app's `Frameworks` folder and loaded by its
  main executable through an added `LC_LOAD_DYLIB` (`LC_LOAD_WEAK_DYLIB` with **Optional** on).
  Rootful and rootless packages both work. Tweaks have to be built for this iPhone — arm64, iOS
  17.4 or later — and injecting one needs room in the Mach-O header, which Xcode builds have.
- **JIT** — the app is launched suspended under the device's debugger and resumed with the session
  held open, which is how iOS lets a process map executable memory. Keep SideInstaller running
  while you use the app.
- **Injectors** — ElleKit, CydiaSubstrate, libhooker and Substitute. ElleKit and Substitute can be
  fetched from where they're published (a repository `.deb` and a GitHub release); the other two are
  added from a copy you have. A package's dependencies — its `Depends` line, and the libraries it
  links — pick which one is loaded, and it's injected before the tweak.
- **Backup** — the whole configuration exports to JSON and imports again.

The archive is rewritten in place and only the files that change are re-encoded, so a 100 MB
`.ipa` costs a few megabytes of work. Applying the same configuration again is a no-op: the
identity is already set and the library is already loaded.

## Compatibility

| iOS | Is it compatible? |
| --- | --- |
| 27+ | ✅ Yes |
| 26.4 - 26.7 | ⚠️ Yes, but [a remote pairing file is needed](#ios-264-to-26x-a-remote-pairing-file), and that requires a PC |
| 17.4 - 26.3 | ⚠️ Yes, but [a pairing file is needed](https://docs.sidestore.io/docs/advanced/alternative#pairing), and that requires a PC |
| <17.4 | ❌ No |

### iOS 26.4 to 26.x: a remote pairing file

Since iOS 26.4, the iPhone hangs up on lockdown pairing files (from jitterbugpair,
`pymobiledevice3 lockdown pair`, or idevice_pair's **Lockdown**) as soon as they connect through
LocalDevVPN, so they can't be used on the iPhone any more, however new. A remote pairing (RPPairing)
file still works:

1. On a Mac, Windows PC or Linux computer, open [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases/latest)
   and plug the iPhone in. Tap **Trust** if it asks.
2. Pick the iPhone, choose **Remote pairing**, click **Create**, and keep the iPhone unlocked until
   it's done.
3. Click **Save to file…** and send the file to the iPhone by AirDrop, iCloud Drive or a cable.
4. In SideInstaller, tap **Import pairing file** (or **Replace**) and pick it.

A pairing file exported from [iLoader](https://github.com/nab138/iloader) (**Manage Pairing File** ›
**Export**) holds both kinds and works too.


## Is SideInstaller safe?

SideInstaller is built with safety and privacy in mind. The app is fully local and open source, which means
anyone can inspect exactly what it does.

**Your Apple credentials never leave your device.** They're used locally, only to sign and install your
  apps, and are never transmitted, logged, or collected in any way.

**No server, no analytics, no account.** Nothing is collected and there's nothing to sign up for.

**Fully auditable.** Every line of it can be verified in the source code.

> [!WARNING]
> All of the above is true of **this** repository and the builds published from it. It is **not** a guarantee
> that applies to forks, re-signed IPAs, or copies you find elsewhere, those can be modified to steal the
> Apple ID you type into them. If you didn't get it from
> https://sideinstaller.net/, don't trust it with your
> credentials.

## Project layout

| Path | What's in it |
| :-- | :-- |
| `ios-app/` | The SwiftUI app — UI, install engine, certificate handling, translations |
| `ios-live-activity/` | The widget extension that draws the pairing code in the Dynamic Island and on the Lock Screen |
| `rust-core/` | Rust core compiled into `SideInstallerFFI.xcframework` |
| `scripts/` | Build and release scripts |
| `.github/` | Workflows that build the unsigned IPA, publish it as a release and hand it to the signer |

Signed builds and the install page live in [FrizzleM/SideInstaller-Signed](https://github.com/FrizzleM/SideInstaller-Signed):
it signs each release's IPA with every certificate, attaches the signed IPAs to a release of its own and
deploys [sideinstaller.net](https://sideinstaller.net/). No IPA is ever committed to either repository.

## Contributing

Issues and pull requests are welcome. If you're reporting a bug, please include your iOS version, the app
version, and the step where it failed.

## License

See [LICENSE.md](LICENSE.md). In short: you may read, modify, and share the **source**, with attribution,
for non-commercial purposes. Redistributing the official builds (IPAs) or monetizing the project in any
form requires written permission.

<div align="center">

**SideInstaller by [FrizzleM](https://github.com/FrizzleM)**

</div>
