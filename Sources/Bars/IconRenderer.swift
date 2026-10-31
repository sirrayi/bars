import AppKit
import BarsCore

enum IconRenderer {
    struct QuotaLayoutPolicy: Hashable {
        let reservesMissingSecondaryLane: Bool
        let treatsExhaustedSecondaryAsMissing: Bool

        static func provider(_ provider: UsageProvider, snapshot: UsageSnapshot? = nil) -> Self {
            let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
            let windows = snapshot.map { presentation.iconWindows(context: .init(
                snapshot: $0,
                secondaryOverrideWindowID: nil,
                now: $0.updatedAt)) }
            let projectedSingleWindow = snapshot?.primary?.measured == nil && windows?.primary != nil &&
                windows?.secondary == nil
            return Self(
                reservesMissingSecondaryLane: presentation.reservesMissingSecondaryIconLane && !projectedSingleWindow,
                treatsExhaustedSecondaryAsMissing: presentation.treatsExhaustedSecondaryIconWindowAsMissing)
        }

        static func style(_ style: IconStyle) -> Self {
            UsageProvider(rawValue: style.rawValue).map { self.provider($0) }
                ?? Self(reservesMissingSecondaryLane: false, treatsExhaustedSecondaryAsMissing: false)
        }
    }

    private static let creditsCap: Double = 1000
    private static let baseSize = NSSize(width: 18, height: 18)
    // Render to an 18×18 pt template (36×36 px at 2×) to match the system menu bar size.
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2
    private static let canvasPx = Int(outputSize.width * outputScale)

