import Foundation

/// A camera-control update sent from the PC down the video socket.
///
/// TCP is full duplex, so the same connection that carries frames upward
/// carries newline-delimited JSON control lines downward. Every field is
/// optional so the sender can express a partial change without having to
/// restate the whole camera state.
struct ControlMessage: Decodable {
    var exposureAuto: Bool?
    var iso: Float?
    var shutter: Double?

    var focusAuto: Bool?
    var lens: Float?

    var wbAuto: Bool?
    var temp: Float?
    var tint: Float?

    /// Target encode bitrate in megabits per second.
    var bitrateMbps: Double?
}
