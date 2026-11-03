# iPhone Duo layout rules

One set of rules for every BumpCast screen on the iPhone Duo. The layout engine (`DuoSpread` in
`ios/BumpCast/Views/DuoLayout.swift`) applies them; `DuoAuditTests` checks every screen, state and
fold position against them. A screen never lays itself out for the Duo.

## 1. One screen, one list

- A screen lists its content once, in the order the iPhone shows it.
- One container (`AdaptiveSpread`) shows that list as the iPhone's stack on an iPhone or a closed
  Duo, and as a spread on the open Duo. Screens contain no Duo checks.
- The iPhone, and the closed Duo, are unchanged by any of this.

## 2. Roles belong to the component

Each component says once, where it's defined, where it goes on a spread:

| Role | Components | Fully open | Partly open |
|---|---|---|---|
| leading | route header and its notes, list controls, official warning | left column, top | left column, top |
| trailing | grade card, minute tiles | right column, top | right column, top |
| wide (the default) | timeline, in-flight, landing, cancelled, diverted, notifications, anything new | full width | shorter column |
| pair | stretch cards | two to a row, equal heights | shorter column |
| heading | "What to expect" | full width, above its cards | with its first card |
| flow | breathing, footer, updates, Coming up, Learn card | shorter column | shorter column |

Leading and trailing views form the top band; everything else follows in list order.

## 3. Space

- One spacing token (`DuoSpacing.rows`, 8 pt) between any two views, across and down.
- Columns meet at the screen's middle when fully open, and stop at the fold's band when partly open.
- Partly open there are no gaps: each column stacks on its own, in reading order (the top band
  first, then the rest).
- Flowing cards always go to the column that's shorter at the time; with flowing cards in both
  columns, the columns end within one card of each other. A column of pinned views alone (say the
  "No flights" card) can be taller than what flows beside it.

## 4. Never

- Anything in the fold's band (40 pt) when it's live.
- Text cut off: every view gets at least the height it needs at the width it's given.
- Labels on top of each other (the timeline picks its hour marks to fit).
- Covering system chrome: the status and tab column (84 pt, right), the bottom inset (34 pt), or
  Apple's Maps attribution.

## 5. Two-pane screens

Learn (list and explainer), Calm and breathing have a phone layout and two panes when open; the
container decides which. Learn's panes fill the screen's height and scroll on their own; Calm's and
breathing's are centred on each other. The fold, overlap and edge rules apply to them; the list
rules (no gaps, minimum heights) don't, since a scrolling pane scrolls and centring leaves space by
design. The map uses its wide chrome whenever the screen is wide, and keeps its
status card clear of the fold and the attribution.

## 6. The iPhone doesn't change

Every rule above applies on the open Duo only. On an iPhone, and on the closed Duo's outer screen,
the app is pixel for pixel what it was before the Duo work. `ios/scripts/iphone-parity.sh` checks
this: it renders every iPhone screen and state (Flights, each flight state and route type, the map
and its offline cards, Learn, Calm, breathing, the sheets, the onboarding fallback and the offline
states) in an earlier commit and in the working tree, on an iPhone 17 Pro, an iPhone SE and the
closed Duo's screen, at the default text size and AX3, and diffs each pair.

    PRO_UDID=<iPhone 17 Pro> SE_UDID=<iPhone SE> ios/scripts/iphone-parity.sh [base-ref]

Both trees build without secrets, so neither can reach production. The base is rendered twice: what
two renders of the same code differ by (Liquid Glass buttons, an animation's phase, clock text) is
the noise. A case fails when the working tree differs from the base by clearly more than that, and
the failures are listed in `flagged.tsv`. Run it after dark or in daytime, not across 5 PM, 8 PM or
5 AM: the app's sky follows the hour, and a render either side of a change differs everywhere.
