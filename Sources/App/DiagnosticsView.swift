import SwiftUI

/// M0 smoke test: if this renders on the phone, the whole Mac-less toolchain
/// works — XcodeGen manifest, CI build, unsigned IPA packaging, Sideloadly
/// install. No camera session is started here.
struct DiagnosticsView: View {
    private let camera = DeviceInfo.cameraCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            VStack(alignment: .leading, spacing: 12) {
                Row("Version", "\(DeviceInfo.version) (\(DeviceInfo.build))")
                Row("Built", DeviceInfo.buildDate)
                Row("Device", DeviceInfo.modelName)
                Row("Identifier", DeviceInfo.modelIdentifier)
                Row("System", DeviceInfo.systemVersion)
            }

            Divider().overlay(Color.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 12) {
                Row("Back camera", camera.available ? "present" : "missing")
                Row("Best format", camera.best)

                HStack {
                    Text("4K30 capable")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(camera.supports4K30 ? "yes" : "no",
                          systemImage: camera.supports4K30 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(camera.supports4K30 ? .green : .red)
                }
                .font(.system(.body, design: .monospaced))
            }

            Spacer()

            Text("M0 — toolchain proof. No capture session is running.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("XRCam")
                .font(.largeTitle.bold())
            Text("iPhone → OBS over USB")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Label/value pair, monospaced so successive builds are easy to eyeball-diff.
private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(.body, design: .monospaced))
    }
}
