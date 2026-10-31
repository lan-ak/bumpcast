# Stat tiles and the water glass (draft, for Lanre's review, Oct 31)

Two small changes to the forecast screen. Both are app updates; nothing changes in the worker.

## 1. Stat tiles: Smooth, Light chop, Moderate or strong

**Why.** "In the air" repeats the flight length that the status line and the timeline already show, and it locks a number anyone can look up. Strong minutes are counted inside "Moderate" without saying so. The new tiles add up to the whole flight, so the proportion is easy to see, and the first number a nervous flyer reads is the calm time.

**Where.** `StatTiles.exactTiles` in `ios/BumpCast/Views/ForecastView.swift` (around line 284).

### Counts (unchanged method: samples from the plane's minute on)
- `smooth` = samples where severity == .smooth
- `light` = samples where severity == .light
- `strongish` = samples where severity >= .moderate (as today)
- `strong` = samples where severity == .severe

### Tiles, left to right

| Tile | Value | Title on the ground | Title in the air |
|---|---|---|---|
| 1 | `smooth.durationText` ("3 h 36 min", or "0 min") | Smooth | Smooth ahead |
| 2 | "\(light) min" | Light chop | Light chop ahead |
| 3 | "\(strongish) min" | Moderate, or **Moderate or strong** when `strong > 0` | Moderate ahead, or **Moderate or strong ahead** |

- **Strong sub-line.** When `strong > 0`, tile 3 gets one more line under its title: "\(strong) min strong" in `.bcCaption`, coloured `Theme.color(.severe)` (muted plum). It's the only colour on any tile. No icon, no symbol. When `strong == 0` the line isn't there and the tile reads exactly as today.
- **Wrapping.** "Moderate or strong ahead" may wrap to two lines in a third of a small phone; that's fine, because the tiles already share one height (`fixedSize(vertical:)`). The value stays on one line (`minimumScaleFactor(0.7)` as now).
- **The time tile goes from the exact layout.** "Left to fly" is removed too; the in-flight card's landing line already shows it.
- **Locked.** Unchanged behaviour: all three show the lock and the "00 min" stand-in. Update the hint to "Unlock to see minutes of smooth air and turbulence".
- **VoiceOver.** Each tile combines as now, e.g. "12 minutes, Moderate or strong, 4 minutes strong".
- **Accessibility sizes.** They stack vertically as now.

### Outlook routes (no exact minutes): no change
`outlookTiles` keeps the time tile ("In the air" / "Left to fly") and "Bumps possible". Without minutes for each level there is no honest Smooth count.

## 2. Water glass: neutral outline, colour only in the water

**Why (tester feedback).** The glass is the container and the water is the reading. When the outline takes the severity colour, the whole glass reads as the grade. A neutral outline keeps the glass constant, so only the water changes. It also reads better for colour-blind users, because the shape stays the same and the surface bumps carry the level.

**Where.** `ios/Shared/WaterGlass.swift`.

- The `GlassShape` stroke changes from `color` to `Theme.secondaryInk` (#45576C light, #B7C3D0 dark). Width is unchanged.
- The water fill (`color.opacity(0.55)`) and the surface stroke (`color`, 1.3× line) stay in the severity colour.
- **Too early (nil severity):** the dashed outline also uses `Theme.secondaryInk`, so it matches.
- **Night skies.** Forecast cards on dark skies already force the dark appearance, so they get #B7C3D0. If a card on a night sky resolves to light, use `Theme.ink` as on that card's text.
- **Sizes.** At 26 pt (Global Outlook rows, the smooth-ahead line) the neutral outline must still be visible. If 1.2 pt looks faint there, raise the minimum line to 1.4. Check in the simulator.
- Update the file's comment: severity colours go on the water only; the outline is neutral ink, still never the brand teal.

## House rules check
- Uses no red or warning symbols, and no new haptics.
- Severity colours appear only where they mean severity: the water, and the plum "min strong" line.
- The glass is still an indicator, not a logo.

## Also update
- `docs/design/DESIGN_SPEC.md`: the tile names and the glass outline rule.
- **App Store and CPP screenshots** (`docs/release/creative/`) show the old tiles and glass. Refresh them in the next screenshot pass; this doesn't block the release.
- **Learn page:** nothing changes. "Strong" is already explained there.

## Check before shipping
1. Flight with smooth air only: the tiles read "4 h 10 min · 0 min · 0 min", with no strong line.
2. Flight with light and moderate: tile 3 reads "Moderate" with no sub-line.
3. Flight with strong: tile 3 reads "Moderate or strong" with "4 min strong" in plum.
4. In the air, partway through: the "… ahead" titles, and the counts drop as minutes pass.
5. Locked: three lock tiles and the new hint.
6. Global outlook route: unchanged.
7. Glasses at every size in light, dark and night sky, including the too-early dashed glass.
