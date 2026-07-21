import AppKit
import CoreGraphics
import Darwin
import Foundation
import SQLite3

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }

    var isWeeklyWindow: Bool {
        guard let windowMinutes else { return false }
        return abs(windowMinutes - weeklyWindowMinutes) <= weeklyWindowMinutes * 0.05
    }
}

struct LimitState {
    var planType: String?
    var weekly: LimitBucket?
    var observedAt: Date
    var source: String

    static let empty = LimitState(planType: nil, weekly: nil, observedAt: Date(), source: "none")
}

private let limitStatePollInterval: TimeInterval = 20.0
private let petFrameFallbackPollInterval: TimeInterval = 2.0
private let petFrameStateDebounceInterval: TimeInterval = 0.035
private let dragFollowInterval: TimeInterval = 1.0 / 60.0
private let dragLiveMismatchTolerance: CGFloat = 96.0
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let liveUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
private let weeklyWindowMinutes = 7.0 * 24.0 * 60.0
private let codexWindowOwnerNames = Set(["Codex", "ChatGPT"])
private let launchAgentLabel = "com.codex-pet.limit-rings"

private func normalizedEpochSeconds(_ value: TimeInterval) -> TimeInterval {
    value > 10_000_000_000 ? value / 1000.0 : value
}

private func formatResetJST(_ resetAt: TimeInterval?) -> String? {
    guard let resetAt else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy/MM/dd HH:mm 'JST'"
    return formatter.string(from: Date(timeIntervalSince1970: normalizedEpochSeconds(resetAt)))
}

struct LaunchAtLoginController {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var agentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    var logsDirectoryURL: URL {
        home.appendingPathComponent("Library/Logs")
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: agentURL.path)
    }

    func enable() throws {
        try fileManager.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [loginExecutableURL().path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logsDirectoryURL.appendingPathComponent("CodexPetLimitRings.log").path,
            "StandardErrorPath": logsDirectoryURL.appendingPathComponent("CodexPetLimitRings.err.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }

    func disable() throws {
        if fileManager.fileExists(atPath: agentURL.path) {
            try fileManager.removeItem(at: agentURL)
        }
    }

    private func loginExecutableURL() -> URL {
        let installed = home.appendingPathComponent("Applications/CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings")
        if fileManager.isExecutableFile(atPath: installed.path) {
            return installed
        }

        if let executable = Bundle.main.executableURL {
            return executable
        }

        return URL(fileURLWithPath: CommandLine.arguments[0])
    }
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
    var additional_rate_limits: [String: RatePayload]?
}

private struct AuthPayload: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var access_token: String?
}

private struct UsagePayload: Decodable {
    var plan_type: String?
    var rate_limit: RatePayload?
    var additional_rate_limits: [AdditionalUsagePayload]?
}

private struct AdditionalUsagePayload: Decodable {
    var limit_name: String?
    var metered_feature: String?
    var rate_limit: RatePayload?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else { return nil }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var authPath: URL
    var codexConfigPath: URL
    var previewPath: URL?
    var fallbackSize: CGFloat = 220
}

final class LimitStateReader {
    private let logsPath: URL
    private let authPath: URL

    init(logsPath: URL, authPath: URL) {
        self.logsPath = logsPath
        self.authPath = authPath
    }

    func readLatest() -> LimitState {
        if let liveState = readLiveUsage() {
            return liveState
        }
        return readLatestLog()
    }

    private func readLiveUsage() -> LimitState? {
        guard let token = readAccessToken() else {
            return nil
        }

        var request = URLRequest(url: liveUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            resultData = data
            resultResponse = response
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 7.0) == .success,
              let http = resultResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data = resultData,
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: data) else {
            return nil
        }

        let weekly = weeklyBucket(from: payload.rate_limit)

        return LimitState(planType: payload.plan_type, weekly: weekly, observedAt: Date(), source: "live")
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authPath),
              let payload = try? JSONDecoder().decode(AuthPayload.self, from: data),
              let token = payload.tokens?.access_token,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return .empty
        }

        let body = String(cString: cText)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return .empty
        }

        let weekly = weeklyBucket(from: payload.rate_limits)

        return LimitState(planType: payload.plan_type, weekly: weekly, observedAt: Date(), source: "legacy-log")
    }

    private func weeklyBucket(from payload: RatePayload?) -> LimitBucket? {
        let candidates = [
            payload?.primary_window?.toBucket(),
            payload?.secondary_window?.toBucket(),
            payload?.primary?.toBucket(),
            payload?.secondary?.toBucket()
        ].compactMap { $0 }

        return candidates.first(where: \.isWeeklyWindow) ?? candidates.first
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = body.index(after: index)
                        break
                    }
                }
            }
            index = body.index(after: index)
        }

        guard let endIndex else { return nil }
        return String(body[start..<endIndex])
    }
}

struct PetFramesTopLeft {
    var mascot: CGRect
    var overlay: CGRect
    var usedLiveOverlay: Bool
}

final class PetFrameReader {
    private struct FrameTemplate {
        var overlaySize: CGSize
        var mascotOffset: CGPoint
        var mascotSize: CGSize

