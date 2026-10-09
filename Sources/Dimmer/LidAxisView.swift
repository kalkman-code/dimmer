import AppKit
import os
import SwiftUI

// A tag's number while it is typed in. Return or clicking away commits once; Escape cancels.
struct TagNumberField: NSViewRepresentable {
    let value: Double
    let name: String
    let rangeDescription: String
    let onFinish: (Double?, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "\(Int(value.rounded()))")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .labelColor
        field.alignment = .right
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(name)
        field.setAccessibilityHelp(rangeDescription)
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinish: (Double?, Bool) -> Void
        private var finished = false

        init(onFinish: @escaping (Double?, Bool) -> Void) { self.onFinish = onFinish }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil, restoringFocus: true); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { finish(Double(control.stringValue), restoringFocus: true); return true }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finish(Double((notification.object as? NSTextField)?.stringValue ?? ""), restoringFocus: false)
        }

        private func finish(_ value: Double?, restoringFocus: Bool) {
            guard !finished else { return }
            finished = true
            onFinish(value.flatMap { $0.isFinite ? $0 : nil }, restoringFocus)
        }
    }
}

enum AxisHandle: CaseIterable {
    case keyboardLow, keyboardHigh, screenLow, screenHigh, zoneLow, zoneHigh

    var isZone: Bool { self == .zoneLow || self == .zoneHigh }
    var isLow: Bool { self == .keyboardLow || self == .screenLow || self == .zoneLow }
    var isScreen: Bool { self == .screenLow || self == .screenHigh }
    var isKeyboard: Bool { self == .keyboardLow || self == .keyboardHigh }
}

private enum AxisTag: Hashable {
    case keyboardLow, keyboardHigh, screenLow, screenHigh, zoneLow, zoneHigh

    var handle: AxisHandle {
        switch self {
        case .keyboardLow: .keyboardLow
        case .keyboardHigh: .keyboardHigh
        case .screenLow: .screenLow
        case .screenHigh: .screenHigh
        case .zoneLow: .zoneLow
        case .zoneHigh: .zoneHigh
        }
    }
}

private enum AxisField: Hashable {
    case angle(AxisTag), level(AxisTag)
}

