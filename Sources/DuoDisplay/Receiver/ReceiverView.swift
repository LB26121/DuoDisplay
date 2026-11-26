import SwiftUI
import AVFoundation

extension ReceiverService {
    /// One-line status for the window header and the menu bar menu.
    var statusText: String {
        guard let peer = peerName else { return "Waiting for the MacBook…" }
        if edgeActive { return "Mouse and keyboard control \(peer)" }
        return mode == .display ? "Showing \(peer)’s display" : "Normal Use, paired with \(peer)"
    }
}

struct ReceiverView: View {
    @ObservedObject var service: ReceiverService
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "display",
                       title: "“\(service.name)” as Display",
                       status: service.isConnected ? service.statusText : service.status,
                       tone: service.isConnected ? .ok : (service.status.hasPrefix("Network error") ? .error : .working))
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Form {
                modeSection
                RequirementsSection(
                    links: service.thunderboltLinks,
                    pairedName: service.pairedName,
                    unpairedText: "Click “Connect” on the MacBook. Both Macs then show the same 6-digit code; click “Pair” on both.",
                    accessibilityGranted: service.accessibilityGranted,
                    accessibilityText: "Lets this Mac’s keyboard and trackpad control the MacBook, in Second Display mode and across the screen edge.",
                    onForget: { service.forgetPairing() })
                displaySection
                ReceiverMediaSection(media: service.media)
                RoleSection(symbol: "display", title: "Use as Display",
                            detail: "This Mac shows the MacBook’s display.",
                            onChange: onBack)
            }
            .formStyle(.grouped)
        }
        .designAnimation(value: service.isConnected)
        .designAnimation(value: service.mode)
        .designAnimation(value: service.edgeActive)
        .designAnimation(value: service.pipShowing)
        .frame(minWidth: 580, minHeight: 640)
    }

    private var modeSection: some View {
        Section {
            if service.isConnected {
                Picker("Mode", selection: Binding(
                    get: { service.mode },
                    set: { if $0 != service.mode { service.requestToggle() } })) {
                    Text("MacBook Display").tag(LinkMode.display)
                    Text("Normal Use").tag(LinkMode.local)
                }
                .pickerStyle(.segmented)

                if service.mode == .local {
                    edgeRow
                    pipRow
                }
                if let problem = service.pipProblem {
                    NoticeRow(text: problem)
                }
                if !service.inputForwarding {
                    NoticeRow(text: "Without Accessibility permission the display is shown, but input isn’t forwarded.")
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for the MacBook")
                        Text("On the MacBook, open DuoDisplay → “Extend Display” → “Connect”. After that it connects automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Mode")
        } footer: {
            if service.isConnected {
                ShortcutHint(text: "Switch anytime with", keys: GlobalHotKey.label, trailing: "on either Mac.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var edgeRow: some View {
        if service.edgeActive {
            StatusRow(symbol: "cursorarrow.motionlines", color: .green,
                      title: "Mouse and keyboard are controlling the MacBook",
                      detail: "To return, push the pointer past the MacBook’s edge or press \(GlobalHotKey.label).")
        } else if let edge = service.peerEdge {
            StatusRow(symbol: edge == .left ? "arrow.left.to.line" : "arrow.right.to.line", color: .blue,
                      title: "Switch at the \(edge == .left ? "left" : "right") edge",
                      detail: "Push the pointer past it to control the MacBook.")
        } else {
            StatusRow(symbol: "rectangle.portrait.slash", color: .gray,
                      title: "Edge switch is off",
                      detail: "Turned off on the MacBook, or it lacks Accessibility permission.")
        }
    }

    private var pipRow: some View {
        StatusRow(symbol: "pip.fill", color: service.pipShowing ? .green : .indigo,
                  title: service.pipShowing ? "Picture-in-Picture is open" : "Picture-in-Picture",
                  detail: service.pipShowing
                      ? "Move the pointer into the picture to control the MacBook, out past any edge to return. Close with \(GlobalHotKey.pipLabel)."
                      : "\(GlobalHotKey.pipLabel) shows the MacBook’s screen in a floating window.") {
            Button(service.pipShowing ? "Close" : "Show") { service.togglePiP() }
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle(isOn: $service.vsync) {
                Text("V-Sync")
                Text(service.vsync
                     ? "No tearing: each frame waits for the iMac’s next refresh, ~8 ms later on average."
                     : "Frames appear immediately: slightly faster, but fast motion shows tearing.")
            }
            if service.isConnected && service.mode == .display && !service.statsLine.isEmpty {
                LabeledContent("Stats") { StatsText(text: service.statsLine) }
            }
        }
    }
}

/// Camera + microphone of this Mac for the MacBook.
struct ReceiverMediaSection: View {
    @ObservedObject var media: MediaProvider

    var body: some View {
        Section {
            Toggle(isOn: $media.enabled) {
                Text("Share camera and microphone")
                Text("They appear on the MacBook as “iMac Camera (DuoDisplay)” and “iMac Microphone (DuoDisplay)” and only run while an app there uses them.")
            }
            Group {
                permissionRow(.video, label: "Camera", symbol: "web.camera.fill", activeColor: .green, active: media.cameraActive)
                permissionRow(.audio, label: "Microphone", symbol: "mic.fill", activeColor: .orange, active: media.micActive)
            }
            .id(media.permissionTick)
            if let problem = media.problem {
                NoticeRow(text: problem)
            }
        } header: {
            Text("Camera & Microphone for the MacBook")
        } footer: {
            Text("In Second Display mode, the MacBook’s sound plays on this Mac’s speakers.")
                .footerText()
        }
    }

    /// Colors follow the macOS privacy indicators: camera green, microphone orange while sending.
    @ViewBuilder
    private func permissionRow(_ type: AVMediaType, label: String, symbol: String, activeColor: Color, active: Bool) -> some View {
        let status = MediaPermissions.status(type)
        let allowed = status == .authorized
        StatusRow(symbol: symbol,
                  color: active ? activeColor : (allowed ? .blue : .gray),
                  title: label,
                  detail: active ? "Sending to the MacBook" : (allowed ? "Access allowed" : "Access not allowed")) {
            if status == .notDetermined {
                Button("Allow…") { media.requestPermission(type) }
                    .buttonStyle(.borderedProminent)
            } else if !allowed {
                Button("Open Settings") { MediaPermissions.openSettings(type) }
            }
        }
    }
}