        func scaled(toMascotWidth mascotWidth: CGFloat?) -> FrameTemplate {
            guard let mascotWidth,
                  mascotWidth > 1.0,
                  mascotSize.width > 1.0 else {
                return self
            }

            let scale = mascotWidth / mascotSize.width
            return FrameTemplate(
                overlaySize: CGSize(width: overlaySize.width * scale, height: overlaySize.height * scale),
                mascotOffset: CGPoint(x: mascotOffset.x * scale, y: mascotOffset.y * scale),
                mascotSize: CGSize(width: mascotWidth, height: mascotSize.height * scale)
            )
        }
    }

    private let globalStatePath: URL
    private let codexConfigPath: URL

    init(globalStatePath: URL, codexConfigPath: URL) {
        self.globalStatePath = globalStatePath
        self.codexConfigPath = codexConfigPath
    }

    func readPetFramesTopLeft(preferLiveOverlay: Bool = false, liveReference: CGRect? = nil) -> PetFramesTopLeft? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any] else {
            return nil
        }

        let configuredMascotWidth = readConfiguredMascotWidth()

        if let directFrames = petFrames(from: bounds, originOverride: nil, mascotWidth: configuredMascotWidth, preferLiveOverlay: preferLiveOverlay, liveReference: liveReference) {
            return directFrames
        }

        guard let x = number(bounds["x"]),
              let y = number(bounds["y"]),
              let template = bestFrameTemplate(for: bounds, origin: CGPoint(x: x, y: y)) else {
            return nil
        }

        let scaledTemplate = template.scaled(toMascotWidth: configuredMascotWidth)
        let origin = CGPoint(x: x, y: y)

        if currentBoundsUseMascotOrigin(bounds) {
            return petFrames(
                mascot: CGRect(origin: origin, size: scaledTemplate.mascotSize),
                overlay: CGRect(origin: origin, size: scaledTemplate.mascotSize)
            )
        }

        return petFrames(from: scaledTemplate, origin: origin, preferLiveOverlay: preferLiveOverlay, liveReference: liveReference)
    }

    func readPetFrameTopLeft(preferLiveOverlay: Bool = false) -> CGRect? {
        readPetFramesTopLeft(preferLiveOverlay: preferLiveOverlay)?.mascot
    }

    private func isAvatarOverlayOpen(_ root: [String: Any]) -> Bool {
        if let isOpen = root["electron-avatar-overlay-open"] as? Bool {
            return isOpen
        }
        if let isOpen = root["electron-avatar-overlay-open"] as? NSNumber {
            return isOpen.boolValue
        }
        return true
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }

    private func readConfiguredMascotWidth() -> CGFloat? {
        guard let config = try? String(contentsOf: codexConfigPath, encoding: .utf8) else {
            return nil
        }

        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("avatar-overlay-mascot-width-px") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2,
                  let width = Double(parts[1]),
                  width.isFinite else {
                continue
            }
            return CGFloat(min(max(width, 48.0), 512.0))
        }

        return nil
    }

    private func currentBoundsUseMascotOrigin(_ bounds: [String: Any]) -> Bool {
        bounds["width"] == nil &&
            bounds["height"] == nil &&
            bounds["mascot"] == nil &&
            bounds["anchor"] == nil
    }

    private func petFrames(
        from payload: [String: Any],
        originOverride: CGPoint?,
        mascotWidth: CGFloat?,
        preferLiveOverlay: Bool,
        liveReference: CGRect?
    ) -> PetFramesTopLeft? {
        guard let template = frameTemplate(from: payload),
              let payloadX = number(payload["x"]),
              let payloadY = number(payload["y"]) else {
            return nil
        }

        return petFrames(
            from: template.scaled(toMascotWidth: mascotWidth),
            origin: originOverride ?? CGPoint(x: payloadX, y: payloadY),
            preferLiveOverlay: preferLiveOverlay,
            liveReference: liveReference
        )
    }

    private func petFrames(mascot: CGRect, overlay: CGRect) -> PetFramesTopLeft {
        PetFramesTopLeft(mascot: mascot, overlay: overlay, usedLiveOverlay: false)
    }

    private func petFrames(
        from template: FrameTemplate,
        origin: CGPoint,
        preferLiveOverlay: Bool,
        liveReference: CGRect?
    ) -> PetFramesTopLeft {
        let persistedOverlay = CGRect(origin: origin, size: template.overlaySize)
        let liveOverlay = preferLiveOverlay ? liveCodexOverlayBounds(matching: liveReference ?? persistedOverlay, expectedSize: persistedOverlay.size) : nil
        let overlay = liveOverlay ?? persistedOverlay
        let mascot = CGRect(
            x: overlay.minX + template.mascotOffset.x,
            y: overlay.minY + template.mascotOffset.y,
            width: template.mascotSize.width,
            height: template.mascotSize.height
        )
        return PetFramesTopLeft(mascot: mascot, overlay: overlay, usedLiveOverlay: liveOverlay != nil)
    }

    private func frameTemplate(from payload: [String: Any]) -> FrameTemplate? {
        guard let overlayWidth = number(payload["width"]),
              let overlayHeight = number(payload["height"]) else {
            return nil
        }

        if let mascotPayload = payload["mascot"] as? [String: Any],
           let left = number(mascotPayload["left"]),
           let top = number(mascotPayload["top"]),
           let width = number(mascotPayload["width"]),
           let height = number(mascotPayload["height"]) {
            return FrameTemplate(
                overlaySize: CGSize(width: overlayWidth, height: overlayHeight),
                mascotOffset: CGPoint(x: left, y: top),
                mascotSize: CGSize(width: width, height: height)
            )
        }

        if let anchorPayload = payload["anchor"] as? [String: Any],
           let x = number(payload["x"]),
           let y = number(payload["y"]),
           let anchorX = number(anchorPayload["x"]),
           let anchorY = number(anchorPayload["y"]),
           let width = number(anchorPayload["width"]),
           let height = number(anchorPayload["height"]) {
            return FrameTemplate(
                overlaySize: CGSize(width: overlayWidth, height: overlayHeight),
                mascotOffset: CGPoint(x: anchorX - x, y: anchorY - y),
                mascotSize: CGSize(width: width, height: height)
            )
        }

        return nil
    }

    private func bestFrameTemplate(for bounds: [String: Any], origin: CGPoint) -> FrameTemplate? {
        let currentDisplayId = displayIdText(bounds["displayId"])
        let currentDisplayBounds = rectPayload(bounds["displayBounds"])
        var scoredTemplates: [(score: CGFloat, template: FrameTemplate)] = []

        for candidate in nestedFramePayloads(in: bounds) {
            guard let template = frameTemplate(from: candidate) else { continue }

            var score: CGFloat = 0
            if let currentDisplayId,
               displayIdText(candidate["displayId"]) == currentDisplayId {
                score -= 1_000_000
            }
            if let currentDisplayBounds,
               let candidateDisplayBounds = rectPayload(candidate["displayBounds"]),
               rectsAreClose(candidateDisplayBounds, currentDisplayBounds) {
                score -= 100_000
            }
            if let candidateX = number(candidate["x"]),
               let candidateY = number(candidate["y"]) {
                let dx = candidateX - origin.x
                let dy = candidateY - origin.y
                score += dx * dx + dy * dy
            } else {
                score += 10_000
            }

            scoredTemplates.append((score, template))
        }

        if let best = scoredTemplates.min(by: { $0.score < $1.score })?.template {
            return best
        }

        return FrameTemplate(
            overlaySize: CGSize(width: 356, height: 320),
            mascotOffset: CGPoint(x: 165, y: 8),
            mascotSize: CGSize(width: 163, height: 177)
        )
    }

    private func nestedFramePayloads(in bounds: [String: Any]) -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        if let byDisplayId = bounds["byDisplayId"] as? [String: Any] {
            payloads.append(contentsOf: byDisplayId.values.compactMap { $0 as? [String: Any] })
        }
        if let byResolution = bounds["byResolution"] as? [String: Any] {
            payloads.append(contentsOf: byResolution.values.compactMap { $0 as? [String: Any] })
        }
        return payloads
    }

    private func rectPayload(_ value: Any?) -> CGRect? {
        guard let payload = value as? [String: Any],
              let x = number(payload["x"]),
              let y = number(payload["y"]),
              let width = number(payload["width"]),
              let height = number(payload["height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayIdText(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        if let value = value as? Int {
            return String(value)
        }
        return nil
    }

    private func rectsAreClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1.0 &&
            abs(lhs.minY - rhs.minY) < 1.0 &&
            abs(lhs.width - rhs.width) < 1.0 &&
            abs(lhs.height - rhs.height) < 1.0
    }

    private func liveCodexOverlayBounds(matching reference: CGRect, expectedSize: CGSize) -> CGRect? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { window -> CGRect? in
            let maxWidthDelta = max(80.0, expectedSize.width * 0.55)
            let maxHeightDelta = max(80.0, expectedSize.height * 0.55)
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  codexWindowOwnerNames.contains(ownerName),
                  let layer = number(window[kCGWindowLayer as String]),
                  layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]),
                  width >= 40.0,
                  height >= 40.0,
                  abs(width - expectedSize.width) <= maxWidthDelta,
                  abs(height - expectedSize.height) <= maxHeightDelta else {
                return nil
            }

            return CGRect(x: x, y: y, width: width, height: height)
        }
        .min {
            liveOverlayScore($0, reference: reference, expectedSize: expectedSize) < liveOverlayScore($1, reference: reference, expectedSize: expectedSize)
        }
    }

    private func liveOverlayScore(_ rect: CGRect, reference: CGRect, expectedSize: CGSize) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let distanceScore = distanceSquared(center, to: reference)
        let widthDelta = rect.width - expectedSize.width
        let heightDelta = rect.height - expectedSize.height
        return distanceScore + (widthDelta * widthDelta + heightDelta * heightDelta) * 8.0
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}

