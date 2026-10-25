import AppKit
import Dispatch

/// Ctrl-C (SIGINT), `kill` (SIGTERM) and a closed terminal (SIGHUP) quit the app the normal way,
/// through `NSApp.terminate`, so `applicationWillTerminate` runs `AppModel.shutdown` and the RSP and
/// the SDRplay API are released. A process that dies inside the API can leave the service's
/// cross-process lock held, and every SDRplay client then hangs until the service is restarted.
/// A second signal of the same kind ends the process at once, for a shutdown that is itself stuck.
@MainActor
enum TerminationSignals {
    static let handled: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private static var sources: [any DispatchSourceSignal] = []
    private static var terminating = false

    static func install(terminate: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }) {
        guard sources.isEmpty else { return }
        for sig in handled {
            // The default action would kill the process before the dispatch source sees the signal.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    if terminating {
                        signal(sig, SIG_DFL)
                        raise(sig)
                    } else {
                        terminating = true
                        terminate()
                    }
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}
