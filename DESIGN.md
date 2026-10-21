# Sekisho design

Product truth is in `PRODUCT.md`; the shared craft standard is [`docs/design/APP_DESIGN.md`](docs/design/APP_DESIGN.md).
This file holds Sekisho's own visual system. Chosen 2026-10-19 by Gino from the five icon options: **Tsūhyō** (通票),
replacing the earlier "Seinhuis" signal-box world.

## Direction: the single-line tablet

On a single-track line only one train may be in a section, and the driver proves it by holding the tablet: a turned
brass disc with a cut-out shape, handed over at the signal box in a leather pouch. It is the railway's own checkpoint
pass, and Sekisho is a checkpoint for traffic.

Quiet edition (2026-10-19, Gino: "too heavy, more fitting macOS 27"): the leather sidebar, stitching and screwed
brass plate are gone. The world now lives in the icon, the accent and two small brass objects; everything else is
macOS.

1. **Brass is what you can act on.** The accent (buttons, switches, selection, focus) is brass, and so are the
   objects that carry the metaphor: the numbered rule tablets and the tablet in the welcome walk. Nothing else is brass.
2. **The chrome is macOS.** Glass sidebars that follow the appearance, glass toolbar, system controls and
   headings in the label colour. The proxy address sits in a small glass capsule at the sidebar's foot.
3. **The work stays calm.** Table and inspector sit on near-system neutrals with a little warmth.
4. **Data keeps its own colours.** Status dots and intervention colours are information, not theme, and survive any
   reskin. Colour is never alone: the code, symbol or word is always there.

## Colour

Contrast ratios are WCAG, computed against the grounds below.

| Token | Light | Dark | Use | Ratio |
|---|---|---|---|---|
| `Color.brass` | `#7A5A1E` | `#D9AE5C` | brass text: links, JSON keys, marks | ≈5.6 on ground / ≈9 on dark |
| `Color.brassFill`, AccentColor | `#8A6420` | `#8A6420` | prominent buttons, selection, switches | white label 5.35; 3.5 vs dark ground |
| `Color.ground` | `#F6F4F0` | `#1B1917` | window ground | |
| `Color.raised` | `#FCFBF9` | `#221F1D` | inspector panes | |
| `Color.rule` | `#E4E0D8` | `#36322E` | hairlines | |
| `Color.engraving` | `#2A1C0E` | same | numbers cut into brass tablets | 7.6 on brass |

Status dots: 2xx green `#1E8A5A`/`#3DB27A`, 3xx slate `#6B7785`/`#8D99A8`, 4xx amber `#B87F00`/`#E2A400`, 5xx and
failures red `#C8352B`/`#E5533F`, an empty ring while waiting.
Interventions: hold, block, abort red; Map Local amber; Map Remote blue `#2C66B8`/`#5B93E0`; edits and repeats neutral.

## Materials

- **Brass:** a top-left-lit gradient with a bevel stroke (white above, dark below); tarnished grey-brown when off.
  Only on the tablets.
- **Glass:** system Liquid Glass for sidebars, toolbar and the address capsule.
- `Resources/leather.jpg` stays in the repo for the icon renderer (`--texture`); the app no longer ships it.

## Type

System faces (Operate surface). SF Pro for the interface, SF Mono for data: sizes, durations, raw messages, hex,
JSON, the proxy address. Tabular numerals in numeric columns.

## Components

- `RecordControl`: a red record dot and "Recording" (with the in-flight count as a small number), or a pause sign and
  "Paused" in secondary. Not the tablet: its triangle read as a play button, the opposite of what it meant.
- `TabletPlate`: a numbered brass disc with a small enamel ring in the tool's colour; tarnished when the rule is off.
  Used for rules in Tools and the steps of the empty state.
- `ProxyStatus`: status dot and address in a glass capsule.
- `StatusDot`: as above.

## Motion

One authored moment: in the welcome walk the tablet rides the single-track line to the station you are at
(exponential ease-out, no bounce; off with Reduce Motion). The record control swaps its symbol with the system's
replace effect. Rows appear without animation.

## Welcome walk

`Welcome.swift`, on first launch and from Help > Welcome to Sekisho. Five stations on a vertical single-track line
(rails and sleepers in `Color.rule`, passed stations ringed in brass with a check). Each station does the real thing
and checks it live: the certificate's trust, the first request arriving, the first decrypted request (the aha
moment, shown as a row with its app). Skip at every station; shown once (`welcomeSeen`).

## Icon

Tsūhyō, rendered by `scripts/make-icon.swift` (the Kagami/Kekkai renderer core, same window). The four other options
stay in `docs/brand/` with their sheets; see its README.

## Screenshots

`defaults write dev.mostlygino.sekisho appearance dark|light` forces an appearance (delete the key to follow the
system).
