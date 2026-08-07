import SwiftUI

/// Manual camera controls, overlaid on the preview.
///
/// Every control stays live while streaming — locking exposure mid-take is
/// the normal case, not an edge case.
struct ControlsPanel: View {
    @ObservedObject var controls: DeviceControls

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                exposureSection
                divider
                focusSection
                divider
                whiteBalanceSection

                if let error = controls.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - Exposure

    private var exposureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Exposure",
                          isAuto: $controls.exposureAuto,
                          supported: controls.supportsManualExposure)

            if !controls.exposureAuto {
                Labeled("ISO", String(Int(controls.iso))) {
                    Slider(value: $controls.iso,
                           in: controls.isoRange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("SHUTTER")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Discrete stops rather than a slider: shutter is chosen
                    // in known increments, and 1/60 at 30fps is the 180°
                    // shutter most footage wants.
                    Picker("Shutter", selection: $controls.shutterDenominator) {
                        ForEach(controls.shutterOptions, id: \.self) { value in
                            Text("1/\(Int(value))").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: - Focus

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Focus",
                          isAuto: $controls.focusAuto,
                          supported: controls.supportsManualFocus)

            if !controls.focusAuto {
                Labeled("Distance", focusLabel) {
                    Slider(value: $controls.lensPosition, in: 0...1)
                }
            }
        }
    }

    private var focusLabel: String {
        switch controls.lensPosition {
        case ..<0.05: return "near"
        case 0.95...: return "∞"
        default: return String(format: "%.2f", controls.lensPosition)
        }
    }

    // MARK: - White balance

    private var whiteBalanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "White Balance",
                          isAuto: $controls.whiteBalanceAuto,
                          supported: controls.supportsManualWhiteBalance)

            if !controls.whiteBalanceAuto {
                Labeled("Temp", "\(Int(controls.temperature))K") {
                    Slider(value: $controls.temperature, in: 2000...10000)
                }
                Labeled("Tint", String(Int(controls.tint))) {
                    Slider(value: $controls.tint, in: -150...150)
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct SectionHeader: View {
    let title: String
    @Binding var isAuto: Bool
    let supported: Bool

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if supported {
                Picker("", selection: $isAuto) {
                    Text("Auto").tag(true)
                    Text("Manual").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            } else {
                Text("unsupported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Labeled<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder let content: Content

    init(_ label: String, _ value: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
            }
            content
                .tint(.white)
        }
    }
}
