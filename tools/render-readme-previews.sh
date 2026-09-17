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
// Reuse the pet from the already-published screenshot, without reading private pet assets.
guard let petReference = NSImage(contentsOfFile: "docs/assets/pro-pet-rings-20260910.png") else {
    fatalError("Missing published pet reference")
}
let side: CGFloat = 164 + 2 * panelPadding(forReadoutTextScale: 2)
for (plan, state) in [("weekly", weekly)] {
    for hover in [false, true] {
        let overlay = NSImage(size: NSSize(width: side, height: side))
        overlay.lockFocus()
        LimitRingRenderer(state: state, phase: 0.18, showsReadout: hover, readoutTextScale: 2)
            .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        overlay.unlockFocus()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // The source rectangle contains only the pet, inside the old rings.
        // Coordinates are normalized because NSImage uses logical points.
        let referenceSize = petReference.size
        let source = NSRect(x: referenceSize.width * 135 / 435,
                            y: referenceSize.height * 90 / 435,
                            width: referenceSize.width * 164 / 435,
                            height: referenceSize.height * 250 / 435)
        let petHeight: CGFloat = 164
        let petWidth = petHeight * 164 / 250
        NSGraphicsContext.current?.imageInterpolation = .none
        petReference.draw(in: NSRect(x: (side - petWidth) / 2, y: (side - petHeight) / 2,
                                     width: petWidth, height: petHeight),
                          from: source, operation: .sourceOver, fraction: 1)
        overlay.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = hover ? "hover" : "rings"
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "docs/assets/\(plan)-pet-\(suffix)-20260918.png"))
    }
}
SWIFT
swiftc tmp/readme-previews.swift -o tmp/readme-previews -framework AppKit -lsqlite3
tmp/readme-previews
