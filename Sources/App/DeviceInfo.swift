import AVFoundation
import Foundation
import UIKit

/// Read-only environment probes for the M0 toolchain smoke test.
///
/// Nothing here starts an `AVCaptureSession` or reads frames, so none of it
/// triggers a camera permission prompt — format enumeration is unprivileged.
enum DeviceInfo {

    // MARK: - Build identity

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Timestamp of the app binary itself.
    ///
    /// This is the field that tells you whether you are looking at the build you
    /// just sideloaded or a stale one still on the phone — the single most
    /// common source of confusion when iterating without a Simulator.
    static var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return "unknown" }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Hardware

    /// Machine identifier, e.g. `iPhone11,8` for the XR.
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        let raw = withUnsafeBytes(of: &info.machine) { bytes in
            bytes.prefix { $0 != 0 }
        }
        return String(decoding: raw, as: UTF8.self)
    }

    static var modelName: String {
        switch modelIdentifier {
        case "iPhone11,8": return "iPhone XR"
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "x86_64", "arm64": return "Simulator"
        default: return modelIdentifier
        }
    }

    static var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    // MARK: - Camera capability

    struct CameraCapability {
        var available: Bool
        var supports4K30: Bool
        var best: String
    }

    /// Confirms the back wide camera exposes a 3840×2160 format at ≥30 fps.
    ///
    /// M1 onward assumes this exists; better to learn otherwise now.
    static var cameraCapability: CameraCapability {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            return CameraCapability(available: false, supports4K30: false, best: "no back camera")
        }

        var supports4K30 = false
        var bestPixels = 0
        var best = "none"

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFPS = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0

            if dims.width >= 3840, dims.height >= 2160, maxFPS >= 30 {
                supports4K30 = true
            }

            let pixels = Int(dims.width) * Int(dims.height)
            if pixels > bestPixels {
                bestPixels = pixels
                best = "\(dims.width)×\(dims.height) @ \(Int(maxFPS))fps"
            }
        }

        return CameraCapability(available: true, supports4K30: supports4K30, best: best)
    }
}
