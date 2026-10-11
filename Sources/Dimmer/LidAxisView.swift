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

enum AxisLane: CaseIterable {
    case keyboard, screen, privacy, blur

    var colour: Color {
        switch self {
        case .keyboard: Color(hex: 0xE9C891)
        case .screen: Color(hex: 0xE2E5EA)
        case .privacy: Color(hex: 0xB9C8E6)
        case .blur: Color(hex: 0xC9B6E4)
        }
    }

    var title: String {
        switch self {
        case .keyboard: L10n.string("Keyboard")
        case .screen: L10n.string("Screen")
        case .privacy: L10n.string("Snap to blur")
        case .blur: L10n.string("Blur by angle")
        }
    }

    var height: CGFloat { self == .privacy ? 30 : 54 }

    var handles: [AxisHandle] {
        switch self {
        case .keyboard: [.keyboardLow, .keyboardHigh]
        case .screen: [.screenLow, .screenHigh]
        case .privacy: [.zoneLow, .zoneHigh]
        case .blur: [.blurLow, .blurHigh]
        }
    }

    // What Cmd+Z is called after a drag or an edit on this lane's bar.
    var actionName: String.LocalizationValue {
        switch self {
        case .keyboard, .screen: "Brightness range"
        case .privacy: "Privacy settings"
        case .blur: "Blur range"
        }
    }

    @MainActor
    func live(controller: DimmerController, features: DimmerFeatures, reading: LidReading, lanes: AngleLaneReading) -> String {
        let angle = reading.angle ?? 0
        switch self {
        case .keyboard:
            return L10n.string("now \(Int((controller.keyboardRange.level(at: angle) * 100).rounded()))%")
        case .screen:
            guard reading.angle != nil, angle < controller.screenRange.highAngle else { return L10n.string("now untouched") }
            return L10n.string("now \(Int((controller.screenRange.level(at: angle) * 100).rounded()))%")
        case .privacy:
            guard reading.angle != nil else { return L10n.string("snap zone") }
            return angle >= features.snap.zoneLow && angle <= features.snap.zoneHigh ? L10n.string("lid in zone") : L10n.string("snap zone")
        case .blur:
            guard let percent = lanes.blurPercent else { return L10n.string("now none") }
            return L10n.string("now \(percent)%")
        }
    }
}

enum AxisHandle: CaseIterable, Hashable {
    case keyboardLow, keyboardHigh, screenLow, screenHigh, zoneLow, zoneHigh, blurLow, blurHigh

    var lane: AxisLane {
        switch self {
        case .keyboardLow, .keyboardHigh: .keyboard
        case .screenLow, .screenHigh: .screen
        case .zoneLow, .zoneHigh: .privacy
        case .blurLow, .blurHigh: .blur
        }
    }

    var isZone: Bool { lane == .privacy }
    var isLow: Bool { self == .keyboardLow || self == .screenLow || self == .zoneLow || self == .blurLow }
    var lowPartner: AxisHandle { lane.handles[0] }
}

enum AxisField: Hashable {
    case angle(AxisHandle), level(AxisHandle)
}

private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}

// One feature's bar on the lid-angle scale: its ramp (or the snap zone), the number boxes on each end, the
// live lid marker and the angle axis. Each Settings box holds one, so the bars share a scale and line up.
struct LidAxisView: View {
    let lane: AxisLane
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var history: SettingsHistory
    // The lid marker, the capsule and the tags that dodge it follow the shown angle, not every sample.
    @ObservedObject private var reading: LidReading
    @State private var active: AxisHandle?
    @State private var hovered: AxisHandle?
    @FocusState private var focusedField: AxisField?

