# Codex Pet Limit Rings Agent Notes

## Goal

This repository packages `codex-pet-limit-rings`: a native macOS companion app that draws a weekly usage-limit ring around the current Codex pet without patching Codex.

## Primary Contract

- Keep the Codex app bundle unmodified.
- Treat `tools/codex-pet-limit-rings.swift` as the app source.
- Treat `tools/install-limit-rings.sh` and `tools/uninstall-limit-rings.sh` as the public install/uninstall path.
- Treat `skills/codex-pet-limit-rings/SKILL.md` as the reusable Codex-agent workflow.
- Show the current weekly remaining percentage and reset date in JST; do not reintroduce the old five-hour ring unless Codex exposes that limit again.

## Done When

For app changes, verify:

```bash
bash -n tools/*.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

For packaged installs, also run `tools/install-limit-rings.sh` and verify:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings" >/dev/null
```

Do not commit `tmp/`, local logs, screenshots, user Codex state, or generated private pet assets.
