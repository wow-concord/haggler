# Haggler dev tools

Dev-only. `.pkgmeta` leaves this folder out of the release zip.

## Haggler_Check: the in-game check suite

`Haggler_Check/` is a separate add-on that watches Haggler while you play and judges the steps 4–6 checklist itself where it can. It reads only Haggler's saved tables, named frames, LDB objects and client events, plus `hooksecurefunc` post-hooks. It never calls into Haggler, never replaces a Blizzard function and never touches a secure frame.

Link it into the client once, from the repo root:

```bash
ln -s "$PWD/dev/Haggler_Check" "/Applications/World of Warcraft/_forever_/Interface/AddOns/Haggler_Check"
```

In game:

- `/hc` toggles the checklist. Its top line names the next thing to do and where (town, mailbox, auction house, then combat). Click a row to see what to do and the evidence so far. Pass, Fail and N/A buttons show on look items and on any item the suite could only judge as a look; a verdict you set there can be changed again.
- `/hc reset` starts a fresh run. The old run is kept as `<run> #n`.

A run is keyed by Haggler's version and the client build, so a new build starts a new run. A fail sticks for the rest of the run. Items marked `once` (client capabilities) are answered once and carried into later runs until a reset.

With Concord_Check v1 (`ConcordCheck.VERSION == 1`), the items also register through `ConcordCheck.RegisterProbes`; each Concord judge reports the verdict this suite recorded (N/A shows as a pass marked `n/a`). Each recorded result is also logged as an INFO line, so the host re-judges at once. When the host refuses the registration, each result goes to `ConcordCheck.Log` as PASS or FAIL instead. A look answered in Concord's panel is recorded here as a player verdict, so this reader goes green without a second answer in `/hc`. A host with `ConcordCheck.FEATURES.onAnswer` hands the answer over. With an older host, the answer is read from `ConcordCheckDB` when the host judges. Each stored answer is taken once, so a later `/hc` verdict wins until you answer in Concord again. Answers from before a `/hc reset` are not taken. Any other version is left alone. The panel stays either way.

Read the run after a `/reload` or logout. The reader exits 0 only when every item passed or was marked N/A:

```bash
node dev/read-check-results.ts --version 0.1.0
```

`--version` is optional; with it the reader is green only when the current run is of that Haggler version. With several WoW accounts, also pass the account folder name or the full path to `Haggler_Check.lua`.

Typecheck the reader (one-time `npm install` in `dev/`):

```bash
npm --prefix dev install && npm --prefix dev run check
```

`tests/haggler_check_spec.lua` covers the suite, the judges, the observer and the checker under luajit.

## Where each checklist item is checked

The checklist is "Combined in-game checklist, steps 4–6" in the step 5 handover. Its sub-checks fall into three groups:

- **a, spec**: proven outside the game, so the run leaves them out. There are 19 sub-checks, one per clause in the column below: rows 2, 5, 7, 15 and 17 have one each, 10 and 16 three each, 6 and 8 four each.
- **b, judged**: `auto` and `action` items the suite judges from Haggler's state. There are 28 (5 auto, 23 action).
- **c, look**: items that need eyes. There are 8.

Provenance's probes (0, 8, 17, 18, 19) are not repeated here.

| # | Checklist item | a, spec | b, judged in game | c, look |
| --- | --- | --- | --- | --- |
| 1 | `/reload` clean; window tabs | | `load.clean`, `client.error-hook` | `window.tabs` |
| 2 | Bar widgets, drag, widget off | widget off: topbar_spec "switching a widget off takes it off the bar" | `bar.position` | `bar.look` |
| 3 | Visibility market / hidden | | `bar.visibility` | |
| 4 | Rule widget; prices follow | | `bar.rule` | `bar.rule-prices` |
| 5 | Shortcuts | the tab opened: topbar_spec "a shortcut opens the window on its tab" | `bar.shortcuts` | |
| 6 | Focus binding, combat | pad focus, B leaves, in-combat binds, freed keys: topbar_spec 159–258 | `focus.bind`, `client.override-query`, `focus.combat`, `focus.combat-bind` | `focus.pad` |
| 7 | LDB feed | feed-off tooltip: topbar_spec "with the feed off the launcher tooltip offers no clicks" | `feed.objects` | `feed.display` |
| 8 | Session modes | every mode, Reset, the alt's mode: sessions_spec; today rolls over: checklist_moved_spec | `session.reload`, `session.relog` | |
| 9 | Step 5 town items (ventures: V2, not checked) | | `craft.book`, `vendor.book`, `bags.destroy` | `craft.look` |
| 10 | Mail: sold, expired, won; full bags; new mail; two posts | full bags, new mail mid-take: tracking_spec 238, 257; two posts: books_spec 95 | `mail.take`, `mail.fullbags`, `mail.newmail`, `ah.twoposts` | |
| 11 | Scan completes | | `ah.scan` | |
| 12 | Lookup, Sell, Buy | | | `ah.flows` |
| 13 | Flips | not checked: Flips is V2 (decided 2026-11-18) | | |
| 14 | Flips Buy | not checked: Flips is V2 (decided 2026-11-18) | | |
| 15 | Auctions tab advice | advice moves after a scan: checklist_moved_spec | | `auctions.look` |
| 16 | Cancel to relist | arm, second click, greyed away: trade_tabs_spec 242 | `ah.cancel` | |
| 17 | Cancel untracked | trade_tabs_spec 333–416 | `ah.untracked` | |
| 18 | Post, cancel, expiry, commodity, undercut; AH-visit start | | `ah.post`, `ah.undercut`, `ah.commodity`, `session.ahvisit` (expiry: `mail.take`) | |
| 19 | `/reload` persists | | `persist.data` (sessions: `session.reload`; bar: `bar.position`) | |

Items 10, 16 and 17 are proven by specs and also judged in game. The in-game run catches a client that behaves differently from the fake one.

## Known limits

- `mail.newmail` assumes 50 or fewer mails in the inbox. The client lists only the first 50, so new mail beyond them goes unseen.

## Engine hook points

None needed. Every judge reads `HagglerDB`, `HagglerCharDB`, the named frames (`HagglerTopBar`, `HagglerFrame`, `HagglerInputButtonN`), the client's `SettingsPanel` and its current category, the LDB objects, client events and post-hooks. `HagglerOptionsPanel` exists only on the legacy options fallback; `bar.shortcuts` accepts either it or the Settings window open on Haggler.