    init(lane: AxisLane, controller: DimmerController, features: DimmerFeatures, history: SettingsHistory) {
        self.lane = lane
        self.controller = controller
        self.features = features
        self.history = history
        reading = controller.reading
    }

    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "settings")
    private let reach: CGFloat = 14
    private let rightInset: CGFloat = 10
    private let top: CGFloat = 10
    private let privacyColour = Color(hex: 0xB9C8E6)
    private let secondary = Color(hex: 0x9A9EA7)
    private let fieldColour = Color(hex: 0x232328)

    // The same for every bar, so the scales line up down the page; wide enough for "Lid angle" in any language.
    private var gutter: CGFloat { ceil(max(56, textWidth(L10n.string("Lid angle"), size: 11) + 16)) }
    private var height: CGFloat { lane.height }
    private var colour: Color { lane.colour }
    private var axisY: CGFloat { top + height + 26 }
    private var plotHeight: CGFloat { axisY + 26 }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in drawAxis(in: &context, size: canvasSize) }
                ForEach(lane.handles, id: \.self) { handle in
                    tagView(handle).position(tagPosition(handle, size: size))
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
        .frame(height: plotHeight)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
    }

    // The tag number being typed in. Separate from focus: the field must exist before it can take focus,
    // so a click sets this and the field focuses itself when it appears.
    @State private var editing: AxisField?

    private var currentAngle: Double { reading.angle ?? 0 }

    private func drawAxis(in context: inout GraphicsContext, size: CGSize) {
        let x = xPosition(size: size)
        if lane == .privacy {
            drawZone(in: &context, size: size, x: x)
        } else {
            drawRamp(in: &context, range: range(for: lane), x: x)
            drawScale(in: &context)
        }
        drawAngleAxis(in: &context, x: x)

        if let angle = reading.angle {
            let markerX = x(angle)
            var marker = Path()
            marker.move(to: CGPoint(x: markerX, y: top - 2))
            marker.addLine(to: CGPoint(x: markerX, y: axisY + 6))
            context.stroke(marker, with: .color(Color.white.opacity(0.7)), lineWidth: 1)
            if lane != .privacy, !(lane == .screen && angle >= controller.screenRange.highAngle) {
                let y = top + height * CGFloat(1 - range(for: lane).level(at: angle))
                context.fill(Path(ellipseIn: CGRect(x: markerX - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(.white))
            }
            let capsuleWidth = lidCapsuleWidth(angle)
            let capsuleX = min(max(markerX, gutter + capsuleWidth / 2), size.width - capsuleWidth / 2)
            let capsule = CGRect(x: capsuleX - capsuleWidth / 2, y: axisY + 7, width: capsuleWidth, height: 17)
            context.fill(Path(roundedRect: capsule, cornerRadius: 8.5), with: .color(.white))
            context.draw(Text(L10n.string("Lid \(Int(angle.rounded()))°")).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: 0x141416)), at: CGPoint(x: capsule.midX, y: capsule.midY))
        }
        if lane == .screen { drawUntouchedLabel(in: &context, x: x) }
        if lane == .privacy {
            drawZoneHandles(in: &context, x: x)
        } else {
            drawRangeHandles(in: &context, x: x)
        }
    }

    private func drawZone(in context: inout GraphicsContext, size: CGSize, x: (Double) -> CGFloat) {
        let well = CGRect(x: gutter, y: top, width: size.width - gutter - rightInset, height: height)
        context.fill(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x111113)))
        context.stroke(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x2A2A30)), lineWidth: 0.5)
        let zoneRect = CGRect(x: x(features.snap.zoneLow), y: top + 1,
                              width: max(x(features.snap.zoneHigh) - x(features.snap.zoneLow), 2), height: height - 2)
        let zonePath = Path(roundedRect: zoneRect, cornerRadius: 2)
        context.fill(zonePath, with: .color(privacyColour.opacity(0.22)))
        context.stroke(zonePath, with: .color(privacyColour.opacity(0.55)), lineWidth: 0.5)
        let zoneLabel = context.resolve(Text(L10n.string("Snap zone")).font(.system(size: 11, weight: .medium)).foregroundColor(privacyColour))
        let labelWidth = zoneLabel.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width + 8
        let labelRect = CGRect(x: zoneRect.midX - labelWidth / 2, y: zoneRect.midY - 8, width: labelWidth, height: 16)
        let labelClear = lane.handles.allSatisfy { handle in
            let centre = tagPosition(handle, size: size)
            let width = tagWidth(handle)
            return !labelRect.intersects(CGRect(x: centre.x - width / 2, y: centre.y - 10, width: width, height: 20))
        }
        if zoneRect.width > labelWidth && labelClear {
            context.draw(zoneLabel, at: CGPoint(x: zoneRect.midX, y: zoneRect.midY))
        }
        for angle in [features.snap.zoneLow, features.snap.zoneHigh] {
            let bar = CGRect(x: x(angle) - 2, y: top - 3, width: 4, height: height + 6)
            let barPath = Path(roundedRect: bar, cornerRadius: 2)
            context.fill(barPath, with: .color(privacyColour))
            context.stroke(barPath, with: .color(Color(hex: 0x141416)), lineWidth: 1)
        }
    }

    // Above its top end the screen is left at the user's own brightness; say so in words, sized to fit.
    // Like the tags it dodges the lid line: the long words if they fit in the stretch on either side
    // of the line, else the short word, else nothing.
    private func drawUntouchedLabel(in context: inout GraphicsContext, x: (Double) -> CGFloat) {
        let start = x(controller.screenRange.highAngle) + 6, end = x(LidAxis.maximum) - 6
        let lidX = reading.angle.map { x($0) }
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
            L10n.string("your own brightness, untouched"), L10n.string("untouched"),
        ].lazy.compactMap { option in
            let width = textWidth(option, size: 11) + 8
            return gaps.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
                .flatMap { $0.upperBound - $0.lowerBound >= width ? (option, width, $0) : nil }
        }.first
        if let (words, labelWidth, gap) = choice {
            let labelRect = CGRect(x: (gap.lowerBound + gap.upperBound) / 2 - labelWidth / 2,
                                   y: top + height / 2 - 7, width: labelWidth, height: 14)
            context.fill(Path(roundedRect: labelRect, cornerRadius: 3), with: .color(Color(hex: 0x111113)))
            context.draw(Text(words).font(.system(size: 11)).foregroundColor(secondary),
                         at: CGPoint(x: labelRect.midX, y: labelRect.midY))
        }
    }

    private func drawRamp(in context: inout GraphicsContext, range: DimRange, x: (Double) -> CGFloat) {
        let floor = top + height
        let y: (Double) -> CGFloat = { top + height * CGFloat(1 - min(max($0, 0), 1)) }
        let isScreen = lane == .screen
        let end = isScreen ? range.highAngle : LidAxis.maximum
        let well = CGRect(x: gutter, y: top, width: x(LidAxis.maximum) - gutter, height: height)
        context.fill(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x111113)))
        context.stroke(Path(roundedRect: well, cornerRadius: 4), with: .color(Color(hex: 0x2A2A30)), lineWidth: 0.5)
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
                Gradient(colors: [colour.opacity(0.30), colour.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: floor)))
        }

        var line = Path()
        line.move(to: CGPoint(x: x(0), y: y(range.lowLevel)))
        line.addLine(to: CGPoint(x: x(range.lowAngle), y: y(range.lowLevel)))
        line.addLine(to: CGPoint(x: x(range.highAngle), y: y(range.highLevel)))
        line.addLine(to: CGPoint(x: x(end), y: y(range.highLevel)))
        context.stroke(line, with: .color(colour),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        if isScreen {
            var drop = Path()
            drop.move(to: CGPoint(x: x(range.highAngle), y: y(range.highLevel)))
            drop.addLine(to: CGPoint(x: x(range.highAngle), y: floor))
            context.stroke(drop, with: .color(colour.opacity(0.35)), lineWidth: 0.75)
        }
    }

    private func drawScale(in context: inout GraphicsContext) {
        for (text, y) in [(L10n.string("100%"), top + 4), (L10n.string("0%"), top + height - 1)] {
            context.draw(Text(text).font(.system(size: 11).monospacedDigit()).foregroundColor(secondary),
                         at: CGPoint(x: gutter - 8, y: y), anchor: .trailing)
        }
    }

    // The white "Lid N°" capsule sits on the label row; a tick label under it would show through its edges.
    private func underLidCapsule(_ labelX: CGFloat, x: (Double) -> CGFloat) -> Bool {
        guard let angle = reading.angle else { return false }
        let width = lidCapsuleWidth(angle)
        let centre = min(max(x(angle), gutter + width / 2), x(LidAxis.maximum) + rightInset - width / 2)
        return abs(labelX - centre) < width / 2 + 18
    }

    private func lidCapsuleWidth(_ angle: Double) -> CGFloat {
        let text = L10n.string("Lid \(Int(angle.rounded()))°")
        return ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width) + 12
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

    private func drawRangeHandles(in context: inout GraphicsContext, x: (Double) -> CGFloat) {
        let range = range(for: lane)
        for (handle, angle, level) in [(lane.handles[0], range.lowAngle, range.lowLevel), (lane.handles[1], range.highAngle, range.highLevel)] {
            let point = CGPoint(x: x(angle), y: top + height * CGFloat(1 - level))
            let circle = Path(ellipseIn: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11))
            context.fill(circle, with: .color(colour))
            context.stroke(circle, with: .color(Color(hex: 0x141416)), lineWidth: 1.5)
            if isKeyboardFocused(handle) {
                let ring = Path(ellipseIn: CGRect(x: point.x - 9.5, y: point.y - 9.5, width: 19, height: 19))
                context.stroke(ring, with: .color(privacyColour.opacity(0.55)), lineWidth: 2)
            }
        }
    }

    private func drawZoneHandles(in context: inout GraphicsContext, x: (Double) -> CGFloat) {
        for (handle, angle) in [(AxisHandle.zoneLow, features.snap.zoneLow), (.zoneHigh, features.snap.zoneHigh)] {
            let rect = CGRect(x: x(angle) - 2, y: top - 3, width: 4, height: height + 6)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            if isKeyboardFocused(handle) {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 4),
                               with: .color(privacyColour.opacity(0.55)), lineWidth: 2)
            }
            context.fill(path, with: .color(privacyColour))
            context.stroke(path, with: .color(Color(hex: 0x141416)), lineWidth: 1)
        }
    }

    private func tagView(_ handle: AxisHandle) -> some View {
        Group {
            // Each number carries its own unit, angle flush right and percentage flush left, so the dot
            // between them sits evenly whatever the digit counts.
            if handle.isZone {
                angleField(handle, width: 30)
            } else {
                HStack(spacing: 5) {
                    angleField(handle, width: 30)
                    Circle().fill(secondary.opacity(0.7)).frame(width: 3, height: 3)
                    levelField(handle, width: 36)
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

    private func angleField(_ handle: AxisHandle, width: CGFloat) -> some View {
        numberCell(angleBinding(handle), field: .angle(handle), unit: "°", alignment: .trailing,
                   name: L10n.string("\(tagLabel(handle)) angle"), width: width)
    }

    private func levelField(_ handle: AxisHandle, width: CGFloat) -> some View {
        numberCell(levelBinding(handle), field: .level(handle), unit: "%", alignment: .leading,
                   name: handle.lane == .blur ? L10n.string("\(tagLabel(handle)) strength") : L10n.string("\(tagLabel(handle)) brightness"),
                   width: width)
    }

    // A plain text field sat several points below the capsule's baseline (it keeps its own 22 pt cell),
    // so the number is ordinary text until clicked, and a field only while it is being typed in.
    @ViewBuilder
    private func numberCell(_ value: Binding<Double>, field: AxisField, unit: String, alignment: Alignment,
                            name: String, width: CGFloat) -> some View {
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
            .onMoveCommand { moveCommand($0, field: field) }
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
        case .angle(let handle):
            let gap = handle.isZone ? 2.0 : 1.0
            return handle.isLow ? 0...(LidAxis.maximum - gap) : gap...LidAxis.maximum
        }
    }

    private func tagLabel(_ handle: AxisHandle) -> String {
        switch handle {
        case .keyboardLow: L10n.string("Keyboard low end")
        case .keyboardHigh: L10n.string("Keyboard high end")
        case .screenLow: L10n.string("Screen low end")
        case .screenHigh: L10n.string("Screen high end")
        case .blurLow: L10n.string("Blur low end")
        case .blurHigh: L10n.string("Blur high end")
        case .zoneLow: L10n.string("Snap zone low edge")
        case .zoneHigh: L10n.string("Snap zone high edge")
        }
    }

    private func isFocusedField(_ handle: AxisHandle) -> Bool {
        switch editing {
        case .angle(let edited), .level(let edited): return edited == handle
        case nil: return false
        }
    }

    private func isKeyboardFocused(_ handle: AxisHandle) -> Bool {
        switch focusedField {
        case .angle(let focused), .level(let focused): return focused == handle
        case nil: return isFocusedField(handle)
        }
    }

    private func tagPosition(_ handle: AxisHandle, size: CGSize) -> CGPoint {
        let x = xPosition(size: size)
        let point: CGPoint
        if handle.isZone {
            let angle = handle.isLow ? features.snap.zoneLow : features.snap.zoneHigh
            point = CGPoint(x: x(angle), y: top + height / 2)
        } else {
            let range = range(for: lane)
            let angle = handle.isLow ? range.lowAngle : range.highAngle
            let level = handle.isLow ? range.lowLevel : range.highLevel
            point = CGPoint(x: x(angle), y: top + height * CGFloat(1 - level))
        }
        let width = tagWidth(handle)
        let clampY = { (y: CGFloat) in min(top + height - 10, max(top + 10, y)) }
        let near = handle.isLow ? point.x - 10 - width / 2 : point.x + 10 + width / 2
        let far = handle.isLow ? point.x + 10 + width / 2 : point.x - 10 - width / 2
        let y = clampY(point.y)
        // Tags dodge the live lid line and their lane's other tag: try the handle's own side, then the
        // other side, then above or below it, and keep the first spot that is clear and inside the plot.
        var candidates = [CGPoint(x: near, y: y), CGPoint(x: far, y: y)]
        if !handle.isZone {
            for dy: CGFloat in [-22, 22] where clampY(point.y + dy) != y {
                candidates += [CGPoint(x: near, y: clampY(point.y + dy)), CGPoint(x: far, y: clampY(point.y + dy))]
            }
        }
        let inside = candidates.filter { $0.x - width / 2 >= gutter + 2 && $0.x + width / 2 <= size.width - rightInset - 2 }
        let sibling: CGRect? = handle.isLow ? nil : {
            let low = handle.lowPartner
            let centre = tagPosition(low, size: size)
            return CGRect(x: centre.x - tagWidth(low) / 2, y: centre.y - 10, width: tagWidth(low), height: 20)
        }()
        let lidX = reading.angle.map { x($0) }
        let clear = inside.first { c in
            let rect = CGRect(x: c.x - width / 2 - 4, y: c.y - 10, width: width + 8, height: 20)
            let missesLid = lidX.map { !(rect.minX...rect.maxX).contains($0) } ?? true
            let missesSibling = sibling.map { !rect.insetBy(dx: 2, dy: 1).intersects($0) } ?? true
            return missesLid && missesSibling
        }
        return clear ?? inside.first ?? candidates[0]
    }

    private func tagWidth(_ handle: AxisHandle) -> CGFloat { handle.isZone ? 42 : 91 }

    private func pointIsInTag(_ point: CGPoint, size: CGSize) -> Bool {
        lane.handles.contains { handle in
            let centre = tagPosition(handle, size: size)
            let width = tagWidth(handle)
            return abs(point.x - centre.x) <= width / 2 && abs(point.y - centre.y) <= 10
        }
    }

    private func axisDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if active == nil {
                    guard !pointIsInTag(value.startLocation, size: size) else { return }
                    focusedField = nil
                    active = beginDrag(at: value.startLocation, size: size)
                    if let active { cursor(for: active, dragging: true).set() }
                }
                guard let active else { return }
                drag(active, to: value.location, size: size)
            }
            .onEnded { value in
                guard let active = self.active else { return }
                history.endGesture()
                logger.info("axis drag \(String(describing: active), privacy: .public) ended at \(Int(value.location.x), privacy: .public),\(Int(value.location.y), privacy: .public): keyboard=\(String(describing: controller.keyboardRange), privacy: .public) screen=\(String(describing: controller.screenRange), privacy: .public) zone=\(features.snap.zoneLow, privacy: .public)–\(features.snap.zoneHigh, privacy: .public)")
                self.active = nil
                hovered = handle(at: value.location, size: size)
                (hovered.map { cursor(for: $0, dragging: false) } ?? .arrow).set()
            }
    }

    // Opens the undo gesture under this lane's own name, so Cmd+Z reads "Undo Blur range" after a Blur drag.
    func beginDrag(at start: CGPoint, size: CGSize) -> AxisHandle? {
        guard let handle = handle(at: start, size: size) else { return nil }
        history.beginGesture(lane.actionName)
        return handle
    }

    private func xPosition(size: CGSize) -> (Double) -> CGFloat {
        let width = size.width - gutter - rightInset
        let origin = gutter
        return { origin + CGFloat(min(max($0 / LidAxis.maximum, 0), 1)) * width }
    }

    func point(of handle: AxisHandle, size: CGSize) -> CGPoint {
        let x = xPosition(size: size)
        if handle.isZone {
            let angle = handle == .zoneLow ? features.snap.zoneLow : features.snap.zoneHigh
            return CGPoint(x: x(angle), y: top + height / 2)
        }
        let range = range(for: lane)
        let level = handle.isLow ? range.lowLevel : range.highLevel
        return CGPoint(x: x(handle.isLow ? range.lowAngle : range.highAngle), y: top + height * CGFloat(1 - level))
    }

    private func handle(at location: CGPoint, size: CGSize) -> AxisHandle? {
        lane.handles
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

    func drag(_ handle: AxisHandle, to location: CGPoint, size: CGSize) {
        let angle = (Double((location.x - gutter) / (size.width - gutter - rightInset)) * LidAxis.maximum).rounded()
        if handle.isZone {
            setZone(isLow: handle.isLow, angle: angle)
            return
        }
        let level = (min(max(1 - Double((location.y - top) / height), 0), 1) * 100).rounded() / 100
        setRange(handle, angle: min(max(angle, 0), LidAxis.maximum), level: level)
    }

    private func cursor(for handle: AxisHandle, dragging: Bool) -> NSCursor {
        if handle.isZone { return .resizeLeftRight }
        return dragging ? .closedHand : .openHand
    }

    private func angleBinding(_ handle: AxisHandle) -> Binding<Double> {
        Binding(get: {
            if handle.isZone { return handle.isLow ? features.snap.zoneLow : features.snap.zoneHigh }
            let range = range(for: lane)
            return handle.isLow ? range.lowAngle : range.highAngle
        }, set: { value in
            if handle.isZone { setZone(isLow: handle.isLow, angle: value) }
            else { setRange(handle, angle: value, level: currentLevel(handle)) }
        })
    }

    private func levelBinding(_ handle: AxisHandle) -> Binding<Double> {
        Binding(get: { currentLevel(handle) * 100 }, set: { value in
            setRange(handle, angle: currentAngleForHandle(handle), level: value / 100)
        })
    }

    private func currentLevel(_ handle: AxisHandle) -> Double {
        let range = range(for: lane)
        return handle.isLow ? range.lowLevel : range.highLevel
    }

    private func currentAngleForHandle(_ handle: AxisHandle) -> Double {
        let range = range(for: lane)
        return handle.isLow ? range.lowAngle : range.highAngle
    }

    func moveCommand(_ direction: MoveCommandDirection, field: AxisField) {
        switch field {
        case .angle(let handle), .level(let handle):
            move(handle, direction: direction, coalescing: "\(field)")
        }
    }

    private func move(_ handle: AxisHandle, direction: MoveCommandDirection, coalescing control: String) {
        if handle.isZone { adjustZone(isLow: handle.isLow, direction: direction, coalescing: control) }
        else { adjustRange(handle, direction: direction, coalescing: control) }
    }

    private func setZone(isLow: Bool, angle: Double, coalescing: String? = nil) {
        history.change(lane.actionName, coalescing: coalescing) {
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
    }

    private func setRange(_ handle: AxisHandle, angle: Double, level: Double) {
        history.change(lane.actionName) {
            let isLow = handle.isLow
            var range = range(for: lane)
            range = isLow
                ? range.settingLow(angle: angle, level: level, maximum: LidAxis.maximum)
                : range.settingHigh(angle: angle, level: level, maximum: LidAxis.maximum)
            setRange(range, for: lane)
        }
    }

    private func range(for lane: AxisLane) -> DimRange {
        switch lane {
        case .blur: features.angleBlurRange
        case .screen: controller.screenRange
        case .keyboard, .privacy: controller.keyboardRange
        }
    }

    private func setRange(_ range: DimRange, for lane: AxisLane) {
        switch lane {
        case .blur: features.angleBlurRange = range
        case .screen: controller.screenRange = range
        case .keyboard, .privacy: controller.keyboardRange = range
        }
    }

    private func adjustRange(_ handle: AxisHandle, direction: MoveCommandDirection, coalescing control: String) {
        history.change(lane.actionName, coalescing: control) {
            let isLow = handle.isLow
            var range = range(for: lane)
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
            setRange(range, for: lane)
        }
    }

    private func adjustZone(isLow: Bool, direction: MoveCommandDirection, coalescing control: String) {
        var angle = isLow ? features.snap.zoneLow : features.snap.zoneHigh
        switch direction {
        case .left: angle -= 1
        case .right: angle += 1
        case .up, .down:
            history.change(lane.actionName, coalescing: control) {
                var settings = features.snap
                settings.blurStrength += direction == .up ? 0.05 : -0.05
                features.snap = settings.clamped(maximum: LidAxis.maximum)
            }
            return
        @unknown default: break
        }
        setZone(isLow: isLow, angle: angle, coalescing: control)
    }
}

// The link-style label for a restore action. A plain button drawn with an explicit colour does not dim
// itself when disabled, so the state is drawn here, at the same 0.38 the dimmed settings rows use.
struct RestoreLinkLabel: View {
    let title: String
    let enabled: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: 0xB9C8E6))
            .underline()
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.38)
    }
}
