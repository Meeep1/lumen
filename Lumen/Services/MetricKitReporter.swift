import Foundation
import MetricKit

/// Supplementary to CrashReporter's own uncaught-exception/signal handlers, not a replacement —
/// MetricKit is Apple's own built-in diagnostics pipeline (zero dependency, nothing to install),
/// but its payloads arrive with an OS-imposed delay (typically the next day, sometimes longer),
/// so it's a "confirms/enriches what we already reported" signal rather than a real-time one.
class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()

    private override init() {}

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let reason = crash.exceptionType?.stringValue ?? "unknown"
                let signal = crash.signal?.stringValue ?? "unknown"
                CrashReporter.reportRaw(type: "metrickit_crash", message: "exceptionType=\(reason) signal=\(signal)")
            }
            for hang in payload.hangDiagnostics ?? [] {
                let duration = hang.hangDuration.description
                CrashReporter.reportRaw(type: "metrickit_hang", message: "duration=\(duration)")
            }
        }
    }
}
