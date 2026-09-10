// Appended to the app source (without its entry point) by tools/test-limit-rings.sh.
let reader = LimitStateReader(logsPath: URL(fileURLWithPath: "/nonexistent/logs"),
                              authPath: URL(fileURLWithPath: "/nonexistent/auth"))
func bucket(_ seconds: Int, _ used: Int) -> [String: Any] {
    ["limit_window_seconds": seconds, "used_percent": used, "reset_at": 1789606059]
}
func decode(_ normal: [String: Any], _ additional: [[String: Any]] = []) -> LimitState {
    let data = try! JSONSerialization.data(withJSONObject: [
        "plan_type": "prolite", "rate_limit": normal, "additional_rate_limits": additional
    ])
    return reader.decodeUsage(data)!
}
let week = bucket(604800, 20)
let five = bucket(18000, 35)
let spark: [String: Any] = ["metered_feature": "codex_bengalfox", "rate_limit": [
    "primary_window": bucket(604800, 45), "secondary_window": bucket(18000, 60)
]]
let pro = decode(["primary_window": week], [spark])
assert(pro.weekly?.remainingPercent == 80 && pro.fiveHour == nil)
assert(pro.sparkWeekly?.remainingPercent == 55 && pro.sparkFiveHour?.remainingPercent == 40)
assert(formatResetJST(pro.sparkWeekly?.resetAt) == "2026/09/17 09:47 JST")
let plus = decode(["primary_window": five, "secondary_window": week])
assert(plus.fiveHour?.remainingPercent == 65 && plus.weekly?.remainingPercent == 80)
assert(plus.sparkFiveHour == nil && plus.sparkWeekly == nil)
let four = decode(["primary_window": five, "secondary_window": week], [spark])
assert(four.fiveHour != nil && four.weekly != nil && four.sparkWeekly != nil && four.sparkFiveHour != nil)
let other = decode(["primary_window": week], [["metered_feature": "other", "rate_limit": ["primary_window": five]]])
assert(other.fiveHour == nil && other.sparkFiveHour == nil)
let named = decode(["primary_window": week], [["limit_name": "GPT-5.3-Codex-Spark", "rate_limit": ["primary_window": five]]])
assert(named.sparkFiveHour != nil && named.sparkWeekly == nil)
assert(reader.decodeUsage(Data("invalid".utf8)) == nil)
for (name, state) in [("pro", pro), ("four", four)] {
    for scale in [CGFloat(1), 2, 3] {
        let side = 164 + 2 * panelPadding(forReadoutTextScale: scale)
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
print("PASS: normal/Spark isolation, duration matching, missing buckets, four rings, JST, render scales 1–3")
