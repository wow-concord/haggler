# Haggler

A gold-making add-on for WoW: Forever (Interface 16001) covering crafting, selling and bags.

Prices from [AHledger](https://ahledger.com).

## Status

Build step 5 of 8, plus prices through `AHledgerAPI`. Done so far:

- The host layer and the engine core (step 1).
- The AH scan, own-sales counting, price rules and item tooltips (step 2).
- Item value, bag badges and totals, and trade window values with a loss warning (step 3).
- The Haggler window: Scan, Lookup, Rules, Sell and Buy tabs (step 4).
- Crafting on the profession frame, ventures, cost pools, auction and mail tracking, and the full ledger (step 5).

Settings are changed with `/hag`; there is no settings panel yet.

- **Value**: an item is worth its rule price after the 5% AH cut and the deposit risk, and never less than the vendor price.
- **Bags**: badges show items to vendor and values that are guesses, with an optional value per button and a bag total. Works in Blizzard bags, BagPad 1.4.0, Bagnon 12.1.8 and Baganator 846, whichever is loaded.
- **Crafting**: each recipe row in Blizzard's profession window shows profit and margin; the selected recipe gets cost, value, the known versus estimated share and confidence, plus a Plan venture button in dev builds (V2). Held reagents cost what they would sell for, or what you paid (cost pools).
- **Ventures** (V2, dev builds only): a venture runs from plan to the last copper in the mail, closes by itself when everything has sold or by hand (leftovers written off or moved to stock), and is never deleted.
- **Ledger**: posts, deposits, sales, the AH cut, refunds, buys, vendor trades, crafts and destroys are booked as they happen; the Ledger tab shows session profit, profit per day, the sell log and purchases.
- **Trade**: shows a value per slot and a total per side, plus a warning when you give more than you get beyond the convenience fee. In confirm mode, the Trade button needs a second click. Friends and guild members get their own policy. Completed trades go to the ledger.

## Layout

| Path | What it is |
| --- | --- |
| `Host/` | Haggler's own host layer, shaped like Concord's API: `AddModule`, `Provide` / `Get`, the bus, settings schemas and the generated `/hag` commands |
| `Host/Tokens.lua` | Generated from the Concord design system by `tools/sync-design.sh`; do not edit |
| `Engine/` | UI-free: the WoW API wrapper, saved data and migrations, the price source (AHledger), calculation rules and price steps, item value, trade verdicts and the ledger |
| `Host/BagHosts/` | One adapter per bag add-on (Blizzard, BagPad, Bagnon, Baganator), detected at runtime |
| `Features/` | One module per feature: pricing, value, scan, tooltip, bags, trade, tracking, crafting, the window and its tabs |
| `media/icons/` | Icon atlases generated from the Concord design system by `tools/sync-design.sh`; do not edit |
| `v2/` | V2 features kept out of the release: Flips and Ventures (engine and tabs). The dev TOC loads them; the release package leaves them out |
| `Haggler.lua` | Bootstrap: opens the saved data on `ADDON_LOADED` and starts the host |
| `tests/` | luajit specs |

## Price data

Haggler requires the [AHledger](https://ahledger.com) add-on (`## Dependencies: AHledger`). Market prices come from AHledger's public, read-only `AHledgerAPI` (v1), which AHledger's own sync app keeps fresh. Haggler still reads every full AH scan itself, for listing depth and its own sales count.

- Prices go through one swappable source in `Engine/PriceData.lua` (`Status`, `Row`, `Table`); the AHledger source is the default, and another source with the same shape can replace it.
- When AHledger only has the copy bundled with the add-on (`snapshot`), prices carry a confidence reason, as old data does.
- The client does not load Haggler without AHledger. When AHledger is there but Haggler cannot use it (an API version Haggler does not read), Haggler says once in chat that it needs AHledger. When AHledger's calls fail or it has no prices for the player's market, prices come from Haggler's own scans with low confidence, and the reason is shown.
- When AHledger is set to another market than the one the player is on, Haggler keeps its own market, says so once in chat, and AHledger prices carry a note.
- The tooltip closes with AHledger's credit line when a price shown used AHledger's figures.

## Development

```bash
luacheck -q .
```

```bash
stylua --check .
```

```bash
luajit tests/run.lua
```

`tests/run.lua` runs the specs twice: on the dev file set, then on the release set without `v2/` (`--v1`), where V2 specs and `t.v2test` tests are skipped.

## V1 release scope

Flips and Ventures are V2 (decided 2026-11-18). Their code lives in `v2/` and stays in the repo, but the release zip leaves it out:

- `.pkgmeta` ignores `v2`, and `Haggler.toc` lists the `v2\` files inside `#@do-not-package@` blocks, which the BigWigs packager strips from the release TOC.
- V1 code never needs V2: `Engine/VentureRecords.lua` reads saved ventures (for the migration) and sets `Ventures.hasPlanner = false`; `v2/Engine/Ventures.lua` adds the planner. Without it the Flips and Ventures tabs, the top bar's Flips shortcut and the Plan venture button are absent, and saved ventures, ledger `ventureId`s and their settings are kept as they are.

To build the release zip locally and check its file list, from a clean checkout with the [BigWigs packager](https://github.com/BigWigsMods/packager)'s `release.sh`:

```bash
release.sh -d
```

```bash
unzip -l .release/Haggler-*.zip | grep -E 'v2/|Flips|Ventures|do-not-package'
```

```bash
unzip -p .release/Haggler-*.zip Haggler/Haggler.toc | grep -E 'v2|do-not-package'
```

Both greps should print nothing.

Before a release, run the in-game check suite (`/hc`, see [dev/README.md](dev/README.md)) on the release build until `node dev/read-check-results.ts --version <release version>` reports green.

To refresh the design tokens from the Concord design system:

```bash
tools/sync-design.sh
```

## Credits

Prices from [AHledger](https://ahledger.com). Their data is free for personal and community use with this linked credit.

## Third-party

Roboto Condensed 2.137, Copyright 2011 Google Inc., Apache License 2.0, media/fonts/LICENSE-RobotoCondensed.txt

Bundled libraries and their licences are listed in Libs/LICENSES.md.
