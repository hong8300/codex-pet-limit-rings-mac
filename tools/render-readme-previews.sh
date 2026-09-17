#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp docs/assets
# Reuse the production renderer with public sample data, without reading local Codex state.
sed '/^guard let config = parseConfig() else {/,$d' tools/codex-pet-limit-rings.swift > tmp/readme-previews.swift
cat >> tmp/readme-previews.swift <<'SWIFT'
let week = LimitBucket(usedPercent: 20, windowMinutes: 10080, resetAt: 1789606059)
let weekly = LimitState(planType: "pro", weekly: week,
                        observedAt: Date(timeIntervalSince1970: 1789002000), source: "sample")
let side: CGFloat = 164 + 2 * panelPadding(forReadoutTextScale: 2)
for (plan, state) in [("weekly", weekly)] {
    for hover in [false, true] {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        LimitRingRenderer(state: state, phase: 0.18, showsReadout: hover, readoutTextScale: 2)
            .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = hover ? "hover" : "rings"
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "docs/assets/\(plan)-\(suffix).png"))
    }
}
SWIFT
swiftc tmp/readme-previews.swift -o tmp/readme-previews -framework AppKit -lsqlite3
tmp/readme-previews
