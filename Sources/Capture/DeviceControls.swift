import AVFoundation
import Combine
import Foundation

/// Manual exposure, focus and white balance over an `AVCaptureDevice`.
///
/// This is the reason the project exists: with everything on auto, iOS
/// re-meters when someone crosses the key light, hunts focus when the subject
/// leans back, and drifts white balance mid-take. Locking them is what makes
/// the phone behave like a camera rather than a webcam.
@MainActor
final class DeviceControls: ObservableObject {

    // MARK: - Published state

    @Published var exposureAuto = true { didSet { exposureModeChanged(from: oldValue) } }
    @Published var iso: Float = 100 { didSet { if !exposureAuto { applyExposure() } } }
    @Published var shutterDenominator: Double = 60 { didSet { if !exposureAuto { applyExposure() } } }

    @Published var focusAuto = true { didSet { focusModeChanged(from: oldValue) } }
    @Published var lensPosition: Float = 0.5 { didSet { if !focusAuto { applyFocus() } } }

    @Published var whiteBalanceAuto = true { didSet { whiteBalanceModeChanged(from: oldValue) } }
    @Published var temperature: Float = 5200 { didSet { if !whiteBalanceAuto { applyWhiteBalance() } } }
    @Published var tint: Float = 0 { didSet { if !whiteBalanceAuto { applyWhiteBalance() } } }

    /// Device capabilities, published so the UI can bound its sliders to what
    /// this specific sensor actually accepts.
    @Published private(set) var isoRange: ClosedRange<Float> = 50...800
    @Published private(set) var shutterOptions: [Double] = [30, 60, 120]
    @Published private(set) var supportsManualExposure = false
    @Published private(set) var supportsManualFocus = false
    @Published private(set) var supportsManualWhiteBalance = false
    @Published private(set) var lastError: String?

    private weak var device: AVCaptureDevice?

    /// Suppresses re-application while seeding sliders from the device, so
    /// assigning to a @Published value does not fight the value being read.
    private var isSeeding = false

    // MARK: - Attachment

    /// Binds to a configured device and re-applies any active manual settings.
    ///
    /// Called after every session reconfiguration — switching resolution
    /// rebuilds the format, and locked values must survive that.
    func attach(to device: AVCaptureDevice, frameDuration: CMTime) {
        self.device = device
        let format = device.activeFormat

        isoRange = format.minISO...max(format.minISO, format.maxISO)
        supportsManualExposure = device.isExposureModeSupported(.custom)
        supportsManualFocus = device.isFocusModeSupported(.locked)
        supportsManualWhiteBalance = device.isWhiteBalanceModeSupported(.locked)

        // Exposure can never outlast a frame interval, so 1/30 is the slowest
        // usable shutter at 30fps regardless of what the format reports.
        let slowestSeconds = min(CMTimeGetSeconds(format.maxExposureDuration),
                                 CMTimeGetSeconds(frameDuration))
        let fastestSeconds = CMTimeGetSeconds(format.minExposureDuration)
        shutterOptions = [30, 48, 60, 96, 120, 240, 500, 1000, 2000].filter {
            let seconds = 1.0 / $0
            return seconds <= slowestSeconds + 1e-9 && seconds >= fastestSeconds - 1e-9
        }
        if let nearest = shutterOptions.min(by: {
            abs($0 - shutterDenominator) < abs($1 - shutterDenominator)
        }) {
            isSeeding = true
            shutterDenominator = nearest
            isSeeding = false
        }

        // Re-assert whatever the user had locked before the reconfiguration.
        if !exposureAuto { applyExposure() }
        if !focusAuto { applyFocus() }
        if !whiteBalanceAuto { applyWhiteBalance() }
    }

    // MARK: - Mode transitions

    private func exposureModeChanged(from wasAuto: Bool) {
        guard !isSeeding, wasAuto != exposureAuto else { return }
        if exposureAuto {
            configure { device in
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        } else {
            seedExposureFromDevice()
            applyExposure()
        }
    }

    private func focusModeChanged(from wasAuto: Bool) {
        guard !isSeeding, wasAuto != focusAuto else { return }
        if focusAuto {
            configure { device in
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
        } else {
            if let device { isSeeding = true; lensPosition = device.lensPosition; isSeeding = false }
            applyFocus()
        }
    }

    private func whiteBalanceModeChanged(from wasAuto: Bool) {
        guard !isSeeding, wasAuto != whiteBalanceAuto else { return }
        if whiteBalanceAuto {
            configure { device in
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } else {
            seedWhiteBalanceFromDevice()
            applyWhiteBalance()
        }
    }

    /// Switching to manual adopts whatever auto had settled on, so locking is
    /// a freeze rather than a jump to some unrelated default.
    private func seedExposureFromDevice() {
        guard let device else { return }
        isSeeding = true
        iso = min(max(device.iso, isoRange.lowerBound), isoRange.upperBound)
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        if seconds > 0, let nearest = shutterOptions.min(by: {
            abs(1.0 / $0 - seconds) < abs(1.0 / $1 - seconds)
        }) {
            shutterDenominator = nearest
        }
        isSeeding = false
    }

    private func seedWhiteBalanceFromDevice() {
        guard let device else { return }
        isSeeding = true
        let gains = device.deviceWhiteBalanceGains
        let values = device.temperatureAndTintValues(for: gains)
        temperature = min(max(values.temperature, 2000), 10000)
        tint = min(max(values.tint, -150), 150)
        isSeeding = false
    }

    // MARK: - Apply

    private func applyExposure() {
        guard !isSeeding else { return }
        configure { [self] device in
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat

            var duration = CMTime(seconds: 1.0 / shutterDenominator,
                                  preferredTimescale: 1_000_000)
            if CMTimeCompare(duration, format.minExposureDuration) < 0 {
                duration = format.minExposureDuration
            }
            if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
                duration = format.maxExposureDuration
            }

            let clampedISO = min(max(iso, format.minISO), format.maxISO)
            device.setExposureModeCustom(duration: duration, iso: clampedISO)
        }
    }

    private func applyFocus() {
        guard !isSeeding else { return }
        configure { [self] device in
            guard device.isFocusModeSupported(.locked) else { return }
            device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1))
        }
    }

    private func applyWhiteBalance() {
        guard !isSeeding else { return }
        configure { [self] device in
            guard device.isWhiteBalanceModeSupported(.locked) else { return }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: values)

            // Out-of-range gains raise an Objective-C exception, which Swift
            // cannot catch — this clamp is what stops a slider from crashing
            // the app mid-stream.
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1.0), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)

            device.setWhiteBalanceModeLocked(with: gains)
        }
    }

    /// Every device mutation must be bracketed by lock/unlock; missing the
    /// unlock wedges the device for the rest of the session.
    private func configure(_ body: (AVCaptureDevice) -> Void) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            body(device)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
