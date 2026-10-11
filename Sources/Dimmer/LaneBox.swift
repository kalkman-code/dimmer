import SwiftUI

// One Settings box per feature: a title row with the live reading and the feature's own switch, and, only
// while the switch is on, its bar on the lid-angle scale, its restore link and whatever else belongs to it.
struct LaneBox<Extra: View>: View {
    let lane: AxisLane
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var history: SettingsHistory
    @ViewBuilder let extra: () -> Extra

    private let secondary = Color(hex: 0x9A9EA7)

    init(lane: AxisLane, controller: DimmerController, features: DimmerFeatures, history: SettingsHistory,
         @ViewBuilder extra: @escaping () -> Extra) {
        self.lane = lane
        self.controller = controller
        self.features = features
        self.history = history
        self.extra = extra
    }

    var body: some View {
        Group {
            // Title and bar are one row, so the Form draws no divider between a feature and its own bar.
            VStack(alignment: .leading, spacing: 4) {
                LaneHeader(lane: lane, isOn: isOn, controller: controller, features: features, history: history)
                if isOn.wrappedValue {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LidAxisView(lane: lane, controller: controller, features: features, history: history)
                }
            }
            .padding(.vertical, 2)
            if isOn.wrappedValue { extra() }
        }
    }

    private var isOn: Binding<Bool> {
        switch lane {
        case .keyboard: $controller.dimsKeyboard
        case .screen: $controller.dimsScreen
        case .privacy: $features.privacyEnabled
        case .blur: $features.angleBlurEnabled
        }
    }

    private var detail: String? {
        switch lane {
        case .keyboard, .screen: nil
        case .privacy: L10n.string("Snap the lid down into the zone and every screen frosts at once. Typing, touching the trackpad or mouse, or pushing the lid back up clears it.")
        case .blur: L10n.string("The screen blurs more the further the lid closes, between the two ends you set on the bar. Off when Reduce Transparency is on; paused, asleep and Go dark clear it.")
        }
    }
}

// The single line above a bar: the feature's name, its live reading, its restore link and its switch. One
// line in every language, which is what the fit test holds it to.
struct LaneHeader: View {
    let lane: AxisLane
    let isOn: Binding<Bool>
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var history: SettingsHistory

    private let secondary = Color(hex: 0x9A9EA7)

    private var switchLabel: String {
        switch lane {
        case .keyboard: L10n.string("Dim the keyboard")
        case .screen: L10n.string("Dim the screen too")
        case .privacy: L10n.string("Blur when the lid is snapped into the zone")
        case .blur: L10n.string("Blur the screen as the lid closes")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lane.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lane.colour)
                if isOn.wrappedValue {
                    LaneLiveText(lane: lane, controller: controller, features: features,
                                 reading: controller.reading, lanes: features.laneReading)
                } else {
                    Text(L10n.string("off"))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            if isOn.wrappedValue { restoreControl }
            Toggle(switchLabel, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var restoreControl: some View {
        switch lane {
        case .keyboard:
            restoreLink(L10n.string("Restore keyboard range"), enabled: controller.keyboardRange != .keyboardDefault,
                        help: L10n.string("Restores the keyboard range to \(Int(DimRange.keyboardDefault.lowAngle))° off, \(Int(DimRange.keyboardDefault.highAngle))° full. Undo with Cmd+Z."),
                        action: history.restoreKeyboardRange)
        case .screen:
            restoreLink(L10n.string("Restore screen range"), enabled: controller.screenRange != .screenDefault,
                        help: L10n.string("Restores the screen range to \(Int(DimRange.screenDefault.lowAngle))° off, \(Int(DimRange.screenDefault.highAngle))° full. Undo with Cmd+Z."),
                        action: history.restoreScreenRange)
        case .blur:
            BlurRestoreLink(features: features, tint: features.angleBlurTint, history: history)
        case .privacy:
            EmptyView()
        }
    }

    private func restoreLink(_ title: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RestoreLinkLabel(title: title, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct BlurRestoreLink: View {
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var tint: VeilTintSettings
    @ObservedObject var history: SettingsHistory

    private var isDefault: Bool {
        features.angleBlurRange == .blurDefault && tint.value == VeilTintSettings.defaultValue
    }

    var body: some View {
        Button { history.restoreBlurRange() } label: {
            RestoreLinkLabel(title: L10n.string("Restore blur defaults"), enabled: !isDefault)
        }
        .buttonStyle(.plain)
        .disabled(isDefault)
        .help(L10n.string("Restores the blur range and tint to their defaults. Undo with Cmd+Z."))
        .accessibilityLabel(L10n.string("Restore blur defaults"))
    }
}

// The live reading beside a box's title. Its own view, observing the readings, so a lid sample redraws this
// one line rather than the box.
private struct LaneLiveText: View {
    let lane: AxisLane
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var reading: LidReading
    @ObservedObject var lanes: AngleLaneReading

    var body: some View {
        Text(lane.live(controller: controller, features: features, reading: reading, lanes: lanes))
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: 0x9A9EA7))
            .accessibilityHidden(true)
    }
}
