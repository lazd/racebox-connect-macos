import AppKit
import RaceBoxCore
import SwiftUI

private let seafoam = Color(red: 0.18, green: 0.70, blue: 0.60)
private let apricot = Color(red: 0.96, green: 0.57, blue: 0.33)

struct RaceBoxMascot: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 94, height: 94)
        .accessibilityLabel("Smiling RaceBox mascot")
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.06)))
    }
}

struct DashboardView: View {
    @EnvironmentObject private var client: RaceBoxClient
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.locale) private var locale
    @State private var section = "Dashboard"
    @State private var showEraseConfirmation = false
    private var displayUnits: DisplayUnits { preferences.units.resolved(locale: locale) }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered.2.crossed").font(.title2).foregroundStyle(seafoam)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RaceBox").font(.title3.bold())
                        Text("CONNECT").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(3)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 22)
                VStack(spacing: 5) {
                    navigationButton("Dashboard", icon: "square.grid.2x2")
                    navigationButton("Recordings", icon: "folder")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("YOUR DEVICE").font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        if client.scanning { ProgressView().controlSize(.small) }
                    }
                    if client.connected || client.connecting {
                        Label(client.deviceName, systemImage: "sensor.tag.radiowaves.forward.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(seafoam)
                        Text(client.connectionStatus).font(.caption).foregroundStyle(.secondary)
                        Button(client.connecting ? "Cancel Connection" : "Disconnect") { client.disconnect() }
                            .disabled(client.operation.isErase)
                    } else {
                        ForEach(client.devices) { device in
                            Button { client.connect(device) } label: {
                                HStack {
                                    Image(systemName: "sensor.tag.radiowaves.forward")
                                    VStack(alignment: .leading) {
                                        Text(device.name).lineLimit(2)
                                        Text("\(device.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(seafoam.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Button { client.scan() } label: {
                            Label(client.scanning ? "Scanning…" : "Find RaceBox", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(client.scanning)
                        Text(client.connectionStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    SettingsLink { Label("Preferences", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                }
                .font(.callout)
            }
            .padding(20)
            .frame(maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .background(.ultraThinMaterial)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if section == "Dashboard" {
                        actions
                        standaloneRecordingControls
                        telemetry
                        diagnostics
                    } else {
                        RecordingsView()
                    }
                    footer
                }
                .padding(30)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(seafoam)
        .alert("RaceBox needs a little attention", isPresented: Binding(
            get: { client.errorMessage != nil && client.downloadConfirmation == nil },
            set: { if !$0 { client.errorMessage = nil } }
        )) {
            Button("OK") { client.errorMessage = nil }
        } message: { Text(client.errorMessage ?? "") }
        .sheet(item: $client.downloadConfirmation) { confirmation in
            DownloadCompleteView(confirmation: confirmation)
                .environmentObject(client)
        }
        .confirmationDialog("Clear all RaceBox memory?", isPresented: $showEraseConfirmation) {
            Button("Clear Device Memory", role: .destructive) { client.clearMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every stored recording from the connected RaceBox. Local downloads are not affected. This cannot be undone.")
        }
    }

    private func navigationButton(_ title: String, icon: String) -> some View {
        Button { section = title } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(section == title ? seafoam.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(section == title ? seafoam : .primary)
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(section == "Dashboard" ? "RaceBox Connect" : "The data. On your device, where it belongs.")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text(section == "Dashboard"
                     ? "We don't need no stinkin' cloud."
                     : "Saved sessions, tracks, and motion data.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle().fill(client.connected ? seafoam : .secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(client.connected ? client.deviceName : "Not connected").font(.caption.weight(.medium))
                }
            }
            Spacer()
            RaceBoxMascot()
        }
        .padding(.vertical, 8)
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 18) {
            Card {
                Label("Get your data", systemImage: "arrow.down.to.line")
                    .font(.headline).foregroundStyle(seafoam)
                Text("Download every stored session as \(preferences.format.rawValue).")
                    .font(.callout).foregroundStyle(.secondary)
                Button { client.downloadHistory() } label: {
                    Label("Download Recordings", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!client.connected || client.busy)
                Text(preferences.deleteAfterDownload ? "Auto-delete after verified download is ON." : "Device recordings stay safe in memory.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Card {
                Label("Live capture", systemImage: "waveform.path")
                    .font(.headline).foregroundStyle(apricot)
                Text(client.capturing ? "\(client.pointsSaved.formatted()) points saved. Keep exploring."
                     : "Stream live telemetry straight to \(preferences.format.rawValue).")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    if client.capturing { client.stopCapture() } else { client.startCapture() }
                } label: {
                    Label(client.capturing ? "Stop & Save Capture" : "Start Live Capture",
                          systemImage: client.capturing ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .tint(apricot)
                .buttonStyle(.borderedProminent)
                .disabled(!client.connected || (client.busy && !client.capturing))
                Text("Records with a valid 3D fix. Pauses if the fix is lost.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var standaloneRecordingControls: some View {
        Card {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Standalone recording", systemImage: "internaldrive").font(.headline)
                    Text(client.recordingConfiguration?.enabled == true
                         ? "Recording to device memory. Continues after disconnecting."
                         : "Save data on your RaceBox to download later.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { client.toggleStandaloneRecording() } label: {
                    Label(client.recordingConfiguration?.enabled == true ? "Stop Standalone Recording" : "Start Standalone Recording",
                          systemImage: client.recordingConfiguration?.enabled == true ? "stop.circle.fill" : "record.circle")
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!client.connected || client.busy || client.recordingConfiguration == nil)
            }
        }
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("A little signal check").font(.title3.bold())
                Spacer()
                Label(client.telemetry?.hasFix == true ? "3D FIX" : "WAITING FOR FIX",
                      systemImage: client.telemetry?.hasFix == true ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .font(.caption2.bold()).foregroundStyle(client.telemetry?.hasFix == true ? seafoam : .secondary)
            }
            HStack(spacing: 14) {
                metric("Speed", value: speedReading(client.telemetry?.speedKmh, digits: 1),
                       unit: displayUnits.speedSymbol, icon: "speedometer", color: seafoam)
                metric("Accuracy", value: lengthReading(client.telemetry?.horizontalAccuracyM),
                       unit: "\(displayUnits.lengthName) horizontal", icon: "scope", color: .blue)
                metric("Battery", value: client.telemetry?.batteryPercent.map { "\($0)%" } ?? "—",
                       unit: client.telemetry?.charging == true ? "charging" : "charge remaining",
                       icon: client.telemetry?.charging == true ? "battery.100percent.bolt" : "battery.75percent",
                       color: apricot)
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        Card {
            HStack {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reading(_ value: Double?, digits: Int = 2, requiresFix: Bool = true) -> String {
        guard let value, !requiresFix || client.telemetry?.hasFix == true else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    private func speedReading(_ value: Double?, digits: Int = 2) -> String {
        reading(value.map { displayUnits.speed(fromKmh: $0) }, digits: digits)
    }

    private func lengthReading(_ value: Double?, digits: Int = 2) -> String {
        reading(value.map { displayUnits.length(fromMeters: $0) }, digits: digits)
    }

    private var diagnostics: some View {
        HStack(alignment: .top, spacing: 18) {
            Card {
                Label("Live instruments", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
                infoRow("Satellites used", client.telemetry?.satellites.map(String.init) ?? "—", "")
                infoRow("Heading", reading(client.telemetry?.headingDeg, digits: 1), "°")
                infoRow("Speed accuracy", speedReading(client.telemetry?.speedAccuracyKmh), displayUnits.speedSymbol)
                infoRow("Heading accuracy", reading(client.telemetry?.headingAccuracyDeg), "°")
                infoRow("Vertical accuracy", lengthReading(client.telemetry?.verticalAccuracyM), displayUnits.lengthSymbol)
                infoRow("PDOP", reading(client.telemetry?.pdop), "")
                Divider()
                infoRow("Latitude", reading(client.telemetry?.latitude, digits: 7), "°")
                infoRow("Longitude", reading(client.telemetry?.longitude, digits: 7), "°")
                infoRow("Altitude MSL", lengthReading(client.telemetry?.altMslM, digits: 1), displayUnits.lengthSymbol)
                infoRow("Altitude WGS84", lengthReading(client.telemetry?.altWgsM, digits: 1), displayUnits.lengthSymbol)
                Divider()
                infoRow("Rejected frames", client.rejectedFrames.formatted(), "")
                infoRow("UTC valid", client.telemetry.map { $0.utcValid == true ? "Yes" : "No" } ?? "—", "")
                infoRow("Time accuracy", client.telemetry?.utcValid == true
                        ? client.telemetry?.timeAccuracyNs.map { $0.formatted() } ?? "—" : "—", "ns")
                Divider()
                Text("Satellites used, not satellites visible. The standard RaceBox packet does not expose per-satellite identities or signal strength.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 18) {
                Card {
                    Label("Motion", systemImage: "gyroscope").font(.headline)
                    infoRow("G-force X / Y / Z", triple(client.telemetry.map { [$0.gForceX, $0.gForceY, $0.gForceZ] }), "g")
                    infoRow("Roll / Pitch / Yaw", triple(client.telemetry.map { [$0.rollRate, $0.pitchRate, $0.yawRate] }), "°/s")
                }
                Card {
                    Label("Memory", systemImage: "internaldrive").font(.headline)
                    infoRow("Memory used", client.memory.map { "\($0.usedPercent)%" } ?? "—", "")
                    infoRow("Stored time (est.)", memoryDuration(client.memory?.storedRecords), "")
                    infoRow("Capacity (est.)", memoryDuration(client.memory?.capacityRecords), "")
                    Text(client.recordingConfiguration.map {
                        "Estimated at \($0.samplesPerSecond.formatted()) Hz. Historical rates and recording pauses may differ."
                    } ?? "Reading the device's recording rate…")
                        .font(.caption2).foregroundStyle(.secondary)
                    infoRow("Standalone recording", client.memory.map { $0.recording ? "Active" : "Stopped" } ?? "—", "")
                    Divider()
                    Button(role: .destructive) { showEraseConfirmation = true } label: {
                        Label("Clear Device Memory…", systemImage: "trash")
                    }
                    .disabled(!client.connected || client.busy)
                    Text("Permanently erases stored recordings on your RaceBox.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func memoryDuration(_ records: UInt32?) -> String {
        guard let records, let configuration = client.recordingConfiguration else { return "—" }
        return configuration.duration(records: records)
    }

    private func triple(_ values: [Double]?) -> String {
        guard let values else { return "—" }
        return values.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")
    }

    private func infoRow(_ title: String, _ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().textSelection(.enabled)
            if !unit.isEmpty { Text(unit).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if client.operation != .idle {
                if let progress = client.progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))% \(client.operation.isErase ? "cleared" : "of advertised maximum")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: client.capturing ? "record.circle.fill" : "info.circle")
                    .foregroundStyle(client.capturing ? apricot : seafoam)
                Text(client.message).font(.callout).textSelection(.enabled)
                Spacer()
                if client.operation.isDownload {
                    Button("Cancel") { client.cancelDownload() }
                }
            }
            HStack {
                Label(preferences.directory, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Spacer()
                SettingsLink { Text("\(preferences.format.rawValue) • Preferences") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(seafoam.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DownloadCompleteView: View {
    let confirmation: DownloadConfirmation
    @EnvironmentObject private var client: RaceBoxClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: confirmation.hasIncompleteRecordings
                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(confirmation.hasIncompleteRecordings ? apricot : seafoam)
            Text(confirmation.files.isEmpty && !confirmation.skippedFiles.isEmpty
                 ? "Already Downloaded"
                 : confirmation.hasIncompleteRecordings ? "Download Finished" : "Download Complete")
                .font(.title2.bold())
            Text("\(confirmation.files.count.formatted()) recordings • \(confirmation.pointCount.formatted()) points saved")
                .foregroundStyle(.secondary)
            if !confirmation.skippedFiles.isEmpty {
                Text("\(confirmation.skippedFiles.count.formatted()) recordings already downloaded. Duplicate copies were skipped.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Label("Find your downloaded files here:", systemImage: "folder.fill")
                    .font(.headline)
                Text(confirmation.directory.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("Recordings are organized into folders by their recording date.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(seafoam.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            if confirmation.hasIncompleteRecordings {
                Text("Some recordings are incomplete because standalone recording was still active. The received data is saved; download again after recording stops.")
                    .font(.callout).foregroundStyle(apricot)
            }
            if confirmation.deletionRequested {
                Text("Automatic memory clearing is a separate step. Keep your RaceBox powered on until the dashboard confirms memory is cleared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        confirmation.files.isEmpty ? confirmation.skippedFiles : confirmation.files
                    )
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .tint(seafoam)
        .alert("RaceBox needs a little attention", isPresented: Binding(
            get: { client.errorMessage != nil },
            set: { if !$0 { client.errorMessage = nil } }
        )) {
            Button("OK") { client.errorMessage = nil }
        } message: { Text(client.errorMessage ?? "") }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var client: RaceBoxClient

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Connect automatically", isOn: $preferences.connectAutomatically)
                Text("Connect to the RaceBox with the strongest RSSI on launch. Scans for three seconds after Bluetooth is ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Make yourself at home") {
                Picker("Units", selection: $preferences.units) {
                    ForEach(DisplayUnits.allCases) { units in Text(units.title).tag(units) }
                }
                LabeledContent("Download location") {
                    HStack {
                        Text(preferences.directory).lineLimit(1).truncationMode(.middle)
                            .help(preferences.directory)
                        Button("Choose…") { preferences.chooseDirectory() }
                    }
                }
                Picker("Download format", selection: $preferences.format) {
                    ForEach(ExportFormat.allCases) { format in Text(format.rawValue).tag(format) }
                }
                .pickerStyle(.segmented)
                Toggle("Delete after downloading", isOn: $preferences.deleteAfterDownload)
                Text("Only clears device memory after a verified, nonempty history download, with standalone recording stopped. Live captures never erase memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Protected device memory") {
                SecureField("Security code", text: $client.securityCode, prompt: Text("0 (unprotected)"))
                Text("Optional unsigned 32-bit device code. Kept only until this app quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 550, height: 580)
        .tint(seafoam)
    }
}
