import AppKit
import Charts
import MapKit
import RaceBoxCore
import SwiftUI

@MainActor
private final class RecordingLibraryModel: ObservableObject {
    @Published var recordings: [RecordingSummary] = []
    @Published var issues: [RecordingLoadIssue] = []
    @Published var loading = false
    @Published var error: String?
    private var request = UUID()

    func refresh(directory: URL, excluding: Set<URL>) async {
        let currentRequest = UUID()
        request = currentRequest
        loading = true
        error = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try RecordingReader.index(directory: directory, excluding: excluding)
            }.value
            guard request == currentRequest, !Task.isCancelled else { return }
            recordings = result.recordings
            issues = result.issues
        } catch {
            guard request == currentRequest, !Task.isCancelled else { return }
            recordings = []
            issues = []
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct RecordingsView: View {
    @EnvironmentObject private var client: RaceBoxClient
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = RecordingLibraryModel()
    @State private var selected: RecordingSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let selected {
                RecordingDetailView(summary: selected) { self.selected = nil }
            } else {
                HStack {
                    Label("Saved on this Mac", systemImage: "folder.fill").font(.headline)
                    Spacer()
                    if library.loading { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.disabled(library.loading)
                    Button("Open Download Folder") {
                        if !NSWorkspace.shared.open(preferences.directoryURL) {
                            client.errorMessage = "Could not open \(preferences.directoryURL.path) in Finder."
                        }
                    }
                }
                Text(preferences.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let error = library.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if library.recordings.isEmpty && !library.loading {
                    ContentUnavailableView("No saved recordings found", systemImage: "tray",
                        description: Text("Download sessions, finish a live capture, or choose the folder containing your RaceBox exports in Preferences."))
                        .frame(minHeight: 220)
                }
                LazyVStack(spacing: 0) {
                    ForEach(library.recordings) { recording in
                        HStack(spacing: 14) {
                            Image(systemName: recording.complete == false ? "exclamationmark.triangle" : "map")
                                .font(.title2).foregroundStyle(recording.complete == false ? .orange : .teal)
                            Button {
                                selected = recording
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(recording.startedAt?.formatted(date: .abbreviated, time: .standard)
                                         ?? recording.url.lastPathComponent).font(.headline)
                                    Text(recording.url.lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text("\(recording.pointCount.formatted()) points · \(RecordingTime.duration(recording.duration)) · \(completionLabel(recording.complete))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("View") { selected = recording }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                        }
                        .padding(.vertical, 16)
                        Divider()
                    }
                }
                if !library.issues.isEmpty {
                    DisclosureGroup("\(library.issues.count) files could not be read") {
                        ForEach(library.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.url.lastPathComponent).font(.callout.bold())
                                Text(issue.message).font(.caption).textSelection(.enabled)
                                Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([issue.url]) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .task(id: preferences.directory) {
            selected = nil
            await library.refresh(directory: preferences.directoryURL, excluding: client.activeRecordingURLs)
        }
        .onChange(of: client.recordings.map(\.url)) { _, _ in refresh() }
        .onChange(of: client.busy) { wasBusy, isBusy in if wasBusy && !isBusy { refresh() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        Task { await library.refresh(directory: preferences.directoryURL, excluding: client.activeRecordingURLs) }
    }

    private func completionLabel(_ complete: Bool?) -> String {
        switch complete {
        case true: return "Complete"
        case false: return "Incomplete"
        default: return "Completion unknown"
        }
    }
}

private struct RecordingDetailView: View {
    let summary: RecordingSummary
    let goBack: () -> Void
    @State private var recording: LoadedRecording?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("All Recordings", systemImage: "chevron.left", action: goBack)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
            }
            Text(summary.startedAt?.formatted(date: .complete, time: .standard) ?? summary.url.lastPathComponent)
                .font(.title2.bold())
            Text(summary.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let recording {
                RecordingVisualization(recording: recording)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Try Again") { attempt += 1 }
            } else {
                ProgressView("Reading session…").frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: "\(summary.url.path)-\(attempt)") {
            recording = nil
            error = nil
            do {
                let url = summary.url
                let loaded = try await Task.detached(priority: .userInitiated) { try RecordingReader.load(url) }.value
                guard !Task.isCancelled else { return }
                recording = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct RecordingVisualization: View {
    let recording: LoadedRecording
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.locale) private var locale
    private let chartPoints: [RecordingSample]
    private let segments: [[CLLocationCoordinate2D]]
    @State private var camera: MapCameraPosition = .automatic
    @State private var satellite = true
    @State private var selectedTime: Double?
    private var displayUnits: DisplayUnits { preferences.units.resolved(locale: locale) }

    init(recording: LoadedRecording) {
        self.recording = recording
        chartPoints = recording.chartSamples()
        segments = recording.trackSegments.map { $0.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } }
    }

    private var selectedSample: RecordingSample? {
        selectedTime.flatMap { recording.nearestSample(to: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(RecordingTime.duration(recording.summary.duration), systemImage: "stopwatch")
                Spacer()
                Text("\(recording.summary.pointCount.formatted()) points")
            }
            .font(.headline)
            if recording.summary.complete == false {
                Label("Incomplete recording · \(recording.endReason ?? "Capture interrupted")",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            summaryPanel
            if segments.isEmpty {
                ContentUnavailableView("No valid GNSS track", systemImage: "map",
                                       description: Text("This session has no points with a valid position."))
                    .frame(height: 240)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Label("Track", systemImage: "map").font(.headline)
                        Spacer()
                        Toggle("Satellite", isOn: $satellite).toggleStyle(.switch).controlSize(.small)
                        Button("Fit Track") { camera = .automatic }
                    }
                    Map(position: $camera) {
                        ForEach(segments.indices, id: \.self) { index in
                            if segments[index].count > 1 {
                                MapPolyline(coordinates: segments[index]).stroke(.indigo, lineWidth: 4)
                            }
                        }
                        if let first = segments.first?.first { Marker("Start", systemImage: "flag", coordinate: first).tint(.green) }
                        if let last = segments.last?.last { Marker("Finish", systemImage: "flag.checkered", coordinate: last).tint(.orange) }
                        if let coordinate = selectedSample?.coordinate {
                            Annotation("Selected time", coordinate: CLLocationCoordinate2D(
                                latitude: coordinate.latitude, longitude: coordinate.longitude
                            )) {
                                Circle().fill(.white).frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.indigo, lineWidth: 4)).shadow(radius: 3)
                            }
                        }
                    }
                    .mapStyle(satellite ? .hybrid(elevation: .flat) : .standard(elevation: .flat))
                    .mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 370)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            speedChart
            VStack(alignment: .leading, spacing: 12) {
                Label("G-force over time", systemImage: "waveform.path").font(.headline)
                if chartPoints.isEmpty {
                    Text("No G-force samples in this recording.").foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(chartPoints) { point in
                            LineMark(x: .value("Time", point.elapsed), y: .value("G-force", point.gForceX),
                                     series: .value("Axis", "X"))
                                .foregroundStyle(by: .value("Axis", "X"))
                            LineMark(x: .value("Time", point.elapsed), y: .value("G-force", point.gForceY),
                                     series: .value("Axis", "Y"))
                                .foregroundStyle(by: .value("Axis", "Y"))
                        }
                        if let selectedSample {
                            RuleMark(x: .value("Selected time", selectedSample.elapsed))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartForegroundStyleScale(["X": Color.red, "Y": Color.green])
                    .chartXScale(domain: 0...max(recording.summary.duration, 0.04))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let seconds = value.as(Double.self) { Text(RecordingTime.axisLabel(seconds)) }
                            }
                        }
                    }
                    .chartYAxisLabel("G-force (g)")
                    .chartXAxisLabel("Elapsed time")
                    .chartXSelection(value: $selectedTime)
                    .frame(height: 240)
                    if let point = selectedSample {
                        HStack(spacing: 18) {
                            Text("At \(point.elapsed.formatted(.number.precision(.fractionLength(2)))) s").bold()
                            Text("Speed: \(speedLabel(point.speedKmh))").foregroundStyle(.orange)
                            axisReading("X", point.gForceX, color: .red)
                            axisReading("Y", point.gForceY, color: .green)
                        }
                        .font(.callout).monospacedDigit()
                    } else {
                        Text("Select a time on either chart to see speed, acceleration/braking (X), cornering (Y), and the matching track position.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var summaryPanel: some View {
        let statistics = recording.statistics
        return VStack(alignment: .leading, spacing: 12) {
            Label("Session summary", systemImage: "list.bullet.rectangle").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .top)], alignment: .leading, spacing: 12) {
                summaryMetric("Max speed", value: speedLabel(statistics.maxSpeedKmh), color: .orange)
                summaryMetric("Max acceleration (+X)", value: forceLabel(statistics.accelerationG), color: .red)
                summaryMetric("Max braking (−X)", value: forceLabel(statistics.brakingG), color: .purple)
                summaryMetric("Peak cornering (Y)", value: forceLabel(statistics.cornering?.magnitude),
                              color: .green, detail: directionalPeaks(statistics.cornering, axis: "Y"))
                summaryMetric("Peak vertical (Z)", value: forceLabel(statistics.vertical?.magnitude),
                              color: .blue, detail: directionalPeaks(statistics.vertical, axis: "Z"))
            }
            Text("Acceleration and braking are separate X-axis peaks. Cornering and vertical show the largest magnitude, with both directions below. Raw Z includes gravity.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Speed over time", systemImage: "speedometer").font(.headline)
            if recording.statistics.maxSpeedKmh == nil {
                Text("No valid GNSS speed samples in this recording.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(chartPoints) { point in
                        if let speed = point.speedKmh {
                            LineMark(x: .value("Time", point.elapsed),
                                     y: .value("Speed", displayUnits.speed(fromKmh: speed)),
                                     series: .value("GNSS segment", point.speedSegment))
                                .foregroundStyle(.orange)
                            PointMark(x: .value("Time", point.elapsed),
                                      y: .value("Speed", displayUnits.speed(fromKmh: speed)))
                                .foregroundStyle(.orange).symbolSize(5)
                        }
                    }
                    if let selectedSample {
                        RuleMark(x: .value("Selected time", selectedSample.elapsed)).foregroundStyle(.secondary)
                    }
                }
                .chartXScale(domain: 0...max(recording.summary.duration, 0.04))
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) { Text(RecordingTime.axisLabel(seconds)) }
                        }
                    }
                }
                .chartYAxisLabel("Speed (\(displayUnits.speedSymbol))")
                .chartXAxisLabel("Elapsed time")
                .chartXSelection(value: $selectedTime)
                .frame(height: 200)
            }
        }
    }

    private func speedLabel(_ speed: Double?) -> String {
        guard let speed else { return "—" }
        let value = displayUnits.speed(fromKmh: speed).formatted(.number.precision(.fractionLength(1)))
        return "\(value) \(displayUnits.speedSymbol)"
    }

    private func forceLabel(_ force: Double?) -> String {
        guard let force else { return "—" }
        return "\(force.formatted(.number.precision(.fractionLength(3)))) g"
    }

    private func directionalPeaks(_ peaks: GForcePeaks?, axis: String) -> String? {
        guard let peaks else { return nil }
        return "+\(axis) \(forceLabel(peaks.positive)) · −\(axis) \(forceLabel(-peaks.negative))"
    }

    private func summaryMetric(_ title: String, value: String, color: Color, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit().textSelection(.enabled)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func axisReading(_ axis: String, _ value: Double, color: Color) -> some View {
        Text("\(axis): \(value.formatted(.number.precision(.fractionLength(3)))) g").foregroundStyle(color)
    }
}