struct LidAxisView: View {
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @State private var active: AxisHandle?
    @State private var hovered: AxisHandle?
    @FocusState private var focusedField: AxisField?

    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "settings")
    private let reach: CGFloat = 14
    private let plotWidth: CGFloat = 604
    private let gutter: CGFloat = 100
    private let rightInset: CGFloat = 10
    private let keyboardTop: CGFloat = 10
    private let screenTop: CGFloat = 78
    private let keyboardHeight: CGFloat = 54
    private let screenHeight: CGFloat = 54
    private let privacyHeight: CGFloat = 30
    private var privacyTop: CGFloat { screenTop + screenHeight + 14 }
    private var axisY: CGFloat { privacyTop + 12 + (features.privacyEnabled ? privacyHeight + 14 : 0) }
    private var plotHeight: CGFloat { axisY + 26 }
    private let keyboardColour = Color(hex: 0xE9C891)
    private let screenColour = Color(hex: 0xE2E5EA)
    private let privacyColour = Color(hex: 0xB9C8E6)
    private let secondary = Color(hex: 0x9A9EA7)
    private let fieldColour = Color(hex: 0x232328)

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvasSize in drawAxis(in: &context, size: canvasSize) }
                    laneNames(keyboard: true)
                    rangeTags(size: size, screen: false)
                    laneNames(keyboard: false)
                    rangeTags(size: size, screen: true)
                    if features.privacyEnabled {
                        laneName(L10n.string("Privacy"), colour: privacyColour, live: privacyLive, top: privacyTop, height: privacyHeight)
                        ForEach([AxisTag.zoneLow, .zoneHigh], id: \.self) { tag in
                            tagView(tag).position(tagPosition(tag, size: size))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .simultaneousGesture(axisDrag(size: size))
                .onContinuousHover { phase in
                    guard active == nil else { return }
                    switch phase {
                    case .active(let point):
                        hovered = handle(at: point, size: size)
                        (hovered.map { cursor(for: $0, dragging: false) } ?? .arrow).set()
                    case .ended:
                        hovered = nil
                        NSCursor.arrow.set()
                    }
                }
            }
            .frame(width: plotWidth, height: plotHeight)
            .focusEffectDisabled()

            HStack(alignment: .top, spacing: 12) {
                Text(L10n.string("Drag an end sideways for its angle, up or down for its brightness. Tab selects a value; Return edits it and Escape cancels."))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.string("← → 1° · ↑ ↓ 5%"))
                    .font(.system(size: 11).monospacedDigit())
                    .fixedSize()
            }
            .font(.system(size: 11))
            .foregroundStyle(secondary)

            if features.privacyEnabled && controller.dimsScreen && features.snap.zoneLow < controller.screenRange.highAngle {
                HStack(spacing: 5) {
                    Text(L10n.string("The screen already dims inside the snap zone."))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                    Button {
                        moveScreenBelowZone()
                    } label: {
                        Text(L10n.string("Move screen range below the zone"))
                            .font(.system(size: 11))
                            .foregroundStyle(privacyColour)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: plotWidth)
        .accessibilityElement(children: .contain)
    }

    // The tag number being typed in. Separate from focus: the field must exist before it can take focus,
    // so a click sets this and the field focuses itself when it appears.
    @State private var editing: AxisField?

    private func laneNames(keyboard: Bool) -> some View {
        let enabled = keyboard ? controller.dimsKeyboard : controller.dimsScreen
        let top = keyboard ? keyboardTop : screenTop
        let height = keyboard ? keyboardHeight : screenHeight
        return Group {
            HStack(spacing: 4) {
                Text(keyboard ? L10n.string("Keyboard") : L10n.string("Screen"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(keyboard ? keyboardColour : screenColour)
                Toggle(keyboard ? L10n.string("Dim the keyboard") : L10n.string("Dim the screen too"),
                       isOn: keyboard ? $controller.dimsKeyboard : $controller.dimsScreen)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .opacity(enabled ? 1 : 0.35)
            .frame(width: gutter - 4, alignment: .leading)
            .position(x: (gutter - 4) / 2, y: top + height / 2 - 7)
            Text(keyboard ? keyboardLive : screenLive)
                .accessibilityHidden(true)
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .frame(width: gutter - 4, alignment: .leading)
                .position(x: (gutter - 4) / 2, y: top + height / 2 + 9)
        }
    }

    private func laneName(_ title: String, colour: Color, live: String, top: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(colour)
            Text(live).font(.system(size: 11)).foregroundStyle(secondary)
                .accessibilityHidden(true)
        }
        .frame(width: gutter - 4, alignment: .leading)
        .position(x: (gutter - 4) / 2, y: top + height / 2)
    }

    private var currentAngle: Double { controller.angle ?? 0 }
    private var keyboardLive: String {
        guard controller.dimsKeyboard else { return L10n.string("off") }
        return L10n.string("now \(Int((controller.keyboardRange.level(at: currentAngle) * 100).rounded()))%")
    }
    private var screenLive: String {
        guard controller.dimsScreen else { return L10n.string("off") }
        guard controller.angle != nil else { return L10n.string("now untouched") }
        return currentAngle >= controller.screenRange.highAngle
            ? L10n.string("now untouched")
            : L10n.string("now \(Int((controller.screenRange.level(at: currentAngle) * 100).rounded()))%")
    }
    private var privacyLive: String {
        guard features.privacyEnabled else { return L10n.string("off") }
        guard controller.angle != nil else { return L10n.string("snap zone") }
        return currentAngle >= features.snap.zoneLow && currentAngle <= features.snap.zoneHigh ? L10n.string("lid in zone") : L10n.string("snap zone")
    }

    private func drawAxis(in context: inout GraphicsContext, size: CGSize) {
        let x = xPosition(size: size)
        drawRamp(in: &context, range: controller.keyboardRange, x: x, top: keyboardTop,
                 height: keyboardHeight, colour: keyboardColour, isScreen: false,
                 opacity: controller.dimsKeyboard ? 1 : 0.35)
        drawRamp(in: &context, range: controller.screenRange, x: x, top: screenTop,
                 height: screenHeight, colour: screenColour, isScreen: true,
                 opacity: controller.dimsScreen ? 1 : 0.35)

        if features.privacyEnabled {
            let well = CGRect(x: gutter, y: privacyTop, width: size.width - gutter - rightInset, height: privacyHeight)
            context.fill(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x111113)))
            context.stroke(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x2A2A30)), lineWidth: 0.5)
            let zoneRect = CGRect(x: x(features.snap.zoneLow), y: privacyTop + 1,
                                  width: max(x(features.snap.zoneHigh) - x(features.snap.zoneLow), 2), height: privacyHeight - 2)
            let zonePath = Path(roundedRect: zoneRect, cornerRadius: 2)
            context.fill(zonePath, with: .color(privacyColour.opacity(0.22)))
            context.stroke(zonePath, with: .color(privacyColour.opacity(0.55)), lineWidth: 0.5)
            let labelRect = CGRect(x: zoneRect.midX - 34, y: zoneRect.midY - 8, width: 68, height: 16)
            let labelClear = [AxisTag.zoneLow, .zoneHigh].allSatisfy { tag in
                let centre = tagPosition(tag, size: size)
                let width = tagWidth(tag)
                return !labelRect.intersects(CGRect(x: centre.x - width / 2, y: centre.y - 10, width: width, height: 20))
            }
            if zoneRect.width > 68 && labelClear {
                context.draw(Text(L10n.string("Snap zone")).font(.system(size: 11, weight: .medium)).foregroundColor(privacyColour),
                             at: CGPoint(x: zoneRect.midX, y: zoneRect.midY))
            }
            for angle in [features.snap.zoneLow, features.snap.zoneHigh] {
                let bar = CGRect(x: x(angle) - 2, y: privacyTop - 3, width: 4, height: privacyHeight + 6)
                let barPath = Path(roundedRect: bar, cornerRadius: 2)
                context.fill(barPath, with: .color(privacyColour))
                context.stroke(barPath, with: .color(Color(hex: 0x141416)), lineWidth: 1)
            }
        }

        drawScale(in: &context, x: x, left: gutter, top: keyboardTop, height: keyboardHeight,
                  opacity: controller.dimsKeyboard ? 1 : 0.35)
        drawScale(in: &context, x: x, left: gutter, top: screenTop, height: screenHeight,
                  opacity: controller.dimsScreen ? 1 : 0.35)
        drawAngleAxis(in: &context, x: x)

        if let angle = controller.angle {
            let markerX = x(angle)
            var marker = Path()
            marker.move(to: CGPoint(x: markerX, y: keyboardTop - 2))
            marker.addLine(to: CGPoint(x: markerX, y: axisY + 6))
            context.stroke(marker, with: .color(Color.white.opacity(0.7)), lineWidth: 1)
            let ranges: [(DimRange, CGFloat, CGFloat, Bool)] = [
                (controller.keyboardRange, keyboardTop, keyboardHeight, false),
                (controller.screenRange, screenTop, screenHeight, true)
            ]
            for (range, top, height, isScreen) in ranges where !(isScreen && angle >= range.highAngle) {
                let y = top + height * CGFloat(1 - range.level(at: angle))
                let dimmed = isScreen && !controller.dimsScreen || !isScreen && !controller.dimsKeyboard
                context.fill(Path(ellipseIn: CGRect(x: markerX - 2.5, y: y - 2.5, width: 5, height: 5)),
                             with: .color(.white.opacity(dimmed ? 0.35 : 1)))
            }
            let capsule = CGRect(x: markerX - 26, y: axisY + 7, width: 52, height: 17)
            context.fill(Path(roundedRect: capsule, cornerRadius: 8.5), with: .color(.white))
            context.draw(Text(L10n.string("Lid \(Int(angle.rounded()))°")).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: 0x141416)), at: CGPoint(x: markerX, y: capsule.midY))
        }
        // Above its top end the screen is left at the user's own brightness; say so in words, sized to fit.
        // Like the tags it dodges the lid line: the long words if they fit in the stretch on either side
        // of the line, else the short word, else nothing.
        let start = x(controller.screenRange.highAngle) + 6, end = x(LidAxis.maximum) - 6
        let lidX = controller.angle.map { x($0) }
        let gaps: [ClosedRange<CGFloat>] = {
            // Swift traps on a range whose bounds are reversed, so every gap is checked before it is built:
            // building start...(lidX - 6) unguarded crashed the app with the lid just past the screen's top end.
            func gap(_ low: CGFloat, _ high: CGFloat) -> ClosedRange<CGFloat>? {
                low.isFinite && high.isFinite && low < high ? low...high : nil
            }
            guard let lidX, lidX > start, lidX < end else { return [gap(start, end)].compactMap { $0 } }
            return [gap(start, lidX - 6), gap(lidX + 6, end)].compactMap { $0 }
        }()
        let choice: (words: String, width: CGFloat, gap: ClosedRange<CGFloat>)? = [
            (L10n.string("your own brightness, untouched"), CGFloat(184)), (L10n.string("untouched"), CGFloat(62)),
        ].lazy.compactMap { option in
            gaps.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
                .flatMap { $0.upperBound - $0.lowerBound >= option.1 ? (option.0, option.1, $0) : nil }
        }.first
        if let (words, labelWidth, gap) = choice {
            let labelRect = CGRect(x: (gap.lowerBound + gap.upperBound) / 2 - labelWidth / 2,
                                   y: screenTop + screenHeight / 2 - 7, width: labelWidth, height: 14)
            context.fill(Path(roundedRect: labelRect, cornerRadius: 3), with: .color(Color(hex: 0x111113)))
            context.draw(Text(words).font(.system(size: 11))
                .foregroundColor(secondary.opacity(controller.dimsScreen ? 1 : 0.35)),
                           at: CGPoint(x: labelRect.midX, y: labelRect.midY))
        }
        drawRangeHandles(in: &context, x: x, range: controller.keyboardRange, top: keyboardTop,
                         height: keyboardHeight, colour: keyboardColour.opacity(controller.dimsKeyboard ? 1 : 0.35),
                         low: .keyboardLow, high: .keyboardHigh)
        drawRangeHandles(in: &context, x: x, range: controller.screenRange, top: screenTop,
                         height: screenHeight, colour: screenColour.opacity(controller.dimsScreen ? 1 : 0.35),
                         low: .screenLow, high: .screenHigh)
        drawZoneHandles(in: &context, x: x)
    }

    private func drawRamp(in context: inout GraphicsContext, range: DimRange, x: (Double) -> CGFloat,
                          top: CGFloat, height: CGFloat, colour: Color, isScreen: Bool, opacity: Double) {
        let floor = top + height
        let y: (Double) -> CGFloat = { top + height * CGFloat(1 - min(max($0, 0), 1)) }
        let end = isScreen ? range.highAngle : LidAxis.maximum
        let well = CGRect(x: gutter, y: top, width: x(LidAxis.maximum) - gutter, height: height)
        context.fill(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x111113).opacity(opacity)))
        context.stroke(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x2A2A30).opacity(opacity)), lineWidth: 0.5)
        var fill = Path()
        fill.move(to: CGPoint(x: x(0), y: floor))
        fill.addLine(to: CGPoint(x: x(0), y: y(range.lowLevel)))
        fill.addLine(to: CGPoint(x: x(range.lowAngle), y: y(range.lowLevel)))
        fill.addLine(to: CGPoint(x: x(range.highAngle), y: y(range.highLevel)))
        fill.addLine(to: CGPoint(x: x(end), y: y(range.highLevel)))
        fill.addLine(to: CGPoint(x: x(end), y: floor))
        fill.closeSubpath()
        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: well, cornerRadius: 4))
            layer.fill(fill, with: .linearGradient(
                Gradient(colors: [colour.opacity(0.30 * opacity), colour.opacity(0.02 * opacity)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: floor)))
        }

        var line = Path()
        line.move(to: CGPoint(x: x(0), y: y(range.lowLevel)))
        line.addLine(to: CGPoint(x: x(range.lowAngle), y: y(range.lowLevel)))
        line.addLine(to: CGPoint(x: x(range.highAngle), y: y(range.highLevel)))
        line.addLine(to: CGPoint(x: x(end), y: y(range.highLevel)))
        context.stroke(line, with: .color(colour.opacity(opacity)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        if isScreen {
            var drop = Path()
            drop.move(to: CGPoint(x: x(range.highAngle), y: y(range.highLevel)))
            drop.addLine(to: CGPoint(x: x(range.highAngle), y: floor))
            context.stroke(drop, with: .color(screenColour.opacity(0.35 * opacity)), lineWidth: 0.75)
        }
    }

    private func drawScale(in context: inout GraphicsContext, x: (Double) -> CGFloat,
                           left: CGFloat, top: CGFloat, height: CGFloat, opacity: Double) {
        for (text, y) in [(L10n.string("100%"), top + 4), (L10n.string("0%"), top + height - 1)] {
            context.draw(Text(text).font(.system(size: 11).monospacedDigit()).foregroundColor(secondary.opacity(opacity)),
                         at: CGPoint(x: left - 8, y: y), anchor: .trailing)
        }
    }

    // The white "Lid N°" capsule sits on the label row; a tick label under it would show through its edges.
    private func underLidCapsule(_ labelX: CGFloat, x: (Double) -> CGFloat) -> Bool {
        guard let angle = controller.angle else { return false }
        return abs(labelX - x(angle)) < 44
    }

    private func drawAngleAxis(in context: inout GraphicsContext, x: (Double) -> CGFloat) {
        var axis = Path()
        axis.move(to: CGPoint(x: gutter, y: axisY))
        axis.addLine(to: CGPoint(x: x(LidAxis.maximum), y: axisY))
        context.stroke(axis, with: .color(Color(hex: 0x4A4D55)), lineWidth: 1)
        for angle in stride(from: 0.0, through: 120.0, by: 15.0) {
            // 120° stays a tick without a label: beside 130° the two labels ran together.
            let major = Int(angle) % 30 == 0 && angle < 120
            let tickHeight: CGFloat = Int(angle) % 30 == 0 ? 6 : 3
            var tick = Path()
            tick.move(to: CGPoint(x: x(angle), y: axisY))
            tick.addLine(to: CGPoint(x: x(angle), y: axisY + tickHeight))
            context.stroke(tick, with: .color(Color(hex: 0x4A4D55)), lineWidth: 0.7)
            if major && !underLidCapsule(x(angle), x: x) {
                context.draw(Text(L10n.string("\(Int(angle))°")).font(.system(size: 11).monospacedDigit()).foregroundColor(secondary),
                             at: CGPoint(x: x(angle), y: axisY + 18))
            }
        }
        var finalTick = Path()
        finalTick.move(to: CGPoint(x: x(LidAxis.maximum), y: axisY))
        finalTick.addLine(to: CGPoint(x: x(LidAxis.maximum), y: axisY + 6))
        context.stroke(finalTick, with: .color(Color(hex: 0x4A4D55)), lineWidth: 0.7)
        // Anchored on its right edge so the last label stays inside the window rather than being clipped.
        if !underLidCapsule(x(LidAxis.maximum) - 12, x: x) {
            context.draw(Text(L10n.string("130°")).font(.system(size: 11).monospacedDigit()).foregroundColor(secondary),
                         at: CGPoint(x: x(LidAxis.maximum) + 4, y: axisY + 18), anchor: .trailing)
        }
        context.draw(Text(L10n.string("Lid angle")).font(.system(size: 11)).foregroundColor(secondary),
                     at: CGPoint(x: 0, y: axisY + 18), anchor: .leading)
    }

    private func drawRangeHandles(in context: inout GraphicsContext, x: (Double) -> CGFloat, range: DimRange,
                                  top: CGFloat, height: CGFloat, colour: Color, low: AxisHandle, high: AxisHandle) {
        for (handle, angle, level) in [(low, range.lowAngle, range.lowLevel), (high, range.highAngle, range.highLevel)] {
            let point = CGPoint(x: x(angle), y: top + height * CGFloat(1 - level))
            let circle = Path(ellipseIn: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11))
            context.fill(circle, with: .color(colour))
            context.stroke(circle, with: .color(Color(hex: 0x141416)), lineWidth: 1.5)
            if isKeyboardFocused(tag(for: handle)) {
                let ring = Path(ellipseIn: CGRect(x: point.x - 9.5, y: point.y - 9.5, width: 19, height: 19))
                context.stroke(ring, with: .color(privacyColour.opacity(0.55)), lineWidth: 2)
            }
        }
    }

    private func drawZoneHandles(in context: inout GraphicsContext, x: (Double) -> CGFloat) {
        guard features.privacyEnabled else { return }
        for (handle, angle) in [(AxisHandle.zoneLow, features.snap.zoneLow), (.zoneHigh, features.snap.zoneHigh)] {
            let rect = CGRect(x: x(angle) - 2, y: privacyTop - 3, width: 4, height: privacyHeight + 6)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            if isKeyboardFocused(tag(for: handle)) {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 4),
                               with: .color(privacyColour.opacity(0.55)), lineWidth: 2)
            }
            context.fill(path, with: .color(privacyColour))
            context.stroke(path, with: .color(Color(hex: 0x141416)), lineWidth: 1)
        }
    }

    private func rangeTags(size: CGSize, screen: Bool) -> some View {
        ForEach(screen ? [AxisTag.screenLow, .screenHigh] : [.keyboardLow, .keyboardHigh], id: \.self) { tag in
            tagView(tag)
                .position(tagPosition(tag, size: size))
                .opacity(tag.handle.isKeyboard && !controller.dimsKeyboard || tag.handle.isScreen && !controller.dimsScreen ? 0.35 : 1)
                .disabled(tag.handle.isKeyboard && !controller.dimsKeyboard || tag.handle.isScreen && !controller.dimsScreen)
        }
    }

    private func tagView(_ tag: AxisTag) -> some View {
        return Group {
            // Each number carries its own unit, angle flush right and percentage flush left, so the dot
            // between them sits evenly whatever the digit counts.
            if tag.handle.isZone {
                angleField(tag, width: 30)
            } else {
                HStack(spacing: 5) {
                    angleField(tag, width: 30)
                    Circle().fill(secondary.opacity(0.7)).frame(width: 3, height: 3)
                    levelField(tag, width: 36)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Capsule().fill(fieldColour))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
    }

    private func angleField(_ tag: AxisTag, width: CGFloat) -> some View {
        numberCell(angleBinding(tag), field: .angle(tag), unit: "°", alignment: .trailing,
                   name: L10n.string("\(tagLabel(tag)) angle"), width: width)
    }

    private func levelField(_ tag: AxisTag, width: CGFloat) -> some View {
        numberCell(levelBinding(tag), field: .level(tag), unit: "%", alignment: .leading,
                   name: L10n.string("\(tagLabel(tag)) brightness"), width: width)
    }

    // A plain text field sat several points below the capsule's baseline (it keeps its own 22 pt cell),
    // so the number is ordinary text until clicked, and a field only while it is being typed in.
    @ViewBuilder
    private func numberCell(_ value: Binding<Double>, field: AxisField, unit: String, alignment: Alignment,
                            name: String, width: CGFloat) -> some View {
        let tag: AxisTag = switch field { case .angle(let t), .level(let t): t }
        if editing == field {
            // Edited in place: a borderless AppKit field at the tag's own font and height, inside the same
            // capsule. SwiftUI's plain TextField kept a 22 pt cell and sat below the capsule.
            HStack(spacing: 0) {
                TagNumberField(value: value.wrappedValue, name: name,
                               rangeDescription: AccessibilityReadout.range(numberRange(field), unit: unit)) { typed, restoringFocus in
                    if let typed { value.wrappedValue = typed }
                    editing = nil
                    if restoringFocus { DispatchQueue.main.async { focusedField = field } }
                }
                .frame(height: 14)
                Text(L10n.displayUnit(unit)).foregroundStyle(secondary)
            }
            .frame(width: width)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(privacyColour, lineWidth: 2).padding(-2))
        } else {
            Button {
                focusedField = nil
                editing = field
            } label: {
                (Text(L10n.string("\(Int(value.wrappedValue.rounded()))")) + Text(L10n.displayUnit(unit)).foregroundColor(secondary))
                    .frame(width: width, alignment: alignment)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(interactions: .edit)
            .focused($focusedField, equals: field)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(focusedField == field ? privacyColour : .clear, lineWidth: 2)
                    .padding(-2)
            }
            .onKeyPress(.return) {
                focusedField = nil
                editing = field
                return .handled
            }
            .onMoveCommand { direction in
                switch field {
                case .angle:
                    if direction == .left || direction == .right { move(tag, direction: direction) }
                case .level:
                    if direction == .up || direction == .down { move(tag, direction: direction) }
                }
            }
            .accessibilityLabel(name)
            .accessibilityValue(AccessibilityReadout.value(value.wrappedValue, unit: unit))
            .accessibilityHint(AccessibilityReadout.rangeForActivation(numberRange(field), unit: unit))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value.wrappedValue += 1
                case .decrement: value.wrappedValue -= 1
                @unknown default: break
                }
            }
        }
    }

    private func numberRange(_ field: AxisField) -> ClosedRange<Double> {
        switch field {
        case .level: return 0...100
        case .angle(let tag):
            let gap = tag.handle.isZone ? 2.0 : 1.0
            return tag.handle.isLow ? 0...(LidAxis.maximum - gap) : gap...LidAxis.maximum
        }
    }

    private func tagLabel(_ tag: AxisTag) -> String {
        switch tag {
        case .keyboardLow: L10n.string("Keyboard low end")
        case .keyboardHigh: L10n.string("Keyboard high end")
        case .screenLow: L10n.string("Screen low end")
        case .screenHigh: L10n.string("Screen high end")
        case .zoneLow: L10n.string("Snap zone low edge")
        case .zoneHigh: L10n.string("Snap zone high edge")
        }
    }

    private func isFocusedField(_ tag: AxisTag) -> Bool {
        switch editing {
        case .angle(let edited), .level(let edited): return edited == tag
        case nil: return false
        }
    }

    private func isKeyboardFocused(_ tag: AxisTag) -> Bool {
        switch focusedField {
        case .angle(let focused), .level(let focused): return focused == tag
        case nil: return isFocusedField(tag)
        }
    }

    private func tagPosition(_ tag: AxisTag, size: CGSize) -> CGPoint {
        let x = xPosition(size: size)
        let point: CGPoint
        let lane: (top: CGFloat, height: CGFloat)
        if tag.handle.isZone {
            let angle = tag.handle.isLow ? features.snap.zoneLow : features.snap.zoneHigh
            point = CGPoint(x: x(angle), y: privacyTop + privacyHeight / 2)
            lane = (privacyTop, privacyHeight)
        } else {
            let range = tag.handle.isScreen ? controller.screenRange : controller.keyboardRange
            let angle = tag.handle.isLow ? range.lowAngle : range.highAngle
            let level = tag.handle.isLow ? range.lowLevel : range.highLevel
            lane = tag.handle.isScreen ? (screenTop, screenHeight) : (keyboardTop, keyboardHeight)
            point = CGPoint(x: x(angle), y: lane.top + lane.height * CGFloat(1 - level))
        }
        let width = tagWidth(tag)
        let clampY = { (y: CGFloat) in min(lane.top + lane.height - 10, max(lane.top + 10, y)) }
        let near = tag.handle.isLow ? point.x - 10 - width / 2 : point.x + 10 + width / 2
        let far = tag.handle.isLow ? point.x + 10 + width / 2 : point.x - 10 - width / 2
        let y = clampY(point.y)
        // Tags dodge the live lid line and their lane's other tag: try the handle's own side, then the
        // other side, then above or below it, and keep the first spot that is clear and inside the plot.
        var candidates = [CGPoint(x: near, y: y), CGPoint(x: far, y: y)]
        if !tag.handle.isZone {
            for dy: CGFloat in [-22, 22] where clampY(point.y + dy) != y {
                candidates += [CGPoint(x: near, y: clampY(point.y + dy)), CGPoint(x: far, y: clampY(point.y + dy))]
            }
        }
        let inside = candidates.filter { $0.x - width / 2 >= gutter + 2 && $0.x + width / 2 <= size.width - rightInset - 2 }
        let sibling: CGRect? = tag.handle.isLow ? nil : {
            let low: AxisTag = tag.handle.isZone ? .zoneLow : (tag.handle.isScreen ? .screenLow : .keyboardLow)
            let centre = tagPosition(low, size: size)
            return CGRect(x: centre.x - tagWidth(low) / 2, y: centre.y - 10, width: tagWidth(low), height: 20)
        }()
        let lidX = controller.angle.map { x($0) }
        let clear = inside.first { c in
            let rect = CGRect(x: c.x - width / 2 - 4, y: c.y - 10, width: width + 8, height: 20)
            let missesLid = lidX.map { !(rect.minX...rect.maxX).contains($0) } ?? true
            let missesSibling = sibling.map { !rect.insetBy(dx: 2, dy: 1).intersects($0) } ?? true
            return missesLid && missesSibling
        }
        return clear ?? inside.first ?? candidates[0]
    }

    private func tagWidth(_ tag: AxisTag) -> CGFloat { tag.handle.isZone ? 42 : 91 }

    private func pointIsInTag(_ point: CGPoint, size: CGSize) -> Bool {
        let candidates = [AxisTag.keyboardLow, .keyboardHigh, .screenLow, .screenHigh] + (features.privacyEnabled ? [.zoneLow, .zoneHigh] : [])
        return candidates.filter { tag in
            (!tag.handle.isKeyboard || controller.dimsKeyboard) && (!tag.handle.isScreen || controller.dimsScreen)
        }.contains { tag in
            let centre = tagPosition(tag, size: size)
            let width = tagWidth(tag)
            return abs(point.x - centre.x) <= width / 2 && abs(point.y - centre.y) <= 10
        }
    }

    private func axisDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if active == nil {
                    guard !pointIsInTag(value.startLocation, size: size) else { return }
                    focusedField = nil
                    active = handle(at: value.startLocation, size: size)
                    if let active { cursor(for: active, dragging: true).set() }
                }
                guard let active else { return }
                drag(active, to: value.location, size: size)
            }
            .onEnded { value in
                guard let active = self.active else { return }
                logger.info("axis drag \(String(describing: active), privacy: .public) ended at \(Int(value.location.x), privacy: .public),\(Int(value.location.y), privacy: .public): keyboard=\(String(describing: controller.keyboardRange), privacy: .public) screen=\(String(describing: controller.screenRange), privacy: .public) zone=\(features.snap.zoneLow, privacy: .public)–\(features.snap.zoneHigh, privacy: .public)")
                self.active = nil
                hovered = handle(at: value.location, size: size)
                (hovered.map { cursor(for: $0, dragging: false) } ?? .arrow).set()
            }
    }

    private func xPosition(size: CGSize) -> (Double) -> CGFloat {
        let width = size.width - gutter - rightInset
        return { gutter + CGFloat(min(max($0 / LidAxis.maximum, 0), 1)) * width }
    }

    private func point(of handle: AxisHandle, size: CGSize) -> CGPoint {
        let x = xPosition(size: size)
        if handle.isZone {
            let angle = handle == .zoneLow ? features.snap.zoneLow : features.snap.zoneHigh
            return CGPoint(x: x(angle), y: privacyTop + privacyHeight / 2)
        }
        let range = handle.isScreen ? controller.screenRange : controller.keyboardRange
        let top = handle.isScreen ? screenTop : keyboardTop
        let height = handle.isScreen ? screenHeight : keyboardHeight
        let level = handle.isLow ? range.lowLevel : range.highLevel
        return CGPoint(x: x(handle.isLow ? range.lowAngle : range.highAngle), y: top + height * CGFloat(1 - level))
    }

    private func handle(at location: CGPoint, size: CGSize) -> AxisHandle? {
        AxisHandle.allCases
            .filter { !$0.isZone || features.privacyEnabled }
            .filter { !$0.isScreen || controller.dimsScreen }
            .filter { $0.isZone || $0.isScreen || controller.dimsKeyboard }
            .map { handle -> (AxisHandle, CGFloat) in
                let point = point(of: handle, size: size)
                let distance = handle.isZone
                    ? (abs(location.y - point.y) <= 22 ? abs(location.x - point.x) : .infinity)
                    : hypot(location.x - point.x, location.y - point.y)
                return (handle, distance)
            }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    private func drag(_ handle: AxisHandle, to location: CGPoint, size: CGSize) {
        let angle = (Double((location.x - gutter) / (size.width - gutter - rightInset)) * LidAxis.maximum).rounded()
        if handle.isZone {
            setZone(isLow: handle.isLow, angle: angle)
            return
        }
        let top = handle.isScreen ? screenTop : keyboardTop
        let height = handle.isScreen ? screenHeight : keyboardHeight
        let level = (min(max(1 - Double((location.y - top) / height), 0), 1) * 100).rounded() / 100
        setRange(tag(for: handle), angle: min(max(angle, 0), LidAxis.maximum), level: level)
    }

    private func cursor(for handle: AxisHandle, dragging: Bool) -> NSCursor {
        if handle.isZone { return .resizeLeftRight }
        return dragging ? .closedHand : .openHand
    }

    private func tag(for handle: AxisHandle) -> AxisTag { AxisTag(rawHandle: handle) }

    private func angleBinding(_ tag: AxisTag) -> Binding<Double> {
        Binding(get: {
            if tag.handle.isZone { return tag.handle.isLow ? features.snap.zoneLow : features.snap.zoneHigh }
            let range = tag.handle.isScreen ? controller.screenRange : controller.keyboardRange
            return tag.handle.isLow ? range.lowAngle : range.highAngle
        }, set: { value in
            if tag.handle.isZone { setZone(isLow: tag.handle.isLow, angle: value) }
            else { setRange(tag, angle: value, level: currentLevel(tag)) }
        })
    }

    private func levelBinding(_ tag: AxisTag) -> Binding<Double> {
        Binding(get: { currentLevel(tag) * 100 }, set: { value in
            setRange(tag, angle: currentAngleForTag(tag), level: value / 100)
        })
    }

    private func currentLevel(_ tag: AxisTag) -> Double {
        let range = tag.handle.isScreen ? controller.screenRange : controller.keyboardRange
        return tag.handle.isLow ? range.lowLevel : range.highLevel
    }

    private func currentAngleForTag(_ tag: AxisTag) -> Double {
        let range = tag.handle.isScreen ? controller.screenRange : controller.keyboardRange
        return tag.handle.isLow ? range.lowAngle : range.highAngle
    }


    private func move(_ tag: AxisTag, direction: MoveCommandDirection) {
        if tag.handle.isZone { adjustZone(isLow: tag.handle.isLow, direction: direction) }
        else { adjustRange(tag, direction: direction) }
    }

    private func setZone(isLow: Bool, angle: Double) {
        var settings = features.snap
        let roundedAngle = min(max(angle.rounded(), 0), LidAxis.maximum)
        if isLow {
            settings.zoneLow = roundedAngle
            settings.zoneHigh = max(settings.zoneHigh, roundedAngle + 2)
        } else {
            settings.zoneHigh = roundedAngle
            settings.zoneLow = min(settings.zoneLow, roundedAngle - 2)
        }
        features.snap = settings.clamped(maximum: LidAxis.maximum)
    }

    private func moveScreenBelowZone() {
        let old = controller.screenRange
        let moved = old.movedBelow(features.snap.zoneLow)
        controller.screenRange = moved
        logger.info("screen range moved below snap zone: \(String(describing: old), privacy: .public) -> \(String(describing: moved), privacy: .public)")
    }

    private func setRange(_ tag: AxisTag, angle: Double, level: Double) {
        let isScreen = tag.handle.isScreen
        let isLow = tag.handle.isLow
        var range = isScreen ? controller.screenRange : controller.keyboardRange
        range = isLow
            ? range.settingLow(angle: angle, level: level, maximum: LidAxis.maximum)
            : range.settingHigh(angle: angle, level: level, maximum: LidAxis.maximum)
        if isScreen { controller.screenRange = range } else { controller.keyboardRange = range }
    }

    private func adjustRange(_ tag: AxisTag, direction: MoveCommandDirection) {
        let isScreen = tag.handle.isScreen
        let isLow = tag.handle.isLow
        var range = isScreen ? controller.screenRange : controller.keyboardRange
        var angle = isLow ? range.lowAngle : range.highAngle
        var level = isLow ? range.lowLevel : range.highLevel
        switch direction {
        case .left: angle -= 1
        case .right: angle += 1
        case .up: level += 0.05
        case .down: level -= 0.05
        @unknown default: break
        }
        range = isLow
            ? range.settingLow(angle: angle, level: level, maximum: LidAxis.maximum)
            : range.settingHigh(angle: angle, level: level, maximum: LidAxis.maximum)
        if isScreen { controller.screenRange = range } else { controller.keyboardRange = range }
    }

    private func adjustZone(isLow: Bool, direction: MoveCommandDirection) {
        var angle = isLow ? features.snap.zoneLow : features.snap.zoneHigh
        switch direction {
        case .left: angle -= 1
        case .right: angle += 1
        case .up, .down: break
        @unknown default: break
        }
        setZone(isLow: isLow, angle: angle)
    }
}

private extension AxisTag {
    init(rawHandle: AxisHandle) {
        switch rawHandle {
        case .keyboardLow: self = .keyboardLow
        case .keyboardHigh: self = .keyboardHigh
        case .screenLow: self = .screenLow
        case .screenHigh: self = .screenHigh
        case .zoneLow: self = .zoneLow
        case .zoneHigh: self = .zoneHigh
        }
    }
}
