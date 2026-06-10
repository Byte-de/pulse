# Byte Pulse — Design System

Native macOS 26 (Tahoe) menu bar app. Status item → floating Liquid Glass panel with
provider tabs (Claude / Codex / Cursor / Gemini) and usage cards.

This document is the single source of truth for visual + motion design. Every value is
concrete and intended to be transcribed 1:1 into `DesignSystem.swift`. Platform API
feasibility for everything referenced here is verified in
`docs/RESEARCH/swiftui-macos26.md` (compiled on this SDK).

**Design philosophy, in one paragraph.** This is a glanceable productivity surface that
people open dozens of times a day. Per Emil Kowalski: animations must stay under 300 ms,
use ease-out for anything entering, and frequent/keyboard-triggered actions get *less or
no* animation ("an animation would make them feel slow… You should never animate them" —
[emilkowal.ski/ui/you-dont-need-animations](https://emilkowal.ski/ui/you-dont-need-animations)).
Per Jakub Krehel: "The best animation is that which goes unnoticed" — exits subtler than
enters, `bounce: 0` as the production default, tabular numerals so digits never shift
([jakub.kr/writing/details-that-make-interfaces-feel-better](https://jakub.kr/writing/details-that-make-interfaces-feel-better)).
If a reviewer *notices* an animation in this app, it is probably too slow or too big.

> Sourcing note: Emil's rules below come from his published essays (cited inline).
> Jakub Krehel's written record is thinner — his SwiftUI-grade interaction craft lives
> mostly in video posts on X ([x.com/jakubkrehel](https://x.com/jakubkrehel)); the rules
> attributed to him here are synthesized from his essays on
> [jakub.kr](https://jakub.kr/) (notably *Details That Make Interfaces Feel Better*,
> *Animating Icons*), the community distillation in
> [kylezantos/design-motion-principles](https://github.com/kylezantos/design-motion-principles)
> (`references/jakub-krehel.md`), and Apple HIG where his record is silent. Treat those
> as "Krehel-style", not verbatim quotes, unless quoted.

---

## 1. MOTION TOKENS

Transcribe as `enum Motion` of named `Animation` values. All motion animates **transform
(scale/offset) + opacity + blur only** — never window frames, never layout-affecting
properties (Emil: "animate with transform and opacity as they only trigger the composite
step" — [emilkowal.ski/ui/great-animations](https://emilkowal.ski/ui/great-animations);
also `docs/RESEARCH/swiftui-macos26.md` §7: "Never animate the NSWindow frame").

### 1.1 Token table

| Token | SwiftUI value | What it animates | Notes |
|---|---|---|---|
| `panelIn` | `.snappy(duration: 0.24, extraBounce: 0.06)` | scale `0.96 → 1.0` anchored `.top`, opacity `0 → 1`, offset y `-8 → 0`, optional blur `4 → 0` | Origin-aware: grows out of the status item (Emil: "the dropdown to animate from where the button is. This feels natural" — [emilkowal.ski/ui/good-vs-great-animations](https://emilkowal.ski/ui/good-vs-great-animations)). Never start from scale 0; 0.9+ only (Emil tip 2 — [emilkowal.ski/ui/7-practical-animation-tips](https://emilkowal.ski/ui/7-practical-animation-tips)). Window appears at final frame; only content animates. |
| `panelOut` | `.easeIn(duration: 0.14)` | opacity `1 → 0`, scale `1 → 0.97` anchor `.top`, offset y `0 → -4` | Exit ≈ 60% of enter duration and *less* movement (Krehel: "Exits always subtler than enters"). Completion-driven: `orderOut` in `withAnimation(...) completion:` with `.logicallyComplete`. |
| `tabPill` | `.snappy(duration: 0.25, extraBounce: 0)` | `matchedGeometryEffect` pill behind active tab | Zero bounce — this is chrome, not a toy (Krehel: "`bounce: 0` is production default"). |
| `tabContentIn` | `.easeOut(duration: 0.18)` | incoming card stack: opacity `0 → 1`, offset x `±12 → 0` | Direction = `sign(newIndex - oldIndex)`: moving to a higher tab index slides content in from +12 (right), lower index from −12. Ease-out for entry (Emil tip 4). |
| `tabContentOut` | `.easeIn(duration: 0.12)` | outgoing stack: opacity `1 → 0`, offset x `0 → ∓8` | Exits faster, smaller travel (8 pt vs 12 pt). Use an `.asymmetric` transition. |
| `numberTick` | `.smooth(duration: 0.25)` + `.contentTransition(.numericText(value: x))` | every changing numeral (%, tokens, cost, "30s ago") | Krehel's fluid-ticker feel via the system primitive. Pair with `.monospacedDigit()` everywhere so width never changes (Krehel: "use tabular-nums… prevents number shift during updates"). |
| `gaugeFill` | `.spring(duration: 0.5, bounce: 0)` | progress bar fill width / gauge trim | Fires on appear (0 → value) and on every data change. **Never bounce a progress bar** — overshoot on a "how much is left" meter reads as wrong data (Krehel `bounce: 0`; Emil: functional data displays "should avoid [decorative] animation" — good-vs-great-animations). |
| `chartDrawIn` | `.easeOut(duration: 0.4)` | line chart: opacity `0 → 1` + y-scale settle; bars: height `0 → value` | Once per panel-open or tab-switch, not on refresh ticks. |
| `chartBarStagger` | `chartDrawIn.delay(Double(i) * 0.03)` | per-bar delay, index 0…6 | 30 ms stagger → last bar starts at 180 ms, total well under 300 ms (Emil's ceiling). Krehel staggers sections; we compress his web-scale 100 ms to 30 ms for a utility panel. |
| `hover` | `.easeOut(duration: 0.12)` | hover overlay opacity, control tint | `ease` is fine for hover-type fades (Emil, good-vs-great-animations); keep it almost instant. |
| `press` | `.easeOut(duration: 0.10)` down, `.snappy(duration: 0.2, extraBounce: 0)` release | scale `1 → 0.97` on press, back on release | Emil tip 1: "Use `scale(0.97)` on active for press feedback". The springy release makes it interruptible/squishy without bounce. |
| `iconSwap` | `.smooth(duration: 0.2)` + `.transition(.blurReplace)` | trend arrow flips, refresh icon → checkmark, status dot color | Krehel: "Animating opacity, scale and blur on icons when they are shown contextually makes the transition feel better" ([jakub.kr/components/animating-icons](https://jakub.kr/components/animating-icons)). `.blurReplace` is the native macOS 26 equivalent (verified ✅). |
| `refreshPulse` | `.easeInOut(duration: 0.8)`, runs **once** per successful fetch | footer status dot opacity `1 → 0.35 → 1` | Confirmation, not decoration. Never loop while idle — a menu-bar app must not burn frames in the background. Timestamp text itself updates via `numberTick`. |
| `staleTint` | `.easeInOut(duration: 0.3)` | footer/status colors crossfade to amber/red | Color-only change; no movement. |

### 1.2 Motion rules (enforce in code review)

1. **Exits are always faster and travel less than enters.** `panelOut` 0.14 s vs
   `panelIn` 0.24 s; tab-out 0.12 s/8 pt vs tab-in 0.18 s/12 pt. (Krehel: "Exits use less
   movement than enters; users are moving on"; his exit recipe uses fixed `-12px`, not
   full-height — details-that-make-interfaces-feel-better.)
2. **Everything under 300 ms.** Longest token is `chartDrawIn` at 0.4 s, allowed only
   because it is passive scenery, runs once, and never blocks input. All interactive
   feedback ≤ 250 ms (Emil: "UI animations should generally stay under 300ms"; "180ms
   select feels more responsive than 400ms" — you-dont-need-animations, tip 6).
3. **Never bounce data.** `bounce`/`extraBounce` = 0 on gauges, charts, numbers, the tab
   pill. The only sanctioned bounce is `panelIn`'s 0.06 — felt, not seen. (Krehel:
   reserve `bounce > 0` for playful contexts; this is not one.)
4. **Keyboard-triggered actions get reduced motion.** ⌘1–4 / ←→ tab switching skips the
   directional slide entirely: pill `matchedGeometry` + plain 0.12 s crossfade only.
   (Emil: "never animate keyboard initiated actions… an animation would make them feel
   slow" — great-animations.)
5. **Transform + opacity + blur only.** No animated `frame`, `padding`, or
   `statusItem.length` (status item width changes are made *rare* via monospaced digits
   instead of animated — RESEARCH §1). Wrap cards in `.geometryGroup()` so reflow never
   tears.
6. **Origin-aware.** Panel anchors `.top` (status item). Card hover/press scales anchor
   `.center`. Tooltips/popovers anchor toward their trigger (Emil tip 5: default
   `center` transform-origin "is usually incorrect").
7. **Interruptible by construction.** Springs retarget with preserved velocity; if
   `show()` is called mid-hide, the same `withAnimation` path retargets smoothly and the
   hide-completion is guarded (`if !state.isPresented`) — RESEARCH §7. Never gate input
   on an animation finishing.
8. **Respect Reduce Motion.** Read
   `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (observe
   `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`). When true: replace
   every token that moves/scales with `.easeInOut(duration: 0.15)` opacity crossfade,
   disable `chartBarStagger`, `refreshPulse`, and `.numericText` (numbers snap). (Emil:
   "Animations can make people feel sick" — great-animations; HIG: accessibility
   settings "can remove or modify certain effects".)
9. **Don't re-animate on every poll.** The 30 s refresh updates numbers via `numberTick`
   and gauge via `gaugeFill` *only when values actually changed*; charts do not redraw-in
   on refresh. Frequent events get the smallest possible motion (Emil: consider "how
   often the user will see it").
10. **Blur is a tool, not a default.** 2–4 pt blur only where a crossfade looks rough
    (`.blurReplace` icon swaps, optional panel enter). (Emil tip 7: "2px blur… bridges
    the visual gap"; Krehel: "Blur→sharp = entering focus".)

---

## 2. COLOR TOKENS

Source of truth is always the **semantic system color** (`NSColor.system*`,
`.labelColor` family, `.separatorColor`) so dark mode, vibrancy, increased-contrast and
"Reduce transparency" come for free (HIG Color: "use dynamic system colors as intended…
don't use the separator color as a text color" —
[developer.apple.com/design/human-interface-guidelines/color](https://developer.apple.com/design/human-interface-guidelines/color)).
Hex values below are the canonical macOS light/dark resolutions for reference only —
never hardcode them; resolve via `NSColor`.

### 2.1 Semantic palette — TWO appearance palettes (amended post-v1.0 review)

One semantic token per role, resolved per appearance via
`NSColor(name:dynamicProvider:)` (`PulsePalette` in DesignSystem.swift):
**dark mode keeps the original vivid system colors** (designed for dark
surfaces, ≥4.5:1 there); **light mode switches to Apple's accessible palette**
(HIG Color → Specifications) because the vivid colors fall to ~2:1 on the
light popover material. Call sites never pick an appearance — only a meaning.

| Token | Light (accessible) | Dark (original) |
|---|---|---|
| `ok` | `#248A3D` | `systemGreen` (`#32D74B`) |
| `warn` | `#B25000` | `systemYellow` (`#FFD60A`) |
| `warnStrong` | `#C93400` | `systemOrange` (`#FF9F0A`) |
| `critical` | `#D70015` | `systemRed` (`#FF453A`) |
| `info` | `#0040DD` | `systemBlue` (`#0A84FF`) |

The old "yellow fills / orange text" special case is obsolete: the accessible
amber is text-grade, so `threshold()` serves both fills and text.

### 2.2 Gauge thresholds (5-Hour Session & Weekly Limit)

Driven purely by **level** (pace is a separate signal, §2.3):

| Used fraction | Color | Meaning |
|---|---|---|
| `0 ..< 0.50` | `ok` (green) | comfortable |
| `0.50 ..< 0.80` | `warn` (yellow fill / orange text) | watch it |
| `0.80 ... 1.0` | `critical` (red) | nearly out |
| `== 1.0` (exhausted) | `critical` fill + label "Limit reached" | out |

Color changes crossfade with `staleTint` (0.3 s); thresholds are exact (`<`, not
fuzzy bands), so the gauge color is deterministic and testable.

### 2.3 Pace colors

`pace = usedFraction / elapsedFraction` of the window (e.g. 60% used at 50% elapsed
→ 1.2).

| Pace | Token | Badge text |
|---|---|---|
| `≤ 1.0` | `ok` | "On pace" |
| `1.0 ..< 1.5` | `warnStrong` | "1.3× pace" |
| `≥ 1.5` | `critical` | "1.8× pace" |

Pace below 0.05 with elapsed < 10% shows neutral (secondary text, "—") to avoid noisy
red flashes right after a window resets.

### 2.4 Trend arrows — INVERTED semantics (codify this!)

In Byte Pulse, the delta being displayed is **usage**, so *rising is bad*:

| Direction | Symbol | Color |
|---|---|---|
| Usage **up** vs previous period | `arrow.up.right` | `critical` (red) |
| Usage **down** | `arrow.down.right` | `ok` (green) |
| Flat (|Δ| < 1 pt) | `minus` | `Color.secondary` |

This matches the reference screenshot and is the **opposite of finance-style arrows**.
⚠️ The compiled snippet in `docs/RESEARCH/swiftui-macos26.md` §1 (line ~51,
`up ? Color.green : Color.red`) has these *backwards* — do not copy it. Centralize in
one function: `func trendColor(delta: Double) -> Color { delta > 0 ? .critical : .ok }`
so the semantics can never fork per-view.

### 2.5 Provider accents

Single flat accents (no gradients) chosen to read on both light and dark glass. Used
for: status-item dots, tab dot, chart/bar fallback tint, "Open <Provider>" hover tint.

| Provider | Token | Hex | Rationale |
|---|---|---|---|
| Claude | `accentClaude` | `#D97757` | Anthropic terra-cotta/"Crail" coral (brand ~`#DA7756`, [beginswithai.com Claude brand](https://beginswithai.com/claude-ai-logo-color-codes-fonts-downloadable-assets/)). Works on both appearances. |
| Codex (OpenAI) | `accentCodex` | dynamic: light `#4A4A4F`, dark `#D8D8DC` | OpenAI's brand is strictly monochrome; a fixed gray dies on one appearance, so the accent is an appearance-adaptive "ink" (teal-free per spec). Implement as a dynamic `NSColor(name:)`. |
| Cursor | `accentCursor` | `#8C7CCD` | Muted violet sampled from the Cursor app-icon palette ([colorswall #111759](https://colorswall.com/palette/111759)); Cursor's official chrome is black/white ([cursor.com/brand](https://cursor.com/brand)), so the violet is our differentiator — desaturated enough to sit on glass. |
| Gemini | `accentGemini` | `#4285F4` | Google blue; the 2025+ Gemini mark is a 4-color gradient — as a single accent, Google blue is the recognizable, glass-safe pick. |

Accent usage rule: accents identify *providers*, never *state*. State (good/bad) is
exclusively §2.1 semantics, so a red Claude dot can never be confused with a critical
gauge.

### 2.6 Chart colors

| Token | Value |
|---|---|
| `rateLineAbove` (burning faster, > 0) | `critical` line 1.5 pt; area fill `critical.opacity(0.16)` → `0.03` vertical gradient |
| `rateLineBelow` (under baseline, < 0) | `ok` line 1.5 pt; area fill `ok.opacity(0.16)` → `0.03` |
| `rateZeroLine` | `Color.primary.opacity(0.15)`, 1 pt `RuleMark` at y = 0 (the only "gridline") |
| `barFill(day)` | quota-relative: `dayTotal / (weeklyLimit / 7)` → `< 0.8` `ok`, `0.8 ..< 1.2` `warn`, `≥ 1.2` `critical`; bars at `opacity(0.85)`, today at `1.0` |
| `barFill` fallback (no known limit) | provider accent, opacity `0.35 + 0.65 × (value / weekMax)` |
| `modelRowBar` | provider accent at `opacity(0.8)`, track `Color.primary.opacity(0.07)` |

### 2.7 Surfaces, hairlines, text on glass

Panel chrome is **one** Liquid Glass surface (`NSGlassEffectView`, `.regular`, no tint).
HIG: use the *regular* variant for "components [that] have a significant amount of
text, such as alerts, sidebars, or popovers", and "use Liquid Glass effects sparingly…
limit these effects to the most important functional elements"
([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)).
Therefore **cards are NOT glass-on-glass** — they are flat tinted plates on the glass:

| Token | Value |
|---|---|
| `cardFill` | `Color.primary.opacity(0.045)` |
| `cardFillHover` | `Color.primary.opacity(0.085)` (≈ +4% overlay) |
| `hairline` | `Color(nsColor: .separatorColor)` (≈ black 10% / white 10–15%), 1 px, also the panel's edge stroke (re-resolve in `updateLayer()` — RESEARCH §3) |
| `pillFill` (active tab) | `Color.primary.opacity(0.09)` |
| `trackFill` (progress/bar tracks) | `Color.primary.opacity(0.08)` |
| `textPrimary` | `.primary` — values, titles, big % |
| `textSecondary` | `.secondary` — units, column headers, axis labels, inactive tabs |
| `textTertiary` | RETIRED (post-v1.0 accessibility pass): `.tertiary` is ~2:1 and reserved by Apple for disabled/placeholder content. ALL informational captions — axis labels, "Updated 30s ago", tags, hints — use `.secondary` (≥4.5:1 on the panel material in both modes). |

Card borders: hairline only, **no card shadows** — on vibrancy glass, shadows muddy the
material; the native Tahoe look is fill + hairline. (Krehel prefers shadows over borders
*on varied web backgrounds*; on uniform system glass the hairline is contextually
correct — his own rule is "context drives [the choice], not templates".) The panel
itself keeps the system `NSWindow` shadow (`hasShadow = true`).

Never put `secondaryLabel`-style colors behind text or redefine semantics (HIG Color).
Text on glass must always be the label hierarchy — vibrancy needs it for legibility.

---

## 3. TYPE & SPACING

### 3.1 Type scale

SF Pro (system font) only; macOS has no Dynamic Type, and HIG macOS floors at 10 pt for
body content (default 13 pt) —
[HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
**Every numeral in the app uses `.monospacedDigit()`** (Krehel: tabular numbers prevent
shift; also our anti-jitter strategy in the status bar, RESEARCH §1).

| Role | Spec |
|---|---|
| Big gauge % ("42%") | `system(size: 22, weight: .semibold).monospacedDigit()`, `.primary` |
| Card titles ("5-Hour Session") | `system(size: 13, weight: .semibold)`, `.primary` |
| Tab labels | `system(size: 12, weight: .semibold)`; active `.primary`, inactive `.secondary`. Same weight for both states — weight flips change width and jiggle the pill. |
| Table numerals / body values | `system(size: 12, weight: .regular).monospacedDigit()`, right-aligned |
| Table row labels / model names | `system(size: 12)`, `.secondary` |
| Column headers, captions, "resets in 2h 14m", pace badge | `system(size: 11, weight: .medium)`, `.secondary` |
| Footer "Updated 30s ago" | `system(size: 11)`, `.tertiary` |
| Bottom-bar buttons | `system(size: 12, weight: .medium)` |
| Chart axis labels (±30%) | `system(size: 9, weight: .medium).monospacedDigit()`, `.tertiary` |
| Menu bar % (per provider row) | `system(size: 9, weight: .semibold, design: .rounded).monospacedDigit()`, `.foregroundStyle(.primary)` |
| Menu bar provider code ("CL") | `system(size: 7, weight: .bold)`, uppercase, tracking `+0.5`, `.secondary` |
| Menu bar trend arrow | SF Symbol at `7pt, .bold` |

**Menu-bar legibility note (verify on hardware).** The menu bar is 24 pt tall
([HIG The Menu Bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar));
two 9 pt rows with `spacing: 0` fit (cap height ≈ 6.4 pt — RESEARCH §1, "don't exceed
~10pt per row"). 7 pt code letters sit **below the HIG 10 pt minimum** — this is the
accepted dense-menubar convention (iStat Menus / Stats ship 7–9 pt) and is mitigated by:
bold weight, uppercase 2-letter codes, +0.5 tracking, `.primary`/`.secondary` dynamic
colors, and the colored provider dot carrying identity redundantly. Keep 6.5 pt as the
absolute floor; prefer 7 pt. Offer a Settings toggle for a one-row compact mode
(single provider) as the legibility escape hatch. Full-color hosting view opts out of
template-image auto-tinting — test on light and dark wallpapers (RESEARCH §1 caveats).

### 3.2 Spacing & geometry

4 pt base grid. Concentric-radius law everywhere: **innerRadius = outerRadius − inset**
(Tahoe's core geometry principle; `ConcentricRectangle`/`.containerShape` implement
exactly this — [nilcoalescing.com/blog/ConcentricRectangleInSwiftUI](https://nilcoalescing.com/blog/ConcentricRectangleInSwiftUI/);
Krehel states the same formula for the web: "outer radius = inner radius + padding").

| Token | Value |
|---|---|
| `panelWidth` | **360 pt** fixed |
| `panelRadius` | **20 pt**, continuous curve (native Tahoe popover range is ~16–26 — RESEARCH §3; set via `NSGlassEffectView.cornerRadius`) |
| `panelPadding` (edge → content) | **10 pt** |
| `cardRadius` | **10 pt** = 20 − 10, continuous (`ConcentricRectangle` or `.rect(cornerRadius: 10, style: .continuous)`) |
| `cardPadding` (inside cards) | **12 pt** |
| `cardGap` (between cards) | **8 pt** |
| `gaugePairWidth` | two cards side-by-side: (360 − 2×10 − 8) / 2 = **166 pt** each |
| `tabBarHeight` | **28 pt** container; capsule container radius 14; pill inset 2 pt → pill radius 12 (concentric) |
| `bottomBarHeight` | **36 pt**, separated by hairline |
| `panelGap` (status item → panel) | **6 pt**; screen-edge margin 8 pt (RESEARCH §2) |
| `progressBarHeight` | **5 pt**, capsule |
| `statusItemHPadding` | 4 pt each side; intrinsic width (never animated) |
| Shadows | panel: system window shadow only. Cards/controls: none. |

Vertical stack (top → bottom): tab bar · 8 · [Session ∥ Weekly] · 8 · Usage Rate · 8 ·
Daily Usage · 8 · Token Usage · 6 · footer caption · 8 · hairline · bottom bar.
Expected panel height ≈ 560–600 pt; see §5.5 for overflow.

Optical alignment beats geometric: SF Symbols next to text get manual `baselineOffset`
/ 0.5 pt nudges where needed; icon-leading buttons reduce icon-side padding by 2 pt
(Krehel: "Trust visual judgment over mathematical centering").

---

## 4. COMPONENT SPECS

### 4.1 Status-bar label (per-provider block)

Two-row block per provider (up to 2 providers shown; more → Settings picks):

```
● CL 42% ↗      ← row: dot(5pt, accent) · 2pt · code(7pt bold, .secondary) · 2pt
● CX 77% ↘         · pct(9pt semibold mono, .primary) · 2pt · arrow(7pt bold, trend color §2.4)
```

- Rows `spacing: 0`, block `.fixedSize()`, `hitTest → nil` click-through
  (RESEARCH §1, verified).
- `%` animates via `numberTick`; arrow swaps via `iconSwap`; dot turns `warnStrong`
  amber when that provider's data is stale (§4.9), gray `.tertiary` when not connected.
- Provider blocks separated by 8 pt. Status item highlight on while panel is open
  (`button.highlight(true)`).

### 4.2 Tab bar (provider switcher)

- 4 equal-width segments in a capsule track (`trackFill`), height 28 pt.
- Active segment: `pillFill` pill via `matchedGeometryEffect(id: "tab-pill")`, animated
  with `tabPill`. Label: 5 pt provider-accent dot + 12 pt semibold name.
- Inactive labels `.secondary`; hover on inactive segment: text → `.primary` with
  `hover` (0.12 s), no background change (the pill is reserved for selection).
- Content below switches with `tabContentIn`/`tabContentOut` directional slide;
  keyboard switching crossfades only (Motion rule 4).

### 4.3 Gauge cards — "5-Hour Session" / "Weekly Limit"

166 × ~110 pt cards, side by side. Internal layout (12 pt padding, 6 pt row gaps):

1. Title row: 13 pt semibold title + spacer + trend arrow (8 pt bold symbol) with
   delta caption (11 pt, trend color): `↗ +12%`.
2. Value row: 22 pt semibold mono `42%` + trailing pace badge.
3. Progress bar: 5 pt capsule, track `trackFill`, fill = threshold color (§2.2),
   fill animates `gaugeFill`, min visible fill 5 pt (never a 0-width sliver when > 0).
4. Caption row: 11 pt `.secondary` "Resets in 2h 14m" (relative, `numberTick` on the
   minutes) + spacer + 11 pt `.tertiary` absolute "at 18:00".

Pace badge: capsule, text 10 pt semibold in pace color, background pace-color
`opacity(0.12)`, padding 6 h / 2 v. Texts: "On pace" / "1.3× pace" (§2.3).

### 4.4 Usage Rate card (line chart)

- Title row as §4.3 (no pace badge).
- Plot: Swift Charts `LineMark` + `AreaMark`, `.interpolationMethod(.catmullRom)`,
  height **56 pt**, `chartXAxis(.hidden)`, legend hidden.
- Split coloring at y = 0: above-zero segments `rateLineAbove` (red = burning faster),
  below `rateLineBelow` (green) — §2.6. Zero line is the only rule mark.
- Y axis: exactly two trailing labels `+30%` / `−30%` (9 pt mono `.tertiary`),
  `AxisGridLine` disabled — minimal axes, no grid (data, not dashboard cosplay).
- Draw-in: `chartDrawIn` once per open/tab-switch; live refresh mutates points with
  `.smooth(0.25)`, no re-draw-in (Motion rule 9).

### 4.5 Daily Usage card (7 bars)

- `BarMark` per day, corner radius **3 pt** (tops; `.cornerRadius(3)` verified ✅),
  bar width ≈ 24 pt, plot height **64 pt**.
- Color per §2.6 intensity mapping; today at full opacity, past days 0.85.
- X labels: weekday initials 9 pt `.tertiary`; no y axis at all — bars + tooltip-on-hover
  (hover shows 11 pt mono value above bar after 300 ms initial delay; subsequent bars
  instant — Emil tip 3: "Don't delay subsequent tooltips").
- Draw-in: heights 0 → value with `chartBarStagger` (30 ms × index).

### 4.6 Token Usage card (table + model breakdown)

- Grid: label column left-aligned + 2 numeric columns (**Today**, **This Month**)
  right-aligned. Rows: Input · Output · Cache · Cost. Row height **22 pt**.
- Headers 11 pt medium `.secondary`; numerals 12 pt regular `.monospacedDigit()`,
  right-aligned so magnitudes scan vertically; Cost row formatted `$12.34` (mono).
- Hairline row separator only under the header row, `hairline` at 50% opacity.
- Compact notation for big numbers: `1.2M`, `845K` (one decimal max).
- Model breakdown (below, 8 pt gap, "By model" 11 pt header): per row —
  model name 12 pt `.secondary` (truncate middle) · 3 pt `modelRowBar` capsule
  (relative %) · trailing 11 pt mono % `.secondary`. Max 4 rows + "+3 more" tertiary row.
- Percent values tick with `numberTick`; bars animate `gaugeFill`.

### 4.7 Footer + bottom bar

- Footer line: status dot (5 pt, `ok` green) + "Updated 30s ago" 11 pt `.tertiary`,
  left-aligned; trailing ghost refresh button (`arrow.clockwise` 11 pt, `.secondary`).
  Manual refresh: icon → progress spinner (≥ 500 ms so it never flickers) → `iconSwap`
  to checkmark for 800 ms → back. Dot pulses `refreshPulse` once per auto-fetch.
- Bottom bar: 36 pt, hairline on top. `Open Claude` (provider-aware label) left ·
  spacer · `Settings` · `Quit` right. Text buttons 12 pt medium `.secondary`;
  hover → `.primary` + `cardFillHover` capsule behind (padding 8 h / 4 v);
  press → `press` token. ⌘Q maps to Quit, ⌘, to Settings, ⌘R to refresh.

### 4.8 Empty / not-connected state (per provider tab)

Replaces the card stack, vertically centered in the same panel height:

- Provider glyph or SF Symbol (e.g. `key.slash`) 28 pt, `.quaternary` →
  provider accent at 0.5 opacity.
- One-liner 13 pt `.secondary`: "Gemini CLI isn't connected." (one sentence, no lecture).
- Hint button "Open setup" — 12 pt medium, capsule `pillFill`, opens Settings →
  provider section.
- Appears with a single 0.2 s opacity fade. No illustration parade, no bounce.

### 4.9 Error / stale state

| Condition | Treatment |
|---|---|
| Last success < 120 s | normal: green dot, `.tertiary` timestamp |
| ≥ 120 s (≥ 4 missed 30 s polls) | dot + timestamp → `warnStrong` amber via `staleTint`; text "Updated 5m ago" |
| ≥ 10 min or hard auth error | dot `critical`; text "Offline — retrying" / "Sign-in required" 11 pt amber/red; affected gauges keep **last values** but desaturate to 60% opacity; status-bar dot for that provider goes amber (§4.1) |

Errors never modal, never shake. Stale is a color, not an animation.

---

## 5. INTERACTION DETAILS

### 5.1 Hover
- Cards: `cardFill` → `cardFillHover` (≈ 4% overlay) with `hover` 0.12 s. No lift, no
  shadow, no scale — cards aren't buttons.
- Buttons/segments: text `.secondary` → `.primary`, background per §4.7. Hover is the
  one place plain `ease` is acceptable (Emil, good-vs-great-animations).

### 5.2 Press
- All buttons: `press` scale 0.97 (Emil tip 1), snappy zero-bounce release. Hit targets
  ≥ 24 × 24 pt even when the glyph is 11 pt.

### 5.3 Keyboard
- Panel is key without activating the app (`nonactivatingPanel` + `canBecomeKey`,
  RESEARCH §2) — shortcuts work while the previous app keeps focus.
- `←` / `→` cycle tabs (wrap around); `⌘1–4` jump directly. Both use the reduced
  crossfade path (Motion rule 4).
- `ESC` closes: SwiftUI `.keyboardShortcut(.cancelAction)` + `cancelOperation` override
  as backstop — both route through the same completion-driven `hide()`.
- `⌘R` manual refresh, `⌘,` Settings, `⌘Q` quit. Focus rings: `.focusEffectDisabled()`
  on decorative containers, default rings kept on real controls.

### 5.4 Dismissal
- Click outside: global + local mouse-down monitors; Cmd-Tab/focus loss:
  `windowDidResignKey`. Always remove monitors on hide (RESEARCH §2).
- Clicking the status item while open **toggles closed** — debounce the double-fire
  (button action + local monitor) by ignoring the action if the panel was visible at
  mouse-down (RESEARCH §2 gotcha).
- Re-open during exit animation retargets smoothly (Motion rule 7).

### 5.5 Scrolling / overflow
- Panel height = `min(contentHeight, screen.visibleFrame.height − 16)`. Width never
  scrolls.
- On overflow: card stack inside `ScrollView` with
  `.scrollBounceBehavior(.basedOnSize)`; tab bar and bottom bar stay pinned outside the
  scroll region; 12 pt soft fade mask at the scroll region's top/bottom edges
  (poor-man's scroll-edge-effect) so content doesn't slice against chrome.
- No scroll indicators unless scrolling (`.scrollIndicators(.automatic)`).

### 5.6 Reduce Motion / Transparency
- Reduce Motion → Motion rule 8 fallbacks.
- Reduce Transparency / Increase Contrast: `NSGlassEffectView` degrades automatically;
  the manual fallback is the `VibrancyChromeView` (`.popover` material) from RESEARCH §3.
  Hairlines and label colors are already dynamic — nothing else to do.

---

## 6. Sources

**Emil Kowalski** — [Great Animations](https://emilkowal.ski/ui/great-animations) ·
[Good vs Great Animations](https://emilkowal.ski/ui/good-vs-great-animations) ·
[You Don't Need Animations](https://emilkowal.ski/ui/you-dont-need-animations) ·
[7 Practical Animation Tips](https://emilkowal.ski/ui/7-practical-animation-tips) ·
[The Magic of Clip Path](https://emilkowal.ski/ui/the-magic-of-clip-path) ·
[CSS Transforms](https://emilkowal.ski/ui/css-transforms) ·
[Building a Toast Component](https://emilkowal.ski/ui/building-a-toast-component) ·
[Building a Drawer Component](https://emilkowal.ski/ui/building-a-drawer-component) ·
[animations.dev](https://animations.dev/) (course: easing, springs, taste, "when to
animate at all").

**Jakub Krehel** — [jakub.kr](https://jakub.kr/) ·
[Details That Make Interfaces Feel Better](https://jakub.kr/writing/details-that-make-interfaces-feel-better) ·
[Animating Icons](https://jakub.kr/components/animating-icons) ·
[@jakubkrehel on X](https://x.com/jakubkrehel) ·
distillation: [kylezantos/design-motion-principles](https://github.com/kylezantos/design-motion-principles)
(`skills/design-motion-principles/references/jakub-krehel.md`).

**Apple** — HIG: [Materials / Liquid Glass](https://developer.apple.com/design/human-interface-guidelines/materials) ·
[The Menu Bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) ·
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography) ·
[Color](https://developer.apple.com/design/human-interface-guidelines/color) ·
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) ·
concentricity: [Corner concentricity in SwiftUI on iOS 26 (Nil Coalescing)](https://nilcoalescing.com/blog/ConcentricRectangleInSwiftUI/) ·
[Apple Newsroom — new software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/).

**Brand colors** — [Claude/Anthropic](https://beginswithai.com/claude-ai-logo-color-codes-fonts-downloadable-assets/) ·
[Cursor brand page](https://cursor.com/brand) / [icon palette](https://colorswall.com/palette/111759) ·
Gemini/Google blue `#4285F4` (Google brand standard).

**Platform verification** — `docs/RESEARCH/swiftui-macos26.md` (all APIs referenced here
compiled against the macOS 26.5 SDK; runtime assumptions flagged there).
