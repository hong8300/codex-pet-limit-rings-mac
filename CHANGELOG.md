# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Hover readouts now show the weekly reset date in JST beneath the remaining percentage.
- The menu now includes `ログイン時に起動`, with installed builds defaulting launch-at-login to on.
- Pet frame reading now supports current Codex global-state files where live overlay coordinates and cached mascot geometry are stored separately.
- Pet ring placement now scales from `avatar-overlay-mascot-width-px`, so changing the Codex pet size keeps the ring centered.

### Changed

- The app now renders a single weekly limit ring because current Codex exposes weekly limits only.
- Rings now follow pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- The live overlay lookup accepts both `Codex` and `ChatGPT` window owner names.
- Current global-state records without `width`/`mascot` are treated as mascot-origin records instead of old overlay-origin records.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
