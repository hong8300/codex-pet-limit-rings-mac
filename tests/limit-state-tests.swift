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
assert(weekly.fiveHour == nil)
let plus = decode(["primary_window": five, "secondary_window": week])
assert(plus.weekly?.remainingPercent == 80 && plus.fiveHour?.remainingPercent == 65)
let swapped = decode(["primary_window": week, "secondary_window": five])
assert(swapped.weekly?.remainingPercent == 80 && swapped.fiveHour?.remainingPercent == 65)
assert(decode(["primary_window": five]).weekly == nil && decode(["primary_window": five]).fiveHour != nil)
assert(decode([:]).weekly == nil && decode([:]).fiveHour == nil)
// Plus after the weekly window is used up: weekly 0% (limit reached) while the five-hour window is fresh.
let reached = decode(["primary_window": bucket(18000, 0), "secondary_window": bucket(604800, 100)])
assert(reached.weekly?.isExhausted == true && reached.weekly?.remainingPercent == 0)
assert(reached.fiveHour?.isExhausted == false && reached.fiveHour?.remainingPercent == 100)
assert(decode(["secondary_window": bucket(604800, 104)]).weekly?.isExhausted == true)
// Additional limits are not decoded, even if their schema changes or is invalid.
assert(decode(["primary_window": week], "ignored").weekly?.remainingPercent == 80)
assert(decode([:], [["metered_feature": "codex_bengalfox", "rate_limit": ["primary_window": week]]]).weekly == nil)
assert(decode(["secondary": ["window_minutes": 10080, "used_percent": 20]]).weekly?.remainingPercent == 80)
assert(decode(["primary": ["used_percent": 20]]).weekly?.remainingPercent == 80)
assert(decode(["primary": ["window_minutes": 300, "used_percent": 35]]).fiveHour?.remainingPercent == 65)
assert(reader.decodeUsage(Data("invalid".utf8)) == nil)
for (name, state) in [("weekly", weekly), ("plus", plus), ("reached", reached)] {
    for scale in [CGFloat(1), 2, 3] {
        let side = 164 + 2 * panelPadding(forReadoutTextScale: scale)
        // Radius stays 120pt across text sizes (previously 144pt).
        assert(side / 2 - readoutInset(forReadoutTextScale: scale) == 120)
        let image = NSImage(size: CGSize(width: side, height: side))
        image.lockFocus()
        LimitRingRenderer(state: state, phase: 0.18, showsReadout: true, readoutTextScale: scale)
            .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "tmp/test-\(name)-\(Int(scale)).png"))
    }
}
print("PASS: weekly + five-hour parsing, limit reached, ignored additional limits, duration matching, missing buckets, JST, radius, render scales 1–3")
