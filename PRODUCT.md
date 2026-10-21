# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI, AppKit where SwiftUI falls short). Apple's Human Interface Guidelines for macOS govern structure, navigation and controls. Target: the current macOS release with its Liquid Glass design language; minimum macOS 26 (same as Kagami).

## Stack

Swift Package: `SekishoCore` (the proxy engine on SwiftNIO, swift-nio-ssl and swift-certificates) and the `Sekisho` SwiftUI app. Network.framework cannot start serving TLS on a socket after `CONNECT`, which is why the engine uses NIO.

## Users

Same audience as Kagami: Mac developers debugging an API, a web app or a native app, and security or Trust & Safety people who need to see what an app (or a suspicious sample) actually sends. They know HTTP, headers and TLS; many know Proxyman, Charles or Burp, and want something that feels like a Mac app.

## Product Purpose

Sekisho (関所, the Edo-era road checkpoint where every traveller was stopped and inspected) is an HTTP(S) debugging proxy. It sits between apps and the network, records every request and response, decrypts HTTPS for the hosts you choose with its own local certificate authority, and lets you stop, rewrite, redirect, replay or block traffic. Success: someone points an app at Sekisho and reads the exact request and response they care about within a minute, then changes it without leaving the app.

## Positioning

A native, open-source Proxyman-style proxy for the Mac. HTTPS is only decrypted for hosts on the SSL Proxying list; everything else passes through untouched and is shown as a tunnel. Upstream certificates are checked against the Mac's trust store, so a broken or hostile server is reported instead of hidden behind Sekisho's own certificate.

## Capabilities

- Records HTTP and HTTPS (SSL Proxying list), CONNECT tunnels, WebSocket upgrades (passed through).
- Inspector: headers, body (JSON, text, image, hex), raw, query, cookies.
- Tools: SSL Proxying (with exclusions), Allow List, Block List, Breakpoints, Scripting (JavaScript, Proxyman's
  onRequest/onResponse shape), Map Local (text, file, folder), Map Remote, DNS Spoofing, Network Conditions, No Caching,
  Reverse Proxy, upstream proxy.
- Compose (cURL paste, history), Repeat, Edit and Repeat, Compare, Copy as code (cURL, HTTPie, Python, fetch, axios,
  URLSession, Go), HAR import/export, sessions (.sekisho).
- Groups traffic by app (the process that opened the connection) and by domain.
- Its own root CA, created on first launch, private key 0600 in Application Support; trusting it and switching the system proxy are explicit user actions.

## Constraints

- Listens on loopback by default. "Allow phones and other devices on my network" (Settings, off by default, with a
  warning) binds every interface and serves only loopback and private addresses.
- Never changes the system proxy or trust settings without a click; restores the previous system proxy state on quit.
- Distribution like Kagami: code AGPL-3.0-or-later with the name, icon and artwork reserved (`BRAND.md`), GitHub `mostlygino/Sekisho`, DMG and Installer package releases.

## Relation to siblings

Kagami (packet viewer) and Kekkai (app firewall) are the sibling apps by the same author; each has its own visual world. Sekisho's name was briefly Kekkai's working name (2026-10-18); they are different apps.
