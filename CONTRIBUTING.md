# Contributing to Sekisho

Thanks for wanting to help. Sekisho is a small, opinionated Mac app, so a short conversation before a large
change saves everyone time: open an issue first for new features or big refactors. Bug fixes, tests and
documentation can go straight to a pull request.

## Build and run

You need macOS 26 on Apple silicon and Xcode 26 (the Command Line Tools alone lack the SwiftUI macros).

```sh
./make-app.sh                 # builds build/Sekisho.app
open -n build/Sekisho.app --args -demo YES   # a recorded session; touches no settings, keychain or proxy
swift test                    # the engine, end to end through a live proxy on 127.0.0.1
scripts/check.sh              # the tests, then a release build
```

`scripts/install.sh` builds and copies the app into /Applications. The demo flags (`-demoAppearance`,
`-demoWindow`, `-demoSelect`, `-demoShot`) are described in `Sources/SekishoApp/Demo.swift`.

## Where things live

| Path | What |
|---|---|
| `Sources/SekishoCore` | The proxy engine on SwiftNIO: CONNECT and TLS interception, the certificate authority, rules and tools, scripting, sessions and HAR. No UI. Tested. |
| `Sources/SekishoApp` | The SwiftUI and AppKit app. |
| `Tests/SekishoTests` | XCTest suites; most run curl through a real proxy against local fixture servers. |
| `scripts/` | Build, install, icon, installers and releases. |
| `docs/demo/` | The synthetic demo session (`SEKISHO_MAKE_DEMO=1 swift test --filter DemoSession` regenerates it). |
| `DESIGN.md`, `PRODUCT.md` | The visual system and what Sekisho is for. Read them before UI work. |

## Ground rules

- **No real traffic in the repository.** Sessions, HAR files and fixtures must be synthetic: `example.com`,
  `example.net`, `example.org`, documentation addresses (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24,
  2001:db8::/32). No real tokens, cookies or hostnames.
- **Engine changes get a test.** Anything in `SekishoCore` comes with a test in `Tests/SekishoTests`. Tests
  stay on this Mac: local fixture servers, never the internet.
- **Match the surrounding code.** Swift 5 language mode, the comment density and naming of the file you are
  in, and the tokens in `DESIGN.md` for anything visible (no new colours, no new fonts).
- **British English** in the interface and docs. Interface text is plain and specific: say what happened
  and what to do next.
- **Security matters here.** Sekisho holds a certificate authority that can sign for any host. Keep its key
  private (0600, never exported), keep the listener on 127.0.0.1 unless the user turns on network devices,
  and keep the macOS proxy restore path intact. See `SECURITY.md`.

## Pull requests

1. Fork, branch from `main`, keep the change focused.
2. `swift test` passes locally; CI runs it and builds the app.
3. Describe what changed and why; add a screenshot for visible changes (light and dark when colours change).
   `-demo YES` gives you something to show without your own traffic.

By contributing you license your work under AGPL-3.0-or-later, the licence of this repository. There is no
contributor licence agreement. The name, icon and artwork are not open for contributions; see
[BRAND.md](BRAND.md).
