import Foundation
import UIKit

/// Dependency-free crash/error reporting — there's no way to add the Sentry Cocoa SDK here (the
/// socket.io-client-swift SPM package couldn't be resolved in this environment either, see
/// SocketManager's header comment; `xcodebuild -resolvePackageDependencies` hangs indefinitely
/// regardless of which remote package is added, confirmed again when trying Sentry's own SPM
/// package). Backend crash/error reporting does use real Sentry (`backend/src/sentry.ts`) — this
/// forwards into the same project via `POST /diagnostics/report`, which calls
/// `Sentry.captureException` server-side. No auth required: the whole point is to still work
/// when the app is logged out or the crash happened before a session existed.
enum CrashReporter {
    fileprivate static let crashFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pending_crash.json")
    }()

    /// Call once at launch (see AppDelegate). Ships whatever crashed last run, then arms the
    /// handlers for this run.
    static func install() {
        reportPendingCrashIfAny()

        // Uncaught Swift/Obj-C exceptions — has real context (name, reason, symbolicated-ish
        // stack) since NSException carries it. Safe to do normal Swift/Foundation work here;
        // unlike a POSIX signal handler, this isn't reentering a corrupted runtime. A trailing
        // closure here would implicitly capture MainActor context (this whole module defaults
        // to MainActor isolation) which a `@convention(c)` handler can't carry — has to be a
        // free function instead, see `uncaughtExceptionHandler` below.
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)

        // Fatal signals (force-unwrap, array out-of-bounds, etc.) never raise an NSException,
        // so this is the only way to record these at all. The handler below is intentionally
        // minimal — a signal handler re-enters process state mid-crash, so anything beyond a
        // raw write(2) to an already-open fd risks deadlocking instead of actually recording
        // the crash. Best-effort by design, not a rigorous async-signal-safe implementation.
        pendingCrashFD = open(crashFileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }

    /// Fire-and-forget non-fatal error reporting for the few call sites that opt in — not a
    /// blanket replacement for every `print()`-only catch block in the app (a much larger sweep,
    /// tracked separately), just the highest-signal ones wired in directly.
    static func reportError(_ error: Error, context: String) {
        Task {
            await send(type: "error", message: "\(context): \(error.localizedDescription)", stack: nil)
        }
    }

    static func reportRaw(type: String, message: String) {
        Task {
            await send(type: type, message: message, stack: nil)
        }
    }

    private static func reportPendingCrashIfAny() {
        guard let data = try? Data(contentsOf: crashFileURL), !data.isEmpty else { return }
        try? FileManager.default.removeItem(at: crashFileURL)
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        Task {
            await send(type: payload["type"] ?? "unknown", message: payload["message"] ?? "", stack: payload["stack"])
        }
    }

    private static func send(type: String, message: String, stack: String?) async {
        let report = DiagnosticReport(
            type: type,
            message: message,
            stack: stack,
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: UIDevice.current.systemVersion
        )
        _ = try? await APIService.shared.reportDiagnostic(report)
    }
}

struct DiagnosticReport: Codable {
    let type: String
    let message: String
    let stack: String?
    let platform: String
    let appVersion: String?
    let osVersion: String
}

/// File-scope, not a CrashReporter member — a `@convention(c)` signal handler can't capture
/// `self`/enclosing context, so this (and `pendingCrashFD`) have to live at file scope where
/// they're addressed directly rather than captured.
private var pendingCrashFD: Int32 = -1

private func crashSignalHandler(_ sig: Int32) {
    if pendingCrashFD >= 0 {
        let json = "{\"type\":\"signal\",\"message\":\"signal \(sig)\"}"
        _ = json.withCString { write(pendingCrashFD, $0, strlen($0)) }
    }
    Foundation.exit(sig)
}

/// Free function, not a closure — see the comment at the `NSSetUncaughtExceptionHandler` call
/// site. `nonisolated` opts it out of this module's default MainActor isolation so it stays a
/// plain, context-free C function pointer.
private nonisolated func uncaughtExceptionHandler(_ exception: NSException) {
    let payload: [String: String] = [
        "type": "exception",
        "message": "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
        "stack": exception.callStackSymbols.joined(separator: "\n"),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
        try? data.write(to: CrashReporter.crashFileURL)
    }
}