struct LimitRingRenderer {
    var state: LimitState
    var phase: Double
    var showsReadout: Bool = false

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.clear(rect)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minSide = min(rect.width, rect.height)
        let urgency = urgency(for: state.weekly)
        let breathe = CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5)
        let pulse = CGFloat(1.0 + urgency * 0.025 * breathe)
        let outerRadius = (minSide * 0.5 - 16.0) * pulse

        drawHalo(context, center: center, radius: outerRadius, urgency: CGFloat(urgency), breathe: breathe)
        drawTicks(context, center: center, radius: outerRadius + 5.0)

        if let weekly = state.weekly {
            drawRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: 7.0,
                bucket: weekly,
                color: color(forRemaining: weekly.remainingPercent, role: .weekly),
                trackAlpha: 0.20,
                phase: phase
            )
        } else {
            drawMissingRing(context, center: center, radius: outerRadius, lineWidth: 7.0)
        }

        if showsReadout {
            drawLimitReadouts(context, center: center, outerRadius: outerRadius, bounds: rect)
        }
        context.restoreGState()
    }

    private enum RingRole {
        case weekly
    }

    private struct LimitReadout {
        var text: String
        var detailText: String?
        var ringPoint: CGPoint
        var labelRect: CGRect
        var color: NSColor
        var angle: CGFloat
    }

    private func urgency(for bucket: LimitBucket?) -> Double {
        guard let bucket else { return 0.0 }
        return min(max((45.0 - bucket.remainingPercent) / 45.0, 0.0), 1.0)
    }

    private func drawHalo(_ context: CGContext, center: CGPoint, radius: CGFloat, urgency: CGFloat, breathe: CGFloat) {
        context.saveGState()
        let color = NSColor(calibratedRed: 0.23 + urgency * 0.55, green: 0.85 - urgency * 0.30, blue: 0.78 - urgency * 0.48, alpha: 0.22 + urgency * 0.16)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 14.0 + urgency * breathe * 5.0, color: color.withAlphaComponent(0.55).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.20).cgColor)
        context.setLineWidth(8.0)
        context.addArc(center: center, radius: radius + 3.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.045).cgColor)
        context.setLineWidth(1.0)
        context.addArc(center: center, radius: radius + 13.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawTicks(_ context: CGContext, center: CGPoint, radius: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        for i in 0..<24 {
            guard i % 2 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 24.0 * CGFloat.pi * 2.0
            let inner = radius - 1.5
            let outer = radius + 2.5
            context.move(to: point(center: center, radius: inner, angle: angle))
            context.addLine(to: point(center: center, radius: outer, angle: angle))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor,
        trackAlpha: CGFloat,
        phase: Double
    ) {
        let start = -CGFloat.pi / 2.0
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        let end = start + max(remaining, 0.018) * CGFloat.pi * 2.0

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.22).cgColor)
        context.addArc(center: center, radius: radius + 1.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: trackAlpha).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 10.0, color: color.withAlphaComponent(0.42).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.30).cgColor)
        context.setLineWidth(lineWidth + 6.0)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 4.0, color: color.withAlphaComponent(0.52).cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        let glintAngle = start + CGFloat(phase.truncatingRemainder(dividingBy: 1.0)) * CGFloat.pi * 2.0
        let glint = point(center: center, radius: radius, angle: glintAngle)
        context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.38).cgColor)
        context.fillEllipse(in: CGRect(x: glint.x - 1.8, y: glint.y - 1.8, width: 3.6, height: 3.6))
        context.restoreGState()
    }

    private func drawMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 1.74, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawLimitReadouts(_ context: CGContext, center: CGPoint, outerRadius: CGFloat, bounds: CGRect) {
        var readouts: [LimitReadout] = []
        if let weekly = state.weekly {
            readouts.append(makeReadout(
                text: formatPercent(weekly.remainingPercent),
                detailText: formatResetJST(weekly.resetAt),
                center: center,
                ringRadius: outerRadius,
                labelRadius: outerRadius + 22.0,
                remainingPercent: weekly.remainingPercent,
                color: color(forRemaining: weekly.remainingPercent, role: .weekly),
                bounds: bounds
            ))
        }

        for readout in resolveReadoutOverlaps(readouts, bounds: bounds) {
            drawReadout(context, readout: readout)
        }
    }

    private func makeReadout(
        text: String,
        detailText: String?,
        center: CGPoint,
        ringRadius: CGFloat,
        labelRadius: CGFloat,
        remainingPercent: Double,
        color: NSColor,
        bounds: CGRect
    ) -> LimitReadout {
        let angle = -CGFloat.pi / 2.0 + CGFloat(max(remainingPercent, 1.8) / 100.0) * CGFloat.pi * 2.0
        let ringPoint = point(center: center, radius: ringRadius, angle: angle)
        let labelPoint = point(center: center, radius: labelRadius, angle: angle)
        let percentSize = NSAttributedString(string: text, attributes: readoutPercentAttributes()).size()
        let detailSize = detailText.map { NSAttributedString(string: $0, attributes: readoutDetailAttributes()).size() } ?? .zero
        let labelSize = CGSize(
            width: ceil(max(text.count > 3 ? 45.0 : 38.0, percentSize.width + 20.0, detailSize.width + 18.0)),
            height: detailText == nil ? 22.0 : 34.0
        )
        var labelRect = CGRect(
            x: labelPoint.x - labelSize.width / 2,
            y: labelPoint.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        labelRect = clamp(labelRect, inside: bounds)
        return LimitReadout(text: text, detailText: detailText, ringPoint: ringPoint, labelRect: labelRect, color: color, angle: angle)
    }

    private func resolveReadoutOverlaps(_ readouts: [LimitReadout], bounds: CGRect) -> [LimitReadout] {
        guard readouts.count > 1 else { return readouts }
        var resolved = readouts

        let averageAngle = resolved.map(\.angle).reduce(0, +) / CGFloat(resolved.count)
        let tangent = CGPoint(x: -sin(averageAngle), y: cos(averageAngle))
        for index in resolved.indices {
            let direction = index == 0 ? -1.0 : 1.0
            resolved[index].labelRect = clamp(resolved[index].labelRect.offsetBy(dx: tangent.x * 12.0 * direction, dy: tangent.y * 12.0 * direction), inside: bounds)
        }

        for _ in 0..<8 {
            var changed = false
            for firstIndex in 0..<resolved.count {
                for secondIndex in (firstIndex + 1)..<resolved.count {
                    let first = expanded(resolved[firstIndex].labelRect)
                    let second = expanded(resolved[secondIndex].labelRect)
                    guard first.intersects(second) else { continue }

                    let xOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
                    let yOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                    let gap: CGFloat = 6.0
                    if xOverlap <= yOverlap {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midX <= resolved[secondIndex].labelRect.midX ? -1.0 : 1.0
                        let nudge = xOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: direction * nudge, dy: 0)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: -direction * nudge, dy: 0)
                    } else {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midY <= resolved[secondIndex].labelRect.midY ? -1.0 : 1.0
                        let nudge = yOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: 0, dy: direction * nudge)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: 0, dy: -direction * nudge)
                    }

                    resolved[firstIndex].labelRect = clamp(resolved[firstIndex].labelRect, inside: bounds)
                    resolved[secondIndex].labelRect = clamp(resolved[secondIndex].labelRect, inside: bounds)
                    changed = true
                }
            }
            if !changed { break }
        }

        return resolved
    }

    private func expanded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -4.0, dy: -3.0)
    }

    private func clamp(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var clamped = rect
        let inset = bounds.insetBy(dx: 4, dy: 4)
        clamped.origin.x = min(max(clamped.minX, inset.minX), inset.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, inset.minY), inset.maxY - clamped.height)
        return clamped
    }

    private func drawReadout(_ context: CGContext, readout: LimitReadout) {
        context.saveGState()
        context.setLineCap(.round)
        context.setStrokeColor(readout.color.withAlphaComponent(0.44).cgColor)
        context.setLineWidth(1.2)
        context.move(to: readout.ringPoint)
        context.addLine(to: CGPoint(x: readout.labelRect.midX, y: readout.labelRect.midY))
        context.strokePath()

        let path = CGPath(roundedRect: readout.labelRect, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        context.setShadow(offset: .zero, blur: 8.0, color: readout.color.withAlphaComponent(0.22).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.055, alpha: 0.78).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(readout.color.withAlphaComponent(0.42).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        let percent = NSAttributedString(string: readout.text, attributes: readoutPercentAttributes())
        let percentSize = percent.size()

        if let detailText = readout.detailText {
            let detail = NSAttributedString(string: detailText, attributes: readoutDetailAttributes())
            let detailSize = detail.size()
            let totalHeight = percentSize.height + detailSize.height - 1.0
            let detailY = readout.labelRect.midY - totalHeight / 2.0 - 0.5
            let percentY = detailY + detailSize.height - 1.0
            percent.draw(at: CGPoint(x: readout.labelRect.midX - percentSize.width / 2.0, y: percentY))
            detail.draw(at: CGPoint(x: readout.labelRect.midX - detailSize.width / 2.0, y: detailY))
        } else {
            percent.draw(at: CGPoint(x: readout.labelRect.midX - percentSize.width / 2, y: readout.labelRect.midY - percentSize.height / 2 + 0.5))
        }
        context.restoreGState()
    }

    private func color(forRemaining remaining: Double, role _: RingRole) -> NSColor {
        if remaining <= 12 {
            return NSColor(calibratedRed: 1.00, green: 0.26, blue: 0.22, alpha: 0.96)
        }
        if remaining <= 30 {
            return NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 0.96)
        }
        return NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.00, alpha: 0.94)
    }

    private func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private func readoutPercentAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92)
        ]
    }

    private func readoutDetailAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.64),
            .kern: -0.35
        ]
    }
}

