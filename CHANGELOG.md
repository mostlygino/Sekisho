# Changelog

All notable changes to Sekisho. Versions follow [semantic versioning](https://semver.org).

## 0.1.2 beta, 2026-10-21

- **Tablet marks**: the command palette, the welcome walk, the decrypt panel and About now show the brass tablet
  from the new app icon instead of a flat disc. Paused or off, it tarnishes.

## 0.1.1 beta, 2026-10-21

- **New app icon**: the brass single-line tablet on saddle-stitched oxblood leather, redrawn to the standard of
  the other mostlygino apps. README banners and the social preview carry it too.

## 0.1.0 beta, 2026-10-19

The first beta. Everything below is new; expect rough edges and please report them.

- **Proxy**: HTTP and HTTPS on 127.0.0.1:9090, built on SwiftNIO. HTTPS is decrypted only for the hosts you
  list, with Sekisho's own certificate authority (made on this Mac, trusted only when you say so); everything
  else passes through as an encrypted tunnel. WebSockets, with their messages.
- **See**: every request with the app that sent it, filter chips, sorting, highlights and comments, pinned apps
  and hosts; an inspector with headers, query, body (pretty JSON in its own key order, tree, text, hex, HTML
  preview), forms, cookies, auth (Basic, JWT), raw and timings.
- **Change**: breakpoints on requests and responses, Map Local (text, file or folder), Map Remote, scripting
  (JavaScript), Block and Allow lists, DNS spoofing, network conditions, no caching, reverse proxy, upstream proxy.
- **Repeat and compose**: Repeat, Edit and Repeat, Compose with cURL paste and history, Compare two requests,
  Copy as cURL, HTTPie, Python, fetch, axios, URLSession or Go.
- **Data**: sessions, HAR import and export.
- **Devices**: phones and other devices on your network (off by default), certificate install in iOS Simulators.
- **Welcome walk** on first launch (and from Help > Welcome to Sekisho): trust the certificate, send traffic
  through, pick hosts to decrypt, each checked live until your first decrypted request shows up. Skippable.
- **⌘K** command palette, a demo mode (`-demo YES`), DMG and Installer package downloads.
- **Licence**: code under the GNU Affero General Public License, version 3 or any later version; the name,
  icon and artwork are reserved ([BRAND.md](BRAND.md)). The app carries its licence and those of the packages
  built into it.
