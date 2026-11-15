import Foundation
import CoreGraphics
import ApplicationServices

/// Headless mode when run from Terminal: logs to stdout, Ctrl+C to quit.
func runCommandLine(_ options: Options) -> Never {
    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        print("""
        ⚠️  PaneBridge needs Screen Recording permission.
           System Settings → Privacy & Security → Screen & System Audio Recording → enable your
           terminal app, then quit and reopen it and run PaneBridge again.
        """)
    }
    if options.input && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
        print("""
        ⚠️  Mouse/keyboard from the viewer needs Accessibility permission.
           System Settings → Privacy & Security → Accessibility → enable your terminal app.
           (Streaming works without it.)
        """)
    }

    let engine = Engine(options: options)
    engine.onViewerCountChanged = { print("Viewers connected: \($0)") }
    engine.onStopped = { fail("Capture stopped: \($0)") }

    Task {
        do {
            try await engine.start()
        } catch {
            fail(error.localizedDescription)
        }
        print("\nOn your Windows PC, open Chrome or Edge and go to:")
        for v in viewerURLs(port: options.port) { print("   \(v.url)   (\(v.label))") }
        print("\n(Press Ctrl+C here to stop.)\n")
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\nStopping, removing virtual display.")
        exit(0)
    }
    sigint.resume()

    withExtendedLifetime((engine, sigint)) {
        RunLoop.main.run()
    }
    exit(0)
}
