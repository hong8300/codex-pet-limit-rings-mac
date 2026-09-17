// Appended to the app source (without its entry point) by tools/test-limit-rings.sh.
let reader = LimitStateReader(logsPath: URL(fileURLWithPath: "/nonexistent/logs"),
                              authPath: URL(fileURLWithPath: "/nonexistent/auth"))
func bucket(_ seconds: Int, _ used: Int) -> [String: Any] {
    ["limit_window_seconds": seconds, "used_percent": used, "reset_at": 1789606059]
}
func decode(_ normal: [String: Any], _ additional: Any = []) -> LimitState {
    let data = try! JSONSerialization.data(withJSONObject: [
        "plan_type": "pro", "rate_limit": normal, "additional_rate_limits": additional
    ])
    return reader.decodeUsage(data)!
}
let week = bucket(604800, 20)
let five = bucket(18000, 35)
let weekly = decode(["primary_window": week])
assert(weekly.weekly?.remainingPercent == 80)
assert(formatResetJST(weekly.weekly?.resetAt) == "2026/09/17 09:47 JST")
assert(decode(["primary_window": five, "secondary_window": week]).weekly?.remainingPercent == 80)
assert(decode(["primary_window": week, "secondary_window": five]).weekly?.remainingPercent == 80)
assert(decode(["primary_window": five]).weekly == nil)
assert(decode([:]).weekly == nil)
// Additional limits are not decoded, even if their schema changes or is invalid.
assert(decode(["primary_window": week], "ignored").weekly?.remainingPercent == 80)
assert(decode([:], [["metered_feature": "codex_bengalfox", "rate_limit": ["primary_window": week]]]).weekly == nil)
assert(decode(["secondary": ["window_minutes": 10080, "used_percent": 20]]).weekly?.remainingPercent == 80)
assert(decode(["primary": ["used_percent": 20]]).weekly?.remainingPercent == 80)
assert(reader.decodeUsage(Data("invalid".utf8)) == nil)
for scale in [CGFloat(1), 2, 3] {
    let side = 164 + 2 * panelPadding(forReadoutTextScale: scale)
    // Radius stays 120pt across text sizes (previously 144pt).
    assert(side / 2 - readoutInset(forReadoutTextScale: scale) == 120)
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    LimitRingRenderer(state: weekly, phase: 0.18, showsReadout: true, readoutTextScale: scale)
        .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "tmp/test-weekly-\(Int(scale)).png"))
}
print("PASS: weekly-only parsing, ignored additional limits, duration matching, missing weekly, JST, smaller radius, render scales 1–3")
