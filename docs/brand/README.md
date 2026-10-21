# Sekisho brand

**Brief.** Sekisho helps a developer stop, read and change HTTP traffic on its way through, represented by the
single-line tablet: the brass pass a driver must hold to enter a section, the railway's own checkpoint pass.
Chosen by Gino on 2026-10-19; the app is themed after it (DESIGN.md).

| Option | Object | Meaning | Silhouette | Materials | Colour | Signature detail | Honest risk |
|---|---|---|---|---|---|---|---|
| Shingō 信号機 | Colour-light signal at night | Proceed / hold, the status lamps of the app | Black board, white border, one green lamp | Painted steel, Fresnel glass | Proceed green | Hooded lenses, the lit one throwing green onto the board | Can read as a traffic light rather than a checkpoint |
| Teko 梃子 | Signal lever | The tools: pull to change traffic | Red bar leaning out of a slot | Red enamel, polished steel, brass | Lever red on frame green | Brass plate with its number, worn paint, spring catch | Thin at 16 px; red, not the product green |
| Heisoku 閉塞器 | Block instrument | The record control (LINE CLEAR) | Round dial in a square case | Mahogany, brass, vitreous enamel, glass | Green sector, needle on it | Needle and counterweight casting on enamel under glass | Close to a generic gauge |
| **Tsūhyō** 通票 (chosen, in the app) | Single-line tablet | The pass a driver must hold to enter a section | Brass disc with a triangle cut out | Turned brass, cowhide, linen thread | Brass on leather | Triangle (第三種) cut-out, engraved 関所 通票, saddle stitching | Reads as a coin to anyone outside railways |
| Tegata 手形 | The traveller's pass | The checkpoint itself: shown, read, stamped | Pale tablet on indigo | Hinoki, sumi, seal paste, silk, hemp | Seal red, green cord | 通 in sumi, 改 (inspected) cut out of the vermilion seal | Literal reading of the name; close to Kekkai's Japanese world |

Characters: 通 (pass through), 改 (inspected), 関所 (checkpoint), 通票 (tablet), from Hiragino Mincho ProN W6 as outlines.
`7` on the lever plate is the same font. No SF Symbols (their licence excludes app icons). All decorative text
disappears below 128 px by design (`Detail` in the renderer: `.glyph` up to 64 px, `.mark` up to 160, `.full` above).

## Provenance and export

**Since 2026-10-21 the app icon is a generated image**, not this renderer's output: the Tsūhyō tablet from [PROMPT.md](PROMPT.md), rendered with an image generator to the standard of Onmitsu and Kuro. `sekisho-icon-master.png` is the original, `sekisho-icon.png` the same object fitted to an 860 px body on a 1024 canvas, which feeds `Resources/AppIcon.icns`. The renderer below still makes the option sheets; the brand sheet comes from `brand_sheet.py` (text and colours in `brand-sheet.json`, laid out like the renderer's sheet, drawn by headless Chromium).

Procedural, no generated imagery: `scripts/make-icon.swift`, whose core (tokens through `softShadow`) is Kekkai's
renderer unchanged; one window high left, height fields, marched shadows, analytic room reflections.

```sh
swiftc -O scripts/make-icon.swift -o /tmp/sekisho-icon
/tmp/sekisho-icon /tmp/Sekisho.iconset --variant tsuhyo --brand docs/brand   # ~20 s
iconutil -c icns /tmp/Sekisho.iconset -o Resources/AppIcon.icns
/tmp/sekisho-icon /tmp/x --preview /tmp/prev [--only <id>]                    # 512 px previews, ~1 s
```

Each icon-set size is rendered natively at twice its size (min 256, max 2048) and scaled down; sizes 16, 32, 128,
256, 512 at 1x and 2x. Files: `sekisho-icon.png` (the one in the app), `sekisho-icon-<id>.png` (1024),
`sekisho-sheet-<id>.png`, `sekisho-options.png`.
