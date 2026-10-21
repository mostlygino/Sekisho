# Security

Sekisho sits between your apps and the network. It makes a certificate authority that can sign for any
host, decrypts the HTTPS you ask it to, and can switch the macOS proxy. Security reports are welcome and
taken seriously.

## Reporting a vulnerability

Please report privately through GitHub: **Security > Report a vulnerability** on this repository (a private
security advisory). Do not open a public issue for a vulnerability.

Include what you found, how to reproduce it, and the Sekisho version (Sekisho > About Sekisho, the build line
has a copy button). You will get a reply on the advisory; fixes ship as a new release.

## What is in scope

- The certificate authority: its private key leaving `~/Library/Application Support/Sekisho` (0600 in a 0700
  folder), being readable by other users, or certificates Sekisho signs being usable outside this Mac's trust.
- The listener: anything on the network reaching it while "Allow phones and other devices" is off, network
  clients reaching this Mac's own services through it when it is on, or Sekisho serving public addresses.
- Request smuggling or header injection through edited requests, breakpoints, scripts, Map Remote or the
  upstream proxy (CR/LF, invalid hosts or methods reaching the wire).
- Upstream TLS: a server with an untrusted or wrong certificate being accepted.
- The macOS proxy: Sekisho leaving it pointed at itself after quitting, crashing or being killed.
- Crashes, hangs or memory blow-ups from crafted traffic, sessions or HAR files.
- The upstream proxy password leaving the Keychain.

## Verifying downloads

Release assets come with SHA-256 sums, and detached GPG signatures (`.sig`) from the release key
`4C49 B6E8 DC9F 50C8 0A1A 20B8 05BE 68B6 158B 9E08`, which is also in this repository at
`Resources/release-key.asc`.

```sh
gpg --import Resources/release-key.asc
gpg --verify Sekisho-0.1.0.dmg.sig Sekisho-0.1.0.dmg
```
