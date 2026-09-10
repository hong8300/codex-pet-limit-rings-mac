# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window and exposes its own menu-bar icon.

The rings are pet-agnostic. They work with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A rings icon appears in the macOS menu bar.
- `Show Rings` toggles the overlay without quitting the app.
- `ログイン時に起動` toggles the LaunchAgent login item. Installed builds default this setting to on.
- `文字サイズ` sets the hover readout font scale: `小` / `中` / `大` / `特大` / `最大` (1×–3×). The default is `大` (2×). The choice is stored in UserDefaults and survives relaunches.
- `Refresh Now` rereads usage and pet-position state.
- Hovering over the ring or pet shows the exact five-hour and weekly remaining percentages and JST reset dates at their arc endpoints.
- Dragging the pet makes the rings follow the gesture immediately while Codex persists the new position.
- Closing the Codex pet hides the rings.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- macOS desktop/Space switching keeps the rings visible with the pet rather than tying them to one active desktop.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads live usage first, then local files as support or legacy fallback:

- `https://chatgpt.com/backend-api/wham/usage`: live usage endpoint, called with the local ChatGPT access token from `~/.codex/auth.json`. Current Codex exposes 18000-second (five-hour) and 604800-second (weekly) windows under `rate_limit`; the app identifies each bucket by duration rather than relying on primary/secondary ordering.
- `~/.codex/auth.json`: local ChatGPT auth token used for the live usage call.
- `~/.codex/.codex-global-state.json`: current pet bounds. Current Codex stores the live overlay `x`/`y` at `electron-avatar-overlay-bounds` and may keep mascot geometry under `byDisplayId` or `byResolution`; older builds stored `electron-avatar-overlay-bounds.mascot` directly.
- `~/.codex/config.toml`: current `avatar-overlay-mascot-width-px` value. Cached geometry is scaled to this width, and current global-state entries without `width`/`mascot` are treated as mascot-origin records.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/logs_2.sqlite`: legacy fallback source using the newest `codex.rate_limits` event when the live usage call fails and that older event is present.

The app watches `~/.codex/.codex-global-state.json` with a macOS file event source, so pet open/close and position writes trigger an immediate frame update. A slow frame timer remains as a fallback in case the file is replaced or an event is missed.

No OpenAI API key is required. The menu summary says `Live` when the direct usage read succeeds and `Cached` when it is showing the legacy local event-log fallback.

## Rendering Model

- Outer ring: weekly remaining percentage.
- The entire ring stack is offset outward by an extra 40 macOS points. With up to four rings spaced 13 points apart, the innermost stroke remains at least 20 points outside half the pet frame’s longest side. Panel and preview padding include this clearance; hover text scaling does not change ring radii.
- Following rings, outside to inside: normal five-hour (if exposed), Spark weekly, Spark five-hour (each only if exposed). A Pro account exposing only normal weekly plus both Spark windows has three rings; an account exposing all four windows has four.
- Spark is selected from `additional_rate_limits` by `metered_feature == codex_bengalfox` or `limit_name == GPT-5.3-Codex-Spark`. Legacy event maps accept either identifier as a key. Unrelated additional limits are ignored. Each Spark window is matched by duration, never substituted for a normal window.
- Reset labels: JST reset dates from each matching normal or Spark bucket, shown in the menu and hover readouts. Spark labels explicitly say `Spark Week` / `Spark 5h`. Three or more hover labels are spread vertically to separate coincident arc endpoints.
- Normal ring colors: blue (weekly) or green (five-hour) for healthy, amber for low, and red for critical. Spark weekly is purple and Spark five-hour is pink; these hues remain distinct at low capacity, with a darker shade at 30% or less. All available buckets contribute to the urgency halo.
- Exact percentages are shown only on hover and in the menu to keep the pet feeling ambient rather than dashboard-like.
- Hover readout font size is user-selectable via the menu-bar `文字サイズ` submenu. Scales are relative to the original base fonts (11.5pt percent / 9pt detail): 1.0, 1.5, 2.0 (default), 2.5, and 3.0. Panel padding grows with the scale so larger labels stay readable without moving the ring away from the pet.
- Preferences stored by the app:
  - `CodexPetLimitRings.ringsVisible` — whether the overlay is shown.
  - `CodexPetLimitRings.readoutTextScale` — hover readout scale multiplier.

## Install Contract

`tools/install-limit-rings.sh` builds:

```text
~/Applications/CodexPetLimitRings.app
```

and installs:

```text
~/Library/LaunchAgents/com.codex-pet.limit-rings.plist
```

The LaunchAgent starts the app at login. The installer also removes the earlier prototype app and LaunchAgent names if present:

Installed builds default launch-at-login to on by writing this LaunchAgent during installation. The menu item can remove or recreate the same plist for future logins without patching the Codex app.

```text
~/Applications/CodexLimitAura.app
~/Library/LaunchAgents/com.codex-pet.limit-aura.plist
```

`tools/uninstall-limit-rings.sh` unloads the LaunchAgent, removes the app bundle, clears saved preferences (`ringsVisible`, `readoutTextScale`), and also cleans up those earlier prototype names.

## Development

Build and run the app from the repository:

```bash
tools/run-limit-rings.sh
```

Run regression checks with `bash tools/test-limit-rings.sh`.

Render a static preview (`--size` is the pet size; the canvas adds the live panel’s label padding):

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
