# Name, icon and artwork

Sekisho's **source code** is free software under the [GNU Affero General Public License, version 3 or any
later version](LICENSE) (AGPL-3.0-or-later).

The **Sekisho name and its brand assets are not covered by that licence.** They stay © 2026 Gino de Graaff
(mostlygino), all rights reserved:

- the name "Sekisho" and "関所" used as the name of this app;
- the app icon (Tsūhyō 通票, the single-line tablet) in `Resources/AppIcon.icns`, and the other icon options in
  `docs/brand/`;
- the mostlygino seal in `Resources/mostlygino.png`;
- the leather texture in `Resources/leather.jpg`;
- the images in `docs/brand/` and `docs/screenshots/`;
- the DMG and installer artwork that `scripts/make-installer-art.swift` draws (the script itself is AGPL code,
  as are `scripts/make-icon.swift` and `docs/brand/readme_art.py`).

You're welcome to show them when you write about, review or link to Sekisho. If you **fork** Sekisho and
distribute your fork, give it a different name and icon, so people can tell the two apart: replace
`Resources/AppIcon.icns` and `Resources/mostlygino.png`, and change the name and bundle identifier in
`Info.plist`. The code is yours to use under the AGPL either way.

## Third-party software

Compiled into the app, all under the Apache License 2.0 (their licence and notice files ship in
`Sekisho.app/Contents/Resources/Licenses`):

- [SwiftNIO](https://github.com/apple/swift-nio), [SwiftNIO SSL](https://github.com/apple/swift-nio-ssl) (which
  includes BoringSSL, under the OpenSSL and ISC licences listed in its notice),
  [swift-certificates](https://github.com/apple/swift-certificates), [swift-crypto](https://github.com/apple/swift-crypto),
  [swift-asn1](https://github.com/apple/swift-asn1), [swift-atomics](https://github.com/apple/swift-atomics),
  [swift-collections](https://github.com/apple/swift-collections) and [swift-system](https://github.com/apple/swift-system).

The demo session in `docs/demo/` is synthetic: documentation hosts and addresses only.
