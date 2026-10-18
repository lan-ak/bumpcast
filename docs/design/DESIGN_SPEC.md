# BumpCast design spec

Goal: calming, trustworthy, educational. Audience: anxious and curious flyers.

**Product decision that overrides the mockups:** the app and notifications never name data sources (no NOAA, GTG or "global models"). Confidence is shown only with the labels "Advance forecast", "Partly confirmed" and "Confirmed forecast", plus a line like "Confirmed today around 7:15 PM" under the grade. The mockups and direction board use this wording. Trust comes from the confidence label, update times and honest wording, not from naming sources.

Visual references (private claude.ai links, owner: Lanre):
- Direction board: https://claude.ai/artifact/Gm2Bujg6Jc3DjNpNHNZk6J (source: `docs/design/bumpcast-design-directions.html`)
- Screen mockups + playable motion board: https://claude.ai/artifact/K7QM6J1aoCcyRmqCQJVEpp

## 1. The direction: three layers

| Layer | Source direction | What it means in code |
|---|---|---|
| System UI (tab bar, nav bars, sheets, menus) | Native iOS 27 Liquid Glass | Standard SwiftUI components only. No custom tab bar or nav chrome. |
| Mood (backgrounds, hero, calm tools) | "Cabin Dawn" | Time-of-day sky gradient behind content, large soft type, wave-line timeline on summary cards. |
| Proof (forecast detail) | "Flight Deck" | Confidence badge and update time on every forecast (no source names). Tabular numbers. Precise bar chart one level down. |
| Depth (explainers) | "Field Guide" | A "Why it's bumpy here" card per bumpy stretch, plus a Learn library. |

## 2. Tokens

Put these in one place (e.g. `ios/Shared/Theme.swift`) and use them everywhere, including widgets and the Live Activity.

### Severity colours (replace the current ones in `Models/Copy.swift`)

The current `Severity.severe` is system red, which reads as danger. Replace with:

| Severity | Light | Dark | Title (keep) |
|---|---|---|---|
| smooth | `#3A9A8F` | `#5CC0B3` | Smooth |
| light | `#C99A2E` | `#E0B54E` | Light chop |
| moderate | `#C9733A` | `#E38F55` | Moderate |
| severe | `#8E4A6B` (muted plum) | `#C57EA0` | Strong |

Rules: never use `.red`, warning triangles or exclamation symbols for turbulence. Colour is never the only signal; always pair with the title and the water-glass glyph.

### Other colours

- Ink `#15253A`, secondary ink `#45576C`, accent `#2A7385` (dark-mode accent `#6FBCCC`).
- Sky gradients by departure local time (used on Flights, Forecast, widget backgrounds):
  - dawn: `#F6D9C4 → #DFE3EC → #B9D0E6`
  - day: `#CFE3F3 → #E6EFF6 → #F4F7FA`
  - dusk: `#E7C3C9 → #C9BFD9 → #9FB0D0`
  - night: `#1B2A45 → #121D31 → #0B1322` (switch to light ink)
- Cards on the sky: white at ~60% opacity with a white hairline border (or `.regularMaterial`). Don't put glass on glass.

### Type

- Use SF Pro via Dynamic Type text styles (no custom fonts needed in the app; the mockups use Familjen Grotesk / Atkinson Hyperlegible / IBM Plex Mono as stand-ins).
- Headline grade: `.largeTitle.bold()`; uses short calm sentences ("A few bumps, mostly calm.").
- Route and times (`JFK → LAX · B6 23`, "Updated 6:41 AM"): `.footnote.monospaced()`.
- All numbers that change or line up: `.monospacedDigit()`.
- Must work at accessibility Dynamic Type sizes.

### Water-glass glyph (signature icon)

A tumbler outline whose water surface ripples more with severity: flat (smooth), small ripple (light), bigger ripple (moderate), choppy (strong); dashed empty outline = "too early to tell". Build it as a SwiftUI `Shape` taking a `Severity?`. Use it in: flight rows, "What to expect" rows, timeline legend, widgets, Live Activity, Dynamic Island compact/minimal, Watch.

