import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                Text("Setup").tag(AppTab.setup)
                Text("Settings").tag(AppTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, 12)

            Divider()

            switch state.tab {
            case .setup: SetupGuideView(state: state)
            case .settings: SettingsView(state: state)
            }
        }
        .frame(width: 580, height: 720)
    }
}

// MARK: - Setup guide

struct SetupGuideView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    StatusBanner(state: state)
                    screenRecordingStep
                    accessibilityStep
                    networkStep
                    browserStep
                    connectStep
                }
                .padding(20)
            }
            Divider()
            HStack {
                Toggle("Show this window when PaneBridge starts", isOn: $state.showAtLaunch)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Button("Done") { state.closeWindow?() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "display.2")
                .font(.system(size: 34, weight: .regular))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to PaneBridge").font(.title2.bold())
                Text("Use your PC's screen as an extra display for this Mac. PaneBridge lives in your menu bar.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private var screenRecordingStep: some View {
        StepCard(number: 1, title: "Allow Screen Recording",
                 detail: "Required. PaneBridge records only its own virtual display, to stream it to your PC.",
                 status: state.screenRecording ? .done : .todo) {
            if !state.screenRecording {
                HStack {
                    Button("Allow Screen Recording…") { state.requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("Relaunch PaneBridge") { relaunchApp() }
                }
                Text("Turn on PaneBridge in the list that opens, then click Relaunch.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Text("Already on, but still not working (common after an update)?")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Reset permission") { state.resetScreenRecording() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var accessibilityStep: some View {
        StepCard(number: 2, title: "Allow Accessibility",
                 detail: "Lets your PC's mouse and keyboard control the Mac. Skip it if you'll only use the Mac's own trackpad and keyboard.",
                 status: state.accessibility ? .done : .optional) {
            if !state.accessibility {
                HStack {
                    Button("Allow Accessibility…") { state.requestAccessibility() }
                    Button("Relaunch PaneBridge") { relaunchApp() }
                }
                HStack(spacing: 4) {
                    Text("Already on, but still not working (common after an update)?")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Reset permission") { state.resetAccessibility() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var hasTailscale: Bool { state.urls.contains { $0.isTailscale } }

    private var networkStep: some View {
        StepCard(number: 3, title: "Connect both computers to the same network",
                 detail: "Your PC needs to reach one of these addresses.",
                 status: state.urls.isEmpty ? .todo : .done) {
            if state.urls.isEmpty {
                Text("This Mac isn't connected to a network.").foregroundColor(.orange)
            }
            ForEach(state.urls) { v in
                CopyRow(state: state, text: v.url, badge: v.label, highlight: v.isTailscale)
            }
            if !hasTailscale {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page won't load on the PC? Your Mac and PC may be on separate networks, for example behind a mesh Wi-Fi system in router mode. Turn on **Tailscale** on both computers with the same account, and a Tailscale address will appear here.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Get Tailscale →", destination: URL(string: "https://tailscale.com/download")!)
                        .font(.caption)
                }
            }
        }
    }

    private var browserStep: some View {
        StepCard(number: 4, title: "One-time browser setup on the PC",
                 detail: "Chrome and Edge only enable their video decoder on secure pages, so allow this Mac's address once.",
                 status: state.everConnected ? .done : .todo) {
            Text("a. In **Chrome** on the PC, open this page (in **Edge**, start it with edge:// instead):")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            CopyRow(state: state, text: "chrome://flags/#unsafely-treat-insecure-origin-as-secure")
            Text("b. Type this address into the box, set it to **Enabled**, then click **Relaunch**:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            CopyRow(state: state, text: state.primaryURL ?? "Waiting for a network address…")
        }
    }

    private var connectStep: some View {
        StepCard(number: 5, title: "Open PaneBridge on the PC",
                 detail: "Go to the same address in Chrome or Edge, then click Fullscreen at the top of the page.",
                 status: state.viewers > 0 ? .done : .todo) {
            if state.viewers > 0 {
                Label("Connected! Move your mouse off the \(state.options.position) edge of your screen to reach the PC.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your PC to connect…").foregroundColor(.secondary)
                }
            }
        }
    }
}

struct StatusBanner: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.phase {
        case .running:
            banner(color: .green, icon: "dot.radiowaves.left.and.right",
                   text: "Virtual display is on: \(state.options.width)×\(state.options.height) at \(state.options.fps) fps. \(state.viewers > 0 ? "Streaming to your PC." : "Waiting for your PC.")")
        case .starting, .restarting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting virtual display…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        case .waitingForPermission where !state.screenRecording:
            banner(color: .orange, icon: "lock", text: "Finish step 1 to turn on the virtual display.")
        case .waitingForPermission:
            banner(color: .secondary, icon: "hourglass", text: "Getting ready…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { state.restartEngine() }
                    Button("Relaunch PaneBridge") { relaunchApp() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
        }
    }

    private func banner(color: Color, icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

enum StepStatus { case done, todo, optional }

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let detail: String
    let status: StepStatus
    let content: Content

    init(number: Int, title: String, detail: String, status: StepStatus, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.detail = detail
        self.status = status
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(status == .done ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                if status == .done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundColor(.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if status == .optional {
                        Text("Optional")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct CopyRow: View {
    @ObservedObject var state: AppState
    let text: String
    var badge: String? = nil
    var highlight = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(highlight ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
            }
            Spacer(minLength: 4)
            Button(state.lastCopied == text ? "Copied" : "Copy") { state.copy(text) }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState

    private var resolution: Binding<String> {
        Binding(
            get: { "\(state.draft.width)x\(state.draft.height)" },
            set: { value in
                let parts = value.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { state.draft.width = parts[0]; state.draft.height = parts[1] }
            })
    }

    private var resolutionChoices: [(Int, Int)] {
        var list = AppState.resolutions
        if !list.contains(where: { $0 == (state.draft.width, state.draft.height) }) { list.append((state.draft.width, state.draft.height)) }
        return list
    }

    private var frameRateChoices: [Int] {
        AppState.frameRates.contains(state.draft.fps) ? AppState.frameRates : (AppState.frameRates + [state.draft.fps]).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Resolution", selection: resolution) {
                        ForEach(resolutionChoices.map { "\($0.0)x\($0.1)" }, id: \.self) { key in
                            Text(key.replacingOccurrences(of: "x", with: " × ")).tag(key)
                        }
                    }
                    Toggle(isOn: $state.draft.hiDPI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Retina (HiDPI)")
                            Text("Sharper text at the same size, but streams 4× the pixels. Best with a 4K PC monitor.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Picker("Position", selection: $state.draft.position) {
                        Text("Right of this Mac's screen").tag("right")
                        Text("Left of this Mac's screen").tag("left")
                        Text("Above this Mac's screen").tag("above")
                        Text("Below this Mac's screen").tag("below")
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Match the resolution to your PC monitor for the sharpest picture. You can also rearrange displays in System Settings → Displays.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section {
                    Picker("Frame rate", selection: $state.draft.fps) {
                        ForEach(frameRateChoices, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text("\(Int(state.draft.bitrateMbps)) Mbps").monospacedDigit().foregroundColor(.secondary)
                        }
                        Slider(value: $state.draft.bitrateMbps, in: 4...80) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("4").font(.caption)
                        } maximumValueLabel: {
                            Text("80").font(.caption)
                        }
                        Text(bitrateHint).font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Stream quality")
                } footer: {
                    Text("Lower the bitrate or frame rate if the picture stutters, for example on Wi-Fi or a relayed Tailscale connection.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section {
                    Toggle("Let the PC's mouse and keyboard control this Mac", isOn: $state.draft.input)
                } header: {
                    Text("Control")
                } footer: {
                    Text("Needs the Accessibility permission from the Setup tab.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Restore Defaults") {
                    var d = Options()
                    d.port = state.draft.port
                    state.draft = d
                }
                Spacer()
                if state.draft != state.options {
                    Text("The display restarts and your PC reconnects automatically.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Apply") { state.applyDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.draft == state.options)
            }
            .padding(12)
        }
    }

    private var bitrateHint: String {
        let pixelsPerSecond = Double(state.draft.pixelWidth * state.draft.pixelHeight * state.draft.fps)
        let suggested = max(6, min(80, (pixelsPerSecond * 0.08 / 1_000_000).rounded()))
        return "Suggested for these settings: about \(Int(suggested)) Mbps."
    }
}
