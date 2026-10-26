import Foundation
import AppKit
import AVFoundation

enum Permissions {
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var camera: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
    }

    enum Pane: String {
        case screen = "Privacy_ScreenCapture"
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