final class LimitRingView: NSView {
    var state: LimitState = .empty {
        didSet { needsDisplay = true }
    }
    var phase: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsReadout: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(state: state, phase: phase, showsReadout: showsReadout).draw(in: bounds)
    }
}

final class LimitRingsApp: NSObject {
    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let launchAtLoginController = LaunchAtLoginController()
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var animationTimer: Timer?
    private var dragFollowTimer: Timer?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var globalStateSource: DispatchSourceFileSystemObject?
    private var pendingGlobalStateWatcherRestart: DispatchWorkItem?
    private var pendingFrameUpdate: DispatchWorkItem?
    private var startTime = Date()
    private var currentPetFrameAppKit: CGRect?
    private var currentPetOverlayTopLeft: CGRect?
    private var currentPetOverlayFrameAppKit: CGRect?
    private var isTrackingMouseDrag = false
    private var dragMouseToPetOriginOffsetAppKit: CGPoint?
    private var dragMouseToOverlayOriginOffsetAppKit: CGPoint?
    private var holdDraggedFrameUntil: Date?
    private var ringsVisible: Bool
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath)
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath, codexConfigPath: config.codexConfigPath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = ringView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()
    }

    deinit {
        stateTimer?.invalidate()
        frameTimer?.invalidate()
        animationTimer?.invalidate()
        dragFollowTimer?.invalidate()
        pendingGlobalStateWatcherRestart?.cancel()
        pendingFrameUpdate?.cancel()
        globalStateSource?.cancel()
        [mouseDownMonitor, mouseDragMonitor, mouseUpMonitor, mouseMoveMonitor].compactMap { $0 }.forEach {
            NSEvent.removeMonitor($0)
        }
    }

    func run() {
        installStatusMenu()
        updateState()
        updateFrame()
        installGlobalStateWatcher()
        updateRingVisibility()

        stateTimer = Timer.scheduledTimer(withTimeInterval: limitStatePollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFrameFallbackPollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        installDragFollow()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ringView.phase = Date().timeIntervalSince(self.startTime) / 4.6
        }
    }

    private func updateState() {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            DispatchQueue.main.async {
                self.ringView.state = state
                self.updateSummaryMenuItem()
                self.stateReadInFlight = false
            }
        }
    }

    private func installGlobalStateWatcher() {
        pendingGlobalStateWatcherRestart?.cancel()
        pendingGlobalStateWatcherRestart = nil
        globalStateSource?.cancel()
        globalStateSource = nil

        let descriptor = open(config.globalStatePath.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleGlobalStateWatcherRestart(after: 1.0)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.globalStateSource?.data ?? []
            self.scheduleFrameUpdateFromGlobalState()
            if events.contains(.delete) || events.contains(.rename) {
                self.scheduleGlobalStateWatcherRestart(after: 0.2)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        globalStateSource = source
        source.resume()
    }

    private func scheduleGlobalStateWatcherRestart(after delay: TimeInterval) {
        pendingGlobalStateWatcherRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGlobalStateWatcherRestart = nil
            self.installGlobalStateWatcher()
            self.scheduleFrameUpdateFromGlobalState()
        }
        pendingGlobalStateWatcherRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFrameUpdateFromGlobalState() {
        pendingFrameUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFrameUpdate = nil
            self.updateFrame()
            self.updateTooltip(at: NSEvent.mouseLocation)
        }
        pendingFrameUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + petFrameStateDebounceInterval, execute: work)
    }

    private func updateFrame(preferLiveOverlay: Bool = false) {
        if let holdDraggedFrameUntil, Date() < holdDraggedFrameUntil {
            return
        }
        holdDraggedFrameUntil = nil
        if isTrackingMouseDrag && !preferLiveOverlay {
            return
        }

        let liveReference = preferLiveOverlay ? currentPetOverlayTopLeft : nil
        guard let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: preferLiveOverlay, liveReference: liveReference) else {
            currentPetFrameAppKit = nil
            currentPetOverlayTopLeft = nil
            currentPetOverlayFrameAppKit = nil
            isTrackingMouseDrag = false
            dragMouseToPetOriginOffsetAppKit = nil
            dragMouseToOverlayOriginOffsetAppKit = nil
            stopDragFollowTimer()
            ringView.showsReadout = false
            panel.orderOut(nil)
            return
        }

        if preferLiveOverlay,
           isTrackingMouseDrag,
           !petFrames.usedLiveOverlay,
           currentPetFrameAppKit != nil {
            return
        }

        applyPetFrames(petFrames)
    }

    private func applyPetFrames(_ petFrames: PetFramesTopLeft) {
        currentPetFrameAppKit = appKitRectFromTopLeft(petFrames.mascot)
        currentPetOverlayTopLeft = petFrames.overlay
        currentPetOverlayFrameAppKit = appKitRectFromTopLeft(petFrames.overlay)
        setPanelFrame(forPetFrameTopLeft: petFrames.mascot)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setPanelFrame(forPetFrameTopLeft petFrame: CGRect) {
        let padding: CGFloat = 38
        let size = max(petFrame.width, petFrame.height) + padding * 2
        let topLeft = CGPoint(x: petFrame.midX - size / 2, y: petFrame.midY - size / 2)
        let origin = appKitOriginFromTopLeft(topLeft, size: CGSize(width: size, height: size))

        panel.setFrame(CGRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
    }

    private func setPanelFrame(forPetFrameAppKit petFrame: CGRect) {
        let padding: CGFloat = 38
        let size = max(petFrame.width, petFrame.height) + padding * 2
        let origin = CGPoint(x: petFrame.midX - size / 2, y: petFrame.midY - size / 2)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Codex Pet Limit Rings"
        }

        let menu = NSMenu()
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Rings", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let launchItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        launchAtLoginItem = launchItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateLaunchAtLoginMenuItem()
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        let outer = NSBezierPath()
        outer.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 6.7,
            startAngle: 22,
            endAngle: 338,
            clockwise: false
        )
        outer.lineWidth = 2.0
        outer.lineCapStyle = .round
        outer.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func updateSummaryMenuItem() {
        guard let summaryItem else { return }
        guard let weekly = ringView.state.weekly else {
            summaryItem.title = "Waiting for Codex limit data"
            statusItem?.button?.toolTip = "Codex weekly limit: waiting for data"
            return
        }

        let source = ringView.state.source == "live" ? "Live" : "Cached"
        let reset = formatResetJST(weekly.resetAt).map { "Reset \($0)" } ?? "Reset --"
        let percent = formatPercent(weekly.remainingPercent)
        summaryItem.title = "\(source) Weekly \(percent) | \(reset)"
        statusItem?.button?.toolTip = "Codex weekly limit \(percent), \(reset)"
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginItem?.state = launchAtLoginController.isEnabled ? .on : .off
    }

    private func updateRingVisibility() {
        updateShowRingsMenuItem()
        if ringsVisible, currentPetFrameAppKit != nil {
            panel.orderFrontRegardless()
            updateTooltip(at: NSEvent.mouseLocation)
        } else {
            ringView.showsReadout = false
            panel.orderOut(nil)
        }
    }

    private func setRingsVisible(_ visible: Bool) {
        ringsVisible = visible
        UserDefaults.standard.set(visible, forKey: ringsVisibleDefaultsKey)
        updateRingVisibility()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginController.isEnabled {
                try launchAtLoginController.disable()
            } else {
                try launchAtLoginController.enable()
            }
            updateLaunchAtLoginMenuItem()
        } catch {
            updateLaunchAtLoginMenuItem()
            showMenuActionError("ログイン時起動の設定を変更できませんでした。", error: error)
        }
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func showMenuActionError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func installDragFollow() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.beginDragFollowIfNeeded(at: NSEvent.mouseLocation)
            }
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.continueDragFollow(at: NSEvent.mouseLocation)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endDragFollow()
            }
        }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTooltip(at: NSEvent.mouseLocation)
            }
        }
    }

    private func beginDragFollowIfNeeded(at mouse: CGPoint) {
        guard ringsVisible else { return }
        updateFrame()
        guard isLikelyPetDragStart(at: mouse) else { return }
        guard let petFrame = currentPetFrameAppKit,
              let overlayFrame = currentPetOverlayFrameAppKit else { return }
        dragMouseToPetOriginOffsetAppKit = CGPoint(x: petFrame.minX - mouse.x, y: petFrame.minY - mouse.y)
        dragMouseToOverlayOriginOffsetAppKit = CGPoint(x: overlayFrame.minX - mouse.x, y: overlayFrame.minY - mouse.y)
        isTrackingMouseDrag = true
        holdDraggedFrameUntil = nil
        startDragFollowTimer()
        updateDragFrame(at: mouse)
        ringView.showsReadout = false
    }

    private func continueDragFollow(at mouse: CGPoint) {
        if !isTrackingMouseDrag {
            beginDragFollowIfNeeded(at: mouse)
        }
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }
        updateDragFrame(at: mouse)
        ringView.showsReadout = false
    }

    private func endDragFollow() {
        guard isTrackingMouseDrag else { return }
        isTrackingMouseDrag = false
        dragMouseToPetOriginOffsetAppKit = nil
        dragMouseToOverlayOriginOffsetAppKit = nil
        stopDragFollowTimer()
        holdDraggedFrameUntil = Date().addingTimeInterval(0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.updateFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateFrame()
        }
    }

    private func isPrimaryMouseButtonPressed() -> Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    private func updateDragFrame(at mouse: CGPoint) {
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }

        let predictedPetFrame = predictedDragPetFrame(at: mouse)
        let predictedOverlayFrame = predictedDragOverlayFrame(at: mouse)
        let liveReference = predictedOverlayFrame.flatMap { topLeftRectFromAppKit($0) } ?? currentPetOverlayTopLeft

        if let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: true, liveReference: liveReference),
           petFrames.usedLiveOverlay {
            let livePetFrame = appKitRectFromTopLeft(petFrames.mascot)
            if let predictedPetFrame {
                guard dragLiveFrameIsClose(livePetFrame, to: predictedPetFrame) else {
                    applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
                    ringView.showsReadout = false
                    return
                }
            }
            applyPetFrames(petFrames)
            ringView.showsReadout = false
            return
        }

        if let predictedPetFrame {
            applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
        }
        ringView.showsReadout = false
    }

    private func predictedDragPetFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetFrameAppKit,
              let offset = dragMouseToPetOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetFrameAppKit.width,
            height: currentPetFrameAppKit.height
        )
    }

    private func predictedDragOverlayFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetOverlayFrameAppKit,
              let offset = dragMouseToOverlayOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetOverlayFrameAppKit.width,
            height: currentPetOverlayFrameAppKit.height
        )
    }

    private func applyPredictedDragFrame(petFrame: CGRect, overlayFrame: CGRect?) {
        currentPetFrameAppKit = petFrame
        if let overlayFrame {
            currentPetOverlayFrameAppKit = overlayFrame
            currentPetOverlayTopLeft = topLeftRectFromAppKit(overlayFrame)
        }
        setPanelFrame(forPetFrameAppKit: petFrame)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func dragLiveFrameIsClose(_ liveFrame: CGRect, to predictedFrame: CGRect) -> Bool {
        let dx = liveFrame.midX - predictedFrame.midX
        let dy = liveFrame.midY - predictedFrame.midY
        let tolerance = max(dragLiveMismatchTolerance, max(predictedFrame.width, predictedFrame.height) * 0.85)
        return (dx * dx + dy * dy) <= tolerance * tolerance
    }

    private func startDragFollowTimer() {
        guard dragFollowTimer == nil else { return }
        let timer = Timer(timeInterval: dragFollowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isTrackingMouseDrag, self.isPrimaryMouseButtonPressed() else {
                self.endDragFollow()
                return
            }
            self.updateDragFrame(at: NSEvent.mouseLocation)
        }
        dragFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDragFollowTimer() {
        dragFollowTimer?.invalidate()
        dragFollowTimer = nil
    }

    private func isLikelyPetDragStart(at mouse: CGPoint) -> Bool {
        if let overlay = currentPetOverlayFrameAppKit,
           overlay.insetBy(dx: -4, dy: -4).contains(mouse) {
            return true
        }
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -24, dy: -24).contains(mouse) {
            return true
        }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    private func updateTooltip(at mouse: CGPoint) {
        if !ringsVisible || currentPetFrameAppKit == nil || isTrackingMouseDrag {
            ringView.showsReadout = false
            return
        }

        ringView.showsReadout = isHoveringRingOrPet(mouse)
    }

    private func isHoveringRingOrPet(_ mouse: CGPoint) -> Bool {
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -10, dy: -10).contains(mouse) {
            return true
        }

        let frame = panel.frame
        guard frame.insetBy(dx: -4, dy: -4).contains(mouse) else {
            return false
        }

        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let distance = hypot(local.x - center.x, local.y - center.y)
        let radius = min(frame.width, frame.height) * 0.5 - 16.0
        return distance >= radius - 24.0 && distance <= radius + 19.0
    }

    private func appKitOriginFromTopLeft(_ topLeft: CGPoint, size: CGSize) -> CGPoint {
        let topLeftRect = CGRect(origin: topLeft, size: size)
        guard let screen = screenForTopLeftRect(topLeftRect) else {
            return CGPoint(x: topLeft.x, y: max(0, config.fallbackSize - topLeft.y))
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = topLeft.x - screenTopLeftFrame.minX
        let localY = topLeft.y - screenTopLeftFrame.minY
        return CGPoint(x: screen.frame.minX + localX, y: screen.frame.maxY - localY - size.height)
    }

    private func appKitRectFromTopLeft(_ rect: CGRect) -> CGRect {
        guard let screen = screenForTopLeftRect(rect) else {
            return rect
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screenTopLeftFrame.minX
        let localY = rect.minY - screenTopLeftFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func topLeftRectFromAppKit(_ rect: CGRect) -> CGRect? {
        guard let screen = screenForAppKitRect(rect) else {
            return nil
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screen.frame.minX
        let localY = screen.frame.maxY - rect.maxY
        return CGRect(
            x: screenTopLeftFrame.minX + localX,
            y: screenTopLeftFrame.minY + localY,
            width: rect.width,
            height: rect.height
        )
    }

    private func screenForTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { topLeftFrame(for: $0).contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: topLeftFrame(for: $0)) < distanceSquared(center, to: topLeftFrame(for: $1))
        }
    }

    private func screenForAppKitRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: $0.frame) < distanceSquared(center, to: $1.frame)
        }
    }

    private func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = (primaryScreen() ?? NSScreen.screens.first)?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }
}

