# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Plans with a five-hour window (e.g. Plus) now show it as an inner teal ring inside the weekly ring, with its own hover readout and menu summary. Plans exposing only a weekly window keep a single ring.
- A used-up window (0% remaining) is drawn as a full red-tinted ring and labelled `上限到達` in the hover readout and menu, instead of a grey track with a stray red stub.
- Hover readouts now show the weekly reset date in JST beneath the remaining percentage.
- The menu now includes `ログイン時に起動`, with installed builds defaulting launch-at-login to on.
- The menu now includes `文字サイズ` so users can pick hover readout scale (`小`–`最大`, 1×–3×; default `大` / 2×). The choice is persisted across launches.
- The installer now prints progress messages for prepare, stop, build, LaunchAgent, and startup steps.
- Pet frame reading now supports current Codex global-state files where live overlay coordinates and cached mascot geometry are stored separately.
- Pet ring placement now scales from `avatar-overlay-mascot-width-px`, so changing the Codex pet size keeps the ring centered.

### Changed

- Default hover readout text is larger (2× the original base fonts) for easier reading on mouse-over.
- Rings now follow pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- The live overlay lookup accepts both `Codex` and `ChatGPT` window owner names.
- Current global-state records without `width`/`mascot` are treated as mascot-origin records instead of old overlay-origin records.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