## 3. Screens (see the mockup canvas)

1. **Flights** — next flight as a large card (route, time, water glass, grade, mini wave timeline, "Confirmed forecast · updated N min ago"). Then "Coming up" rows showing each confidence state (advance forecast with when it will be confirmed; too early with when the first forecast arrives). A Learn card. Tabs: Flights, Map, Learn + Calm as `Tab(role: .prominent)`.
2. **Forecast** — confidence badge, headline + one-sentence summary, three stat tiles (time in air, min of light chop, min of moderate), scrubbable timeline, "What to expect" rows (timing, severity + duration + phase, the `feelsLike` line), a "Why it's bumpy here" link on the main stretch, a "Practise breathing" button, and a footer with the confidence label, when it was updated and when it next updates (no source names). Use `toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)`.
3. **Explainer** — diagram, "What's happening", "What the crew is doing", "What you'll feel", a "Good to know" reassurance card, chips for other turbulence types. Saved for offline. Start with generic explainers; per-segment causes need a cause field from the worker (not built yet).
4. **Breathe** — night sky, breathing orb (4 s in, 6 s out), haptics toggle, "Light chop in about 6 min" heads-up from the forecast.
5. **Live Activity / Lock Screen** — "Smooth for 42 min", next stretch, route strip with plane position and bumpy stretches, Breathe + Full forecast buttons, "Saved before takeoff · confirmed forecast from …".
6. **Dynamic Island** — compact: glyph + minutes of smooth air left; landscape (`isDynamicIslandLimitedInWidth`): glyph + "42m" only; expanded: route strip + Breathe / "Why the next bumps?" buttons. **Watch Smart Stack / CarPlay**: `.supplementalActivityFamilies([.small])` layout. **StandBy**: `activityBackgroundTint` night sky.
7. **After landing** — "How did it feel?" Smoother / About right / Bumpier (a `LiveActivityIntent` button too). Store ratings; they're the calibration data the README calls for.

## 4. Motion

Rules: no bounce, no shake, no flashing; nothing faster than 0.35 s; use `.smooth` (critically damped) springs ~0.5–0.7 s. Every animation has a Reduce Motion fallback (`@Environment(\.accessibilityReduceMotion)`), normally a 0.3–0.4 s cross-fade.

| Moment | Spec | Reduce Motion |
|---|---|---|
| Open a flight | `.navigationTransition(.zoom(sourceID:in:))` with `.matchedTransitionSource` on the card; detail content fades/slides 14 pt after 0.3 s | System handles it; content fades only |
| Forecast reveal | Timeline line draws takeoff→landing over 1.4 s (mask/trim), bumpy bands tint as the line passes, then headline and rows stagger in (0.15 s). First open per forecast only. | Chart fades in, no draw |
| Advance → Confirmed forecast | Bars go from 0.4 opacity to 1 and to new heights in a left-to-right sweep (~15 ms stagger, 0.7 s each); badge `symbolEffect(.replace)`; score `contentTransition(.numericText())`; one soft haptic when it settles | Opacity change only, no sweep |
| Forecast changed | Changed stretches glow once (one `PhaseAnimator` cycle) | Static highlight |
| Map route | Great-circle line draws origin→destination; bumpy stretches tint as it passes | Appears at once |
| Breathe | Orb scale 0.8→1.08 on inhale (4 s), back on exhale (6 s), `TimelineView(.animation)`; slow sky drift | Glow (opacity) instead of scale; haptic stays |

## 5. Haptics

Soft, sparse, optional. Respect the system haptics setting and an in-app toggle.