    private struct PixelGrid {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat {
            CGFloat(px) / self.scale
        }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }
    }

    private static let grid = PixelGrid(scale: outputScale)

    static func fillWidthPixels(remaining: Double, rectWidth: Int) -> Int {
        let clamped = max(0, min(remaining / 100, 1))
        return max(0, min(rectWidth, Int((CGFloat(rectWidth) * CGFloat(clamped)).rounded())))
    }

    private struct IconCacheKey: Hashable {
        let primary: Int
        let weekly: Int
        let credits: Int
        let stale: Bool
        let style: Int
        let hideCritters: Bool
        let quotaLayoutPolicy: QuotaLayoutPolicy
    }

    private final class IconCacheStore: @unchecked Sendable {
        private var cache: [IconCacheKey: NSImage] = [:]
        private var order: [IconCacheKey] = []
        private let lock = NSLock()

        func cachedIcon(for key: IconCacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let image = self.cache[key] else { return nil }
            if let idx = self.order.firstIndex(of: key) {
                self.order.remove(at: idx)
                self.order.append(key)
            }
            return image
        }

        func storeIcon(_ image: NSImage, for key: IconCacheKey, limit: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.cache[key] = image
            self.order.removeAll { $0 == key }
            self.order.append(key)
            while self.order.count > limit {
                let oldest = self.order.removeFirst()
                self.cache.removeValue(forKey: oldest)
            }
        }
    }

    private static let iconCacheStore = IconCacheStore()
    private static let iconCacheLimit = 64
    private static let morphBucketCount = 200
    private static let morphCache = MorphCache(limit: 512)

    private final class MorphCache: @unchecked Sendable {
        private let cache = NSCache<NSNumber, NSImage>()

        init(limit: Int) {
            self.cache.countLimit = limit
        }

        func image(for key: NSNumber) -> NSImage? {
            self.cache.object(forKey: key)
        }

        func set(_ image: NSImage, for key: NSNumber) {
            self.cache.setObject(image, forKey: key)
        }
    }

    private struct RectPx: Hashable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        var midXPx: Int {
            self.x + self.w / 2
        }

        var midYPx: Int {
            self.y + self.h / 2
        }

        func rect() -> CGRect {
            Self.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h)
        }

        private static let grid = IconRenderer.grid
    }

    static func makeIcon(
        primaryRemaining: Double?,
        weeklyRemaining: Double?,
        creditsRemaining: Double?,
        stale: Bool,
        style: IconStyle,
        blink: CGFloat = 0,
        wiggle: CGFloat = 0,
        tilt: CGFloat = 0,
        hideCritters: Bool = false,
        quotaLayoutPolicy: QuotaLayoutPolicy? = nil) -> NSImage
    {
        let quotaLayoutPolicy = quotaLayoutPolicy ?? .style(style)
        let shouldCache = blink <= 0.0001 && wiggle <= 0.0001 && tilt <= 0.0001
        let render = {
            self.renderImage {
                // Keep monochrome template icons; Claude uses subtle shape cues only.
                let baseFill = NSColor.labelColor
                let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
                let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
                let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1.0)

                let barWidthPx = 30 // 15 pt at 2×, uses the slot better without touching edges.
                let barXPx = (Self.canvasPx - barWidthPx) / 2

                func drawBar(
                    rectPx: RectPx,
                    remaining: Double?,
                    alpha: CGFloat = 1.0,
                    blink: CGFloat = 0,
                    drawTrackFill: Bool = true)
                {
                    let rect = rectPx.rect()
                    let cornerRadiusPx = rectPx.h / 2
                    let radius = Self.grid.pt(cornerRadiusPx)

                    let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                    if drawTrackFill {
                        baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
                        trackPath.fill()
                    }

                    // Crisp outline: stroke an inset path so the stroke stays within pixel bounds.
                    let strokeWidthPx = 2 // 1 pt == 2 px at 2×
                    let insetPx = strokeWidthPx / 2
                    let strokeRect = Self.grid.rect(
                        x: rectPx.x + insetPx,
                        y: rectPx.y + insetPx,
                        w: max(0, rectPx.w - insetPx * 2),
                        h: max(0, rectPx.h - insetPx * 2))
                    let strokePath = NSBezierPath(
                        roundedRect: strokeRect,
                        xRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)),
                        yRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)))
                    strokePath.lineWidth = CGFloat(strokeWidthPx) / Self.outputScale
                    baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
                    strokePath.stroke()

                    // Fill: clip to the capsule and paint a left-to-right rect so the progress edge is straight.
                    if let remaining {
                        let fillWidthPx = Self.fillWidthPixels(remaining: remaining, rectWidth: rectPx.w)
                        if fillWidthPx > 0 {
                            NSGraphicsContext.current?.cgContext.saveGState()
                            trackPath.addClip()
                            fillColor.withAlphaComponent(alpha).setFill()
                            NSBezierPath(
                                rect: Self.grid.rect(
                                    x: rectPx.x,
                                    y: rectPx.y,
                                    w: fillWidthPx,
                                    h: rectPx.h)).fill()
                            NSGraphicsContext.current?.cgContext.restoreGState()
                        }
                    }
                }

                let usesMissingSecondaryLayout = quotaLayoutPolicy.treatsExhaustedSecondaryAsMissing
                let effectiveWeeklyRemaining: Double? = {
                    if usesMissingSecondaryLayout, let weeklyRemaining, weeklyRemaining <= 0 {
                        return nil
                    }
                    return weeklyRemaining
                }()
                let topValue = primaryRemaining
                let bottomValue = effectiveWeeklyRemaining
                let creditsRatio = creditsRemaining.map { min($0 / Self.creditsCap * 100, 100) }

                let hasWeekly = (bottomValue != nil)
                let weeklyAvailable = hasWeekly && (bottomValue ?? 0) > 0
                let creditsAlpha: CGFloat = 1.0
                let topRectPx = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
                let bottomRectPx = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)
                let creditsRectPx = RectPx(x: barXPx, y: 14, w: barWidthPx, h: 16)
                let creditsBottomRectPx = RectPx(x: barXPx, y: 4, w: barWidthPx, h: 6)

                // When the secondary lane is exhausted or missing, show "top primary, bottom dimmed".
                let missingSecondary = usesMissingSecondaryLayout && !weeklyAvailable

                if let bottomValue, bottomValue > 0, topValue == nil,
                   !quotaLayoutPolicy.reservesMissingSecondaryLane,
                   !usesMissingSecondaryLayout
                {
                    // Some providers surface their only meaningful quota in the secondary slot.
                    drawBar(
                        rectPx: creditsRectPx,
                        remaining: bottomValue,
                        blink: blink)
                } else if weeklyAvailable {
                    // Normal: top=primary, bottom=secondary (bonus/weekly).
                    drawBar(
                        rectPx: topRectPx,
                        remaining: topValue,
                        blink: blink)
                    drawBar(rectPx: bottomRectPx, remaining: bottomValue)
                } else if !hasWeekly || missingSecondary {
                    if usesMissingSecondaryLayout {
                        // Exhausted or missing secondary: top=primary, bottom=dimmed track.
                        drawBar(
                            rectPx: topRectPx,
                            remaining: topValue,
                            blink: blink)
                        drawBar(rectPx: bottomRectPx, remaining: nil, alpha: 0.45)
                    } else {
                        if topValue == nil, let ratio = creditsRatio {
                            // Credits-only: show credits prominently (e.g. credits loaded before usage).
                            drawBar(
                                rectPx: creditsRectPx,
                                remaining: ratio,
                                alpha: creditsAlpha,
                                blink: blink)
                            drawBar(rectPx: creditsBottomRectPx, remaining: nil, alpha: 0.45)
                        } else if !quotaLayoutPolicy.reservesMissingSecondaryLane, let topValue {
                            // One meaningful quota should read as one meter. Reserving an unavailable second
                            // lane makes (for example) 46% remaining look like roughly 23% of the icon.
                            drawBar(
                                rectPx: creditsRectPx,
                                remaining: topValue,
                                blink: blink)
                        } else {
                            // Missing secondary (for example Claude Enterprise): preserve the normal two-lane
                            // layout and dim the unavailable lane.
                            drawBar(
                                rectPx: topRectPx,
                                remaining: topValue,
                                blink: blink)
                            drawBar(rectPx: bottomRectPx, remaining: nil, alpha: 0.45)
                        }
                    }
                } else {
                    // Weekly exhausted/missing: show credits on top (thicker), weekly (likely 0) on bottom.
                    if let ratio = creditsRatio {
                        drawBar(
                            rectPx: creditsRectPx,
                            remaining: ratio,
                            alpha: creditsAlpha,
                            blink: blink)
                    } else {
                        // No credits available; fall back to 5h if present.
                        drawBar(
                            rectPx: topRectPx,
                            remaining: topValue,
                            blink: blink)
                    }
                    drawBar(rectPx: creditsBottomRectPx, remaining: bottomValue)
                }
            }
        }

        if shouldCache {
            let key = IconCacheKey(
                primary: self.quantizedPercent(primaryRemaining),
                weekly: self.quantizedPercent(weeklyRemaining),
                credits: self.quantizedCredits(creditsRemaining),
                stale: stale,
                style: self.styleKey(style),
                hideCritters: hideCritters,
                quotaLayoutPolicy: quotaLayoutPolicy)
            if let cached = self.cachedIcon(for: key) {
                return cached
            }
            let image = render()
            self.storeIcon(image, for: key)
            return image
        }

        return render()
    }

    /// Morph helper: unbraids a simplified knot into our bar icon.
    static func makeMorphIcon(progress: Double, style: IconStyle, hideCritters: Bool = false) -> NSImage {
        let clamped = max(0, min(progress, 1))
        let key = self.morphCacheKey(progress: clamped, style: style, hideCritters: hideCritters)
        if let cached = self.morphCache.image(for: key) {
            return cached
        }
        let image = self.renderImage {
            self.drawUnbraidMorph(t: clamped, style: style, hideCritters: hideCritters)
        }
        self.morphCache.set(image, for: key)
        return image
    }

    private static func quantizedPercent(_ value: Double?) -> Int {
        guard let value else { return -1 }
        return Int((value * 10).rounded())
    }

    private static func quantizedCredits(_ value: Double?) -> Int {
        guard let value else { return -1 }
        let clamped = max(0, min(value, self.creditsCap))
        return Int((clamped * 10).rounded())
    }

    private static let styleKeyLookup: [IconStyle: Int] = {
        var lookup: [IconStyle: Int] = [:]
        for (index, style) in IconStyle.allCases.enumerated() {
            lookup[style] = index
        }
        return lookup
    }()

    private static func styleKey(_ style: IconStyle) -> Int {
        self.styleKeyLookup[style] ?? 0
    }

    private static func morphCacheKey(progress: Double, style: IconStyle, hideCritters: Bool) -> NSNumber {
        let bucket = Int((progress * Double(self.morphBucketCount)).rounded())
        let key = (hideCritters ? 1_000_000 : 0) + self.styleKey(style) * 1000 + bucket
        return NSNumber(value: key)
    }

    private static func cachedIcon(for key: IconCacheKey) -> NSImage? {
        self.iconCacheStore.cachedIcon(for: key)
    }

    private static func storeIcon(_ image: NSImage, for key: IconCacheKey) {
        self.iconCacheStore.storeIcon(image, for: key, limit: self.iconCacheLimit)
    }

    private static func drawUnbraidMorph(t: Double, style: IconStyle, hideCritters: Bool) {
        let t = CGFloat(max(0, min(t, 1)))
        let size = Self.baseSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseColor = NSColor.labelColor

        struct Segment {
            let startCenter: CGPoint
            let endCenter: CGPoint
            let startAngle: CGFloat
            let endAngle: CGFloat
            let startLength: CGFloat
            let endLength: CGFloat
            let startThickness: CGFloat
            let endThickness: CGFloat
            let fadeOut: Bool
        }

        let segments: [Segment] = [
            // Upper ribbon -> top bar
            .init(
                startCenter: center.offset(dx: 0, dy: 2),
                endCenter: CGPoint(x: center.x, y: 9.0),
                startAngle: -30,
                endAngle: 0,
                startLength: 16,
                endLength: 14,
                startThickness: 3.4,
                endThickness: 3.0,
                fadeOut: false),
            // Lower ribbon -> bottom bar
            .init(
                startCenter: center.offset(dx: 0, dy: -2),
                endCenter: CGPoint(x: center.x, y: 4.0),
                startAngle: 210,
                endAngle: 0,
                startLength: 16,
                endLength: 12,
                startThickness: 3.4,
                endThickness: 2.4,
                fadeOut: false),
            // Side ribbon fades away
            .init(
                startCenter: center,
                endCenter: center.offset(dx: 0, dy: 6),
                startAngle: 90,
                endAngle: 0,
                startLength: 16,
                endLength: 8,
                startThickness: 3.4,
                endThickness: 1.8,
                fadeOut: true),
        ]

        for seg in segments {
            let p = seg.fadeOut ? t * 1.1 : t
            let c = seg.startCenter.lerp(to: seg.endCenter, p: p)
            let angle = seg.startAngle.lerp(to: seg.endAngle, p: p)
            let length = seg.startLength.lerp(to: seg.endLength, p: p)
            let thickness = seg.startThickness.lerp(to: seg.endThickness, p: p)
            let alpha = seg.fadeOut ? (1 - p) : 1

            self.drawRoundedRibbon(
                center: c,
                length: length,
                thickness: thickness,
                angle: angle,
                color: baseColor.withAlphaComponent(alpha))
        }

        // Cross-fade in bar fill emphasis near the end of the morph.
        if t > 0.55 {
            let barT = (t - 0.55) / 0.45
            let bars = self.makeIcon(
                primaryRemaining: 100,
                weeklyRemaining: 100,
                creditsRemaining: nil,
                stale: false,
                style: style,
                hideCritters: hideCritters)
            bars.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: barT)
        }
    }

    private static func drawRoundedRibbon(
        center: CGPoint,
        length: CGFloat,
        thickness: CGFloat,
        angle: CGFloat,
        color: NSColor)
    {
        var transform = AffineTransform.identity
        transform.translate(x: center.x, y: center.y)
        transform.rotate(byDegrees: angle)
        transform.translate(x: -center.x, y: -center.y)

        let rect = CGRect(
            x: center.x - length / 2,
            y: center.y - thickness / 2,
            width: length,
            height: thickness)

        let path = NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2)
        path.transform(using: transform)
        color.setFill()
        path.fill()
    }

    private static func withScaledContext(_ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            draw()
            return
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none
        draw()
        ctx.restoreGState()
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * self.outputScale).rounded() / self.outputScale
    }

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: Self.outputSize)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.outputSize.width * Self.outputScale),
            pixelsHigh: Int(Self.outputSize.height * Self.outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = Self.outputSize // points
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                Self.withScaledContext(draw)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Fallback to legacy focus if the bitmap rep fails for any reason.
            image.lockFocus()
            Self.withScaledContext(draw)
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}

extension CGPoint {
    fileprivate func lerp(to other: CGPoint, p: CGFloat) -> CGPoint {
        CGPoint(x: self.x + (other.x - self.x) * p, y: self.y + (other.y - self.y) * p)
    }

    fileprivate func offset(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: self.x + dx, y: self.y + dy)
    }
}

extension CGFloat {
    fileprivate func lerp(to other: CGFloat, p: CGFloat) -> CGFloat {
        self + (other - self) * p
    }
}