func renderPreview(config: LimitRingsConfig) -> Bool {
    let state = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    LimitRingRenderer(state: state, phase: 0.18, showsReadout: true).draw(in: CGRect(origin: .zero, size: size))
    image.unlockFocus()

    guard let previewPath = config.previewPath,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try FileManager.default.createDirectory(at: previewPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: previewPath)
        return true
    } catch {
        fputs("codex-pet-limit-rings: could not write preview: \(error)\n", stderr)
        return false
    }
}

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        authPath: codexHome.appendingPathComponent("auth.json"),
        codexConfigPath: codexHome.appendingPathComponent("config.toml"),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--codex-home PATH] [--logs PATH] [--auth PATH] [--config PATH] [--state PATH]

            Draws a transparent Codex rate-limit rings around the current pet.
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
            config.authPath = url.appendingPathComponent("auth.json")
            config.codexConfigPath = url.appendingPathComponent("config.toml")
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
        case "--auth":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.authPath = URL(fileURLWithPath: value)
        case "--config":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.codexConfigPath = URL(fileURLWithPath: value)
        case "--state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.globalStatePath = URL(fileURLWithPath: value)
        case "--size":
            guard let value = args.first, let size = Double(value) else { return nil }
            args.removeFirst()
            config.fallbackSize = CGFloat(size)
        default:
            fputs("codex-pet-limit-rings: unknown argument \(arg)\n", stderr)
            return nil
        }
    }

    return config
}

func defaultLogsPath(codexHome: URL) -> URL {
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

guard let config = parseConfig() else {
    fputs("codex-pet-limit-rings: invalid arguments. Use --help.\n", stderr)
    exit(2)
}

if config.previewPath != nil {
    exit(renderPreview(config: config) ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rings = LimitRingsApp(config: config)
rings.run()
app.run()
