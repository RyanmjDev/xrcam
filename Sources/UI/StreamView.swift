import SwiftUI

struct StreamView: View {
    @StateObject private var controller = StreamController()
    @State private var showDiagnostics = false
    @State private var showControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: controller.capture.session)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 0) {
                if showControls {
                    ControlsPanel(controls: controller.controls)
                        .padding(.trailing, 16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
            }
            .padding(20)
        }
        .statusBarHidden()
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top) {
            statusPill

            Spacer()

            if controller.isRunning {
                stats
            }

            Button {
                showDiagnostics = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.leading, 12)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(controller.statusMessage)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var statusColor: Color {
        switch controller.transport {
        case .connected: return .green
        case .listening: return .yellow
        case .failed:    return .red
        case .idle:      return .gray
        }
    }

    private var stats: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1f Mb/s", controller.megabitsPerSecond))
            Text("\(controller.framesSent) sent")
            if controller.framesDropped > 0 {
                Text("\(controller.framesDropped) dropped")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showControls.toggle() }
            } label: {
                Image(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
                    .font(.title2)
                    .foregroundStyle(showControls ? Color.accentColor : .white.opacity(0.8))
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }

            // Format changes require reconfiguring the session, so both are
            // only offered while stopped.
            Picker("Resolution", selection: $controller.resolution) {
                ForEach(CaptureEngine.Resolution.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(controller.isRunning)
            .opacity(controller.isRunning ? 0.4 : 1)

            Picker("Frame rate", selection: $controller.frameRate) {
                ForEach(CaptureEngine.FrameRate.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(controller.isRunning)
            .opacity(controller.isRunning ? 0.4 : 1)

            Spacer()

            Button {
                Task {
                    if controller.isRunning {
                        controller.stop()
                    } else {
                        await controller.start()
                    }
                }
            } label: {
                Text(controller.isRunning ? "Stop" : "Start")
                    .font(.headline)
                    .frame(width: 110, height: 48)
                    .background(controller.isRunning ? Color.red : Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        }
    }
}