| Moment | Haptic |
|---|---|
| Breathing guide | Core Haptics continuous event, intensity 0.1 → 0.6 over the inhale, back to 0.1 over the exhale; low sharpness. The most important haptic in the app. |
| Scrubbing the timeline | `.sensoryFeedback(.selection, trigger: severity)` only when crossing into a different severity |
| "What will light chop feel like?" (opt-in) | Gentle irregular transient pattern, intensity ≤ 0.4. Never offered for moderate/strong. |
| Forecast confirmed / flight added | `.sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5))` |
| Forecast got bumpier | None. Bad news arrives quietly, in words. |

Never use `.warning` or `.error` feedback for turbulence.

## 6. iOS 27 features (WWDC26)

- Liquid Glass refresh comes from building with the iOS 27 SDK; keep chrome native (session 251, 269).
- Live Activities: landscape Dynamic Island, StandBy tint, `.small` family for Watch/CarPlay, `LiveActivityIntent` buttons (session 223).
- Foundation Models on-device works in airplane mode: "Ask about this bump" answers only from the stored forecast + explainer library via tool calling. It explains; it never predicts or changes a forecast (sessions 241, 242).
- Siri/Spotlight: flights as `IndexedEntity`, App Schemas, annotate the forecast screen ("How bumpy is my flight to LA?") (sessions 240, 343).
- Accessibility: timeline as an adjustable control (VoiceOver swipes step through stretches and read "3 h 40 min in, light chop for 8 minutes"), plus a Swift Charts audio graph (session 220).

## 7. Copy and trust rules

Do: show the confidence label and update time on every forecast; say what we don't know (advance forecast, out of coverage, too early); lead with timing and duration; explain what the crew is doing.
Don't: name data sources (NOAA, GTG, global models) anywhere in the app or notifications; show raw EDR on the main screens; imply certainty the data doesn't support; send night-time notifications for small changes.
Keep the existing calm wording in `Models/Copy.swift`; extend it rather than replacing it.

## 8. App icon: "Calm line"

Mockup: the "App icon" row on the screens canvas (link at the top of this file).

**Idea.** One small bump that settles into a long, level line, which is the shape of a good forecast. The line is also the horizon: the sun rises behind it and still water lies below. The line runs off the right edge, so the calm continues past the frame.

**Never:** a plane, lightning, a second bump, jagged or choppy lines, or severity colours (amber, orange, plum, red) on the line. It is always a sunrise, never a sunset.

### Geometry (1024 × 1024 master; the system applies the corner mask)

| Element | Spec |
|---|---|
| Sky | Fills the canvas above the horizon, vertical gradient |
| Horizon / water | Horizon at y = 604 (59%). Water fills everything below it, vertical gradient |
| Sun | Circle, centre (655, 604), r = 154. Drawn behind the water, so only the top half shows |
| Reflections | Two round-capped strokes, 15 px: x 573–737 at y 686, and x 614–696 at y 737, 70% opacity. Hide at 60 pt and below |
| Line | `M133 604 C215 604 246 502 317 502 S420 604 502 604 L1085 604`, stroke 51 px (5%), round caps and joins. The bump is 102 px tall (10%) and sits in the left third; the line runs past the right edge |
| Small sizes | 60 pt: stroke 6%. 40 pt and below: stroke 7%, no reflections |

### Colours by appearance

| | Sky (top → bottom) | Water (top → bottom) | Sun | Line |
|---|---|---|---|---|
| Default | `#F6D9C4 → #DFE6EF` | `#A9C6E2 → #7FA6CC` | `#FFF3E8` at 95% | `#1F5F6E` |
| Dark | `#1B2A45 → #2C4262` | `#13203A → #0B1322` | `#F2D8B8` at 85% | `#8FD7E0` |
| Tinted | Let the system tint it: provide the line, the sun outline and the reflections as one monochrome layer |
| Clear | Let the system generate it from the layers below |

### Icon Composer layers (top to bottom)

1. **Line**: solid, with no glass effect, so it stays crisp.
2. **Reflections**: solid, hidden at small sizes.
3. **Sun**: glass layer with translucency on.
4. **Background**: the sky and water gradients.

Export the `.icon` file into `ios/BumpCast/` and point the app's icon setting at it. The widget extension uses the same icon.
