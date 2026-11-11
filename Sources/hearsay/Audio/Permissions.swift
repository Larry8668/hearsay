import AppKit
import AVFoundation
import Foundation

/// The two TCC grants hearsay needs, and where to send the user when they are missing.
///
/// TCC attributes a request to the *responsible* process: launched from Finder / `open`, that is
/// hearsay.app; run as `build/hearsay.app/Contents/MacOS/hearsay` from a terminal, it is the
/// terminal app. The grant is also bound to the code signature, which is why the Makefile insists
/// on the stable "hearsay-dev" identity (an ad-hoc signature changes every build and macOS silently
/// drops the grant).
enum Permissions {
    enum Status: String { case granted, denied, notDetermined, unknown }

    // MARK: Microphone (public API)

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// Shows the system prompt the first time; afterwards returns the stored decision immediately.
    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    // MARK: System audio ("System Audio Recording Only", kTCCServiceAudioCapture)

    /// There is no public API to query this grant (macOS 14.2–27). Like insidegui/AudioCap we ask
    /// TCC.framework directly via `TCCAccessPreflight`. If Apple removes the symbol we report
    /// `.unknown` and callers should just try the tap: without the grant it delivers silence
    /// rather than failing, so `unknown` must never be treated as `denied`.
    static var systemAudio: Status {
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight(TCC.audioCaptureService, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined   // 2 = not yet asked
        }
    }

    /// Asks TCC to show the "System Audio Recording" prompt. Returns `nil` when the private
    /// symbol is unavailable (the prompt will then appear the first time the tap starts).
    static func requestSystemAudio() async -> Bool? {
        guard let request = TCC.request else { return nil }
        return await withCheckedContinuation { cont in
            request(TCC.audioCaptureService, nil) { cont.resume(returning: $0) }
        }
    }

    // MARK: Settings deep links

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Opens Privacy & Security → "Screen & System Audio Recording", whose lower section
    /// ("System Audio Recording Only") is where the AudioCapture grant lives.
    static func openSystemAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    private static func open(_ s: String) {
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Private TCC.framework entry points, resolved lazily with dlopen/dlsym so a missing symbol
/// degrades to `nil` instead of failing to launch.
private enum TCC {
    typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    private static let handle: UnsafeMutableRawPointer? = {
        let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        if h == nil { Log.warn(.tap, "permissions: TCC.framework not loadable; system-audio status unknown") }
        return h
    }()

    static let preflight: PreflightFn? = symbol("TCCAccessPreflight")
    static let request: RequestFn? = symbol("TCCAccessRequest")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else {
            Log.warn(.tap, "permissions: \(name) not found in TCC.framework")
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }
}
