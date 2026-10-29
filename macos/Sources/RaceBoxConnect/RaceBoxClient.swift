import AppKit
import CoreBluetooth
import RaceBoxCore
import SwiftUI

struct NearbyDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

struct SavedRecording: Identifiable {
    let url: URL
    let points: Int
    let complete: Bool
    var id: URL { url }
}

struct DownloadConfirmation: Identifiable {
    let id = UUID()
    let directory: URL
    let files: [URL]
    let skippedFiles: [URL]
    let duplicateCheckIssues: [RecordingLoadIssue]
    let pointCount: Int
    let hasIncompleteRecordings: Bool
    let deletionRequested: Bool
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var directory: String {
        didSet { UserDefaults.standard.set(directory, forKey: "downloadDirectory") }
    }
    @Published var deleteAfterDownload: Bool {
        didSet { UserDefaults.standard.set(deleteAfterDownload, forKey: "deleteAfterDownload") }
    }
    @Published var connectAutomatically: Bool {
        didSet { UserDefaults.standard.set(connectAutomatically, forKey: "connectAutomatically") }
    }
    @Published var format: ExportFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "exportFormat") }
    }
    @Published var units: DisplayUnits {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "displayUnits") }
    }

    private init() {
        directory = UserDefaults.standard.string(forKey: "downloadDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        deleteAfterDownload = UserDefaults.standard.bool(forKey: "deleteAfterDownload")
        connectAutomatically = UserDefaults.standard.bool(forKey: "connectAutomatically")
        format = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "exportFormat") ?? "JSON") ?? .json
        units = DisplayUnits(rawValue: UserDefaults.standard.string(forKey: "displayUnits") ?? "automatic") ?? .automatic
    }

    var directoryURL: URL { URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath) }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directoryURL
        panel.prompt = "Choose Download Folder"
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}

final class RaceBoxClient: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = RaceBoxClient()
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var devices: [NearbyDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var deviceName = "Your next adventure awaits"
    @Published private(set) var connectionStatus = "Connect your RaceBox Mini S to get started."
    @Published private(set) var message = "Ready when you are."
    @Published private(set) var telemetry: Telemetry?
    @Published private(set) var memory: MemoryStatus?
    @Published private(set) var recordingConfiguration: RecordingConfiguration?
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var capturing = false
    @Published private(set) var pointsSaved = 0
    @Published private(set) var rejectedFrames = 0
    @Published private(set) var progress: Double?
    @Published private(set) var recordings: [SavedRecording] = []
    @Published var errorMessage: String?
    @Published var downloadConfirmation: DownloadConfirmation?
    @Published var securityCode = ""

    enum Operation: String {
        case idle, unlockingDownload, checkingDownload, downloading
        case unlockingErase, checkingErase, erasing
        case unlockingRecording, readingRecordingConfiguration, settingRecording, verifyingRecording
        var isDownload: Bool { [.unlockingDownload, .checkingDownload, .downloading].contains(self) }
        var isErase: Bool { [.unlockingErase, .checkingErase, .erasing].contains(self) }
    }

    var busy: Bool { operation != .idle || capturing }
    var activeRecordingURLs: Set<URL> {
        Set([liveCapture?.url, download?.activeFileURL].compactMap { $0 })
    }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var decoder = PacketDecoder()
    private var latestTelemetry: Telemetry?
    private var latestTelemetryAt: Date?
    private var dashboardTimer: Timer?
    private var watchdog: Timer?
    private var scanTimer: Timer?
    private var launchScanPending = true
    private var download: HistoryDownload?
    private var liveCapture: LiveCapture?
    private var liveFormat: ExportFormat = .json
    private var operationInvalidStart = 0
    private var deleteWhenDone = false
    private var exportDirectory: URL?
    private var exportFormat: ExportFormat = .json
    private var lastPacketAt = Date()
    private var operationStartedAt = Date()
    private var commandQueue: [Packet] = []
    private var commandPending = false
    private var standaloneTarget: Bool?
    private var lastMemoryPollAt = Date()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        dashboardTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshDashboard()
        }
    }

    private func refreshDashboard() {
        if let latestTelemetryAt, Date().timeIntervalSince(latestTelemetryAt) < 3 {
            telemetry = latestTelemetry
        } else {
            telemetry = nil
        }
        rejectedFrames = decoder.invalidFrames
        if let download, operation == .downloading {
            pointsSaved = download.received
            if let expected = download.expected, expected > 0 {
                progress = min(1, Double(download.received) / Double(expected))
            }
        } else if capturing {
            pointsSaved = liveCapture?.count ?? 0
        }
        if connected, operation == .idle, recordingConfiguration?.enabled == true,
           Date().timeIntervalSince(lastMemoryPollAt) >= 5 {
            lastMemoryPollAt = Date()
            send(Packet(id: 0x22))
        }
    }

    func scan(automaticallyConnect: Bool = false) {
        guard central.state == .poweredOn, !connected, !connecting else {
            if central.state != .poweredOn {
                errorMessage = "Bluetooth must be enabled and access allowed in System Settings → Privacy & Security → Bluetooth."
            }
            return
        }
        devices = []
        scanning = true
        connectionStatus = automaticallyConnect
            ? "Looking for the RaceBox with the strongest signal…"
            : "Looking for nearby RaceBox devices…"
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: automaticallyConnect ? 3 : 20, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stopScanning()
            if automaticallyConnect && Preferences.shared.connectAutomatically {
                if let strongest = self.devices.filter({ $0.rssi != 127 }).max(by: { $0.rssi < $1.rssi }) {
                    self.connect(strongest)
                    return
                }
                self.connectionStatus = self.devices.isEmpty
                    ? "No Mini S found. Power it on and click Find RaceBox to try again."
                    : "No valid signal readings. Choose a device in the sidebar."
                return
            }
            self.connectionStatus = self.devices.isEmpty
                ? "No Mini S found. Power it on and close other RaceBox apps."
                : "Choose a device in the sidebar."
        }
    }

    private func stopScanning() {
        central.stopScan()
        scanning = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func connect(_ device: NearbyDevice) {
        guard !connected, !connecting else { return }
        stopScanning()
        peripheral = device.peripheral
        peripheral?.delegate = self
        connecting = true
        deviceName = device.name
        connectionStatus = "Connecting…"
        decoder = PacketDecoder()
        central.connect(device.peripheral)
        startWatchdog()
    }

    func disconnect() {
        interrupt(reason: "Device disconnected")
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
    }

    private func resetConnection() {
        connected = false
        connecting = false
        writeCharacteristic = nil
        peripheral = nil
        telemetry = nil
        latestTelemetry = nil
        latestTelemetryAt = nil
        memory = nil
        recordingConfiguration = nil
        commandQueue = []
        commandPending = false
        watchdog?.invalidate()
        watchdog = nil
        connectionStatus = "Disconnected"
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            connectionStatus = "Bluetooth is ready. Find your RaceBox."
            if launchScanPending {
                launchScanPending = false
                scan(automaticallyConnect: Preferences.shared.connectAutomatically)
            }
        } else {
            stopScanning()
            if connected || connecting {
                interrupt(reason: "Bluetooth became unavailable")
                resetConnection()
            }
            switch central.state {
            case .unauthorized: connectionStatus = "Allow Bluetooth access in System Settings → Privacy & Security."
            case .poweredOff: connectionStatus = "Turn on Bluetooth to connect."
            case .unsupported: connectionStatus = "This Mac does not support Bluetooth Low Energy."
            default: connectionStatus = "Waiting for Bluetooth…"
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.hasPrefix("RaceBox Mini S") else { return }
        let device = NearbyDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral == peripheral else { return }
        connectionStatus = "Discovering native Bluetooth services…"
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral == peripheral else { return }
        errorMessage = error?.localizedDescription ?? "The RaceBox could not be connected."
        resetConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral == peripheral else { return }
        interrupt(reason: error?.localizedDescription ?? "Device disconnected")
        resetConnection()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral == peripheral else { return }
        if let error { failConnection(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failConnection("The RaceBox UART service is missing.")
            return
        }
        peripheral.discoverCharacteristics([Self.rx, Self.tx], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral == peripheral else { return }
        if let error { failConnection(error.localizedDescription); return }
        guard let rx = service.characteristics?.first(where: { $0.uuid == Self.rx }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.tx }),
              rx.properties.contains(.write), tx.properties.contains(.notify) else {
            failConnection("Required RaceBox Bluetooth characteristics are missing.")
            return
        }
        writeCharacteristic = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard self.peripheral == peripheral else { return }
        if let error { failConnection(error.localizedDescription); return }
        guard characteristic.isNotifying else {
            failConnection("Bluetooth notifications stopped.")
            return
        }
        connected = true
        connecting = false
        connectionStatus = "Connected over Bluetooth"
        message = "Telemetry is live. Download history or start a capture."
        lastPacketAt = Date()
        send(Packet(id: 0x22))
        send(Packet(id: 0x25))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral == peripheral else { return }
        commandPending = false
        if let error { failConnection("Bluetooth command failed: \(error.localizedDescription)"); return }
        flushCommands()
    }

    private func send(_ packet: Packet) {
        guard connected, peripheral != nil, writeCharacteristic != nil else {
            failConnection("The device is not ready to receive commands.")
            return
        }
        commandQueue.append(packet)
        flushCommands()
    }

    private func flushCommands() {
        guard !commandPending, let peripheral, let writeCharacteristic, !commandQueue.isEmpty else { return }
        commandPending = true
        peripheral.writeValue(commandQueue.removeFirst().data, for: writeCharacteristic, type: .withResponse)
    }

    private func failConnection(_ reason: String) {
        interrupt(reason: reason)
        if let finalizationError = errorMessage, finalizationError != reason {
            errorMessage = "\(reason)\n\n\(finalizationError)"
        } else {
            errorMessage = reason
        }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
    }

    private func startWatchdog() {
        lastPacketAt = Date()
        operationStartedAt = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let awaitingCommand = self.operation != .idle && self.operation != .downloading && self.operation != .erasing
            let commandTimedOut = awaitingCommand && Date().timeIntervalSince(self.operationStartedAt) > 30
            let transportTimedOut = Date().timeIntervalSince(self.lastPacketAt) > (self.operation == .erasing ? 180 : 30)
            if commandTimedOut || transportTimedOut {
                self.failConnection("The RaceBox did not respond in time. Saved data was preserved; reconnect to try again.")
            }
        }
    }

    private func beginUnlock(for newOperation: Operation) {
        let code: UInt32
        if securityCode.isEmpty { code = 0 }
        else if let parsed = UInt32(securityCode) { code = parsed }
        else {
            errorMessage = "The memory security code must be an unsigned 32-bit integer."
            return
        }
        operation = newOperation
        operationInvalidStart = decoder.invalidFrames
        progress = nil
        pointsSaved = 0
        operationStartedAt = Date()
        send(.unlock(code: code))
    }

    func downloadHistory() {
        guard connected, !busy else { return }
        let preferences = Preferences.shared
        exportDirectory = preferences.directoryURL
        exportFormat = preferences.format
        deleteWhenDone = preferences.deleteAfterDownload
        message = "Unlocking recorded memory…"
        beginUnlock(for: .unlockingDownload)
    }

    func clearMemory() {
        guard connected, !busy else { return }
        message = "Checking memory before clearing…"
        beginUnlock(for: .unlockingErase)
    }

    func toggleStandaloneRecording() {
        guard connected, !busy, let configuration = recordingConfiguration else { return }
        standaloneTarget = !configuration.enabled
        message = configuration.enabled ? "Stopping standalone recording…" : "Starting standalone recording…"
        beginUnlock(for: .unlockingRecording)
        if operation != .unlockingRecording { standaloneTarget = nil }
    }

    private func finishStandaloneChange() {
        let enabled = standaloneTarget == true
        standaloneTarget = nil
        operation = .idle
        message = enabled
            ? "Standalone recording started. Data is saved on your RaceBox, even after disconnecting."
            : "Standalone recording stopped. Your device recordings are ready to download."
        lastMemoryPollAt = Date()
        send(Packet(id: 0x22))
    }

    func startCapture() {
        guard connected, !busy else { return }
        liveFormat = Preferences.shared.format
        operationInvalidStart = decoder.invalidFrames
        liveCapture = LiveCapture(directory: Preferences.shared.directoryURL, format: liveFormat)
        capturing = true
        pointsSaved = 0
        message = "Waiting for a valid 3D fix. Live capture will start automatically."
        lastPacketAt = Date()
    }

    func stopCapture(complete: Bool = true, reason: String = "Stopped by user") {
        guard capturing else { return }
        capturing = false
        let invalid = decoder.invalidFrames - operationInvalidStart
        if let capture = liveCapture {
            liveCapture = nil
            do {
                if let recording = try capture.finish(complete: complete, invalidFrames: invalid, reason: reason) {
                    recordings.insert(SavedRecording(url: recording.url, points: recording.pointCount,
                                                     complete: recording.complete), at: 0)
                    pointsSaved = recording.pointCount
                    message = recording.complete
                        ? "Capture saved. A little adventure, safely on disk."
                        : "Capture preserved as incomplete: \(reason)"
                } else {
                    message = "No capture created: no valid GNSS points were received."
                }
            } catch {
                errorMessage = "Could not finalize the live capture: \(error.localizedDescription)"
            }
        }
    }

    func cancelDownload() {
        guard operation.isDownload else { return }
        // Disconnect after cancelling; the firmware may flush history for several more seconds.
        if operation == .downloading { send(Packet(id: 0x23, payload: [0xff])) }
        interrupt(reason: "Download cancelled")
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
    }

    private func interrupt(reason: String) {
        if capturing { stopCapture(complete: false, reason: reason) }
        if let download {
            let invalid = decoder.invalidFrames - operationInvalidStart
            do {
                try download.interrupt(reason: reason, invalidFrames: invalid)
                addDownloadFiles(download)
            } catch {
                errorMessage = "Could not finalize the download: \(error.localizedDescription)"
            }
            self.download = nil
        }
        if operation != .idle {
            message = operation.isErase
                ? "Operation interrupted: \(reason). Device memory may be partially cleared if an erase had already started."
                : "Operation interrupted: \(reason). Reconnect to verify the device's current state."
        }
        operation = .idle
        standaloneTarget = nil
        progress = nil
    }

    private func addDownloadFiles(_ download: HistoryDownload) {
        for recording in download.recordings where !recordings.contains(where: { $0.url == recording.url }) {
            recordings.insert(SavedRecording(url: recording.url, points: recording.pointCount,
                                             complete: recording.complete), at: 0)
        }
    }

    func shutdown() {
        if capturing { stopCapture(reason: "Application closed") }
        interrupt(reason: "Application closed")
        stopScanning()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral == peripheral else { return }
        if let error { failConnection(error.localizedDescription); return }
        guard let data = characteristic.value else { return }
        let packets = decoder.receive(data)
        do {
            for packet in packets where packet.messageClass == 0xff {
                try handle(packet)
            }
        } catch {
            failConnection(error.localizedDescription)
        }
    }

    private func handle(_ packet: Packet) throws {
        if packet.id == 0x01 {
            let point = try Telemetry(packet: packet)
            latestTelemetry = point
            latestTelemetryAt = Date()
            if operation == .idle { lastPacketAt = Date() }
            if capturing, let liveCapture {
                if try liveCapture.receive(point) {
                    message = "Recording live telemetry to \(liveFormat.rawValue)…"
                } else {
                    message = liveCapture.count == 0 ? "Acquiring a 3D fix. Waiting to record…" : "Fix lost. Logging paused until it returns."
                }
            }
            return
        }
        if packet.id == 0x03 {
            let command = packet.payload.count == 2 ? packet.payload[1] : 0
            if command == 0x25 {
                throw RaceBoxError.protocolError("RaceBox rejected the standalone recording command. Memory may be full or locked, or its recording configuration may not be supported.")
            }
            throw RaceBoxError.protocolError(String(format: "RaceBox rejected command 0x%02X. Check the memory security code and that no other operation is running.", command))
        }
        if packet.id == 0x02, packet.payload == [0xff, 0x30] {
            if operation == .unlockingDownload {
                operation = .checkingDownload
                send(Packet(id: 0x22))
            } else if operation == .unlockingErase {
                operation = .checkingErase
                send(Packet(id: 0x22))
            } else if operation == .unlockingRecording {
                operation = .readingRecordingConfiguration
                send(Packet(id: 0x25))
            }
            return
        }
        if packet.id == 0x02, packet.payload == [0xff, 0x25], operation == .settingRecording {
            operation = .verifyingRecording
            send(Packet(id: 0x25))
            return
        }
        if packet.id == 0x25 {
            let configuration = try RecordingConfiguration(payload: packet.payload)
            recordingConfiguration = configuration
            lastPacketAt = Date()
            if operation == .readingRecordingConfiguration || operation == .verifyingRecording {
                guard let target = standaloneTarget else {
                    throw RaceBoxError.protocolError("The requested standalone recording state is unavailable.")
                }
                if operation == .readingRecordingConfiguration && configuration.enabled != target {
                    operation = .settingRecording
                    send(configuration.command(enabled: target))
                } else {
                    guard configuration.enabled == target else {
                        throw RaceBoxError.protocolError("The device did not confirm the requested standalone recording state.")
                    }
                    finishStandaloneChange()
                }
            }
            return
        }
        if packet.id == 0x22 {
            let status = try MemoryStatus(payload: packet.payload)
            memory = status
            lastMemoryPollAt = Date()
            lastPacketAt = Date()
            if operation == .checkingDownload || operation == .checkingErase {
                guard !status.securityEnabled || status.unlocked else {
                    throw RaceBoxError.protocolError("Memory is locked. Enter its security code in Preferences.")
                }
                if operation == .checkingDownload {
                    guard let exportDirectory else {
                        throw RaceBoxError.fileError("No download directory selected.")
                    }
                    if deleteWhenDone && status.recording {
                        throw RaceBoxError.protocolError("Delete after downloading is enabled, but standalone recording is active. Stop standalone recording, or turn off automatic deletion in Preferences.")
                    }
                    download = HistoryDownload(status: status, directory: exportDirectory, format: exportFormat)
                    operation = .downloading
                    message = "Downloading stored recordings…"
                    send(Packet(id: 0x23))
                } else {
                    guard !status.recording else {
                        throw RaceBoxError.protocolError("Memory cannot be cleared while standalone recording is active. Stop standalone recording first.")
                    }
                    operation = .erasing
                    operationStartedAt = Date()
                    message = "Clearing device memory. Keep your RaceBox powered on…"
                    send(Packet(id: 0x24))
                }
            }
            return
        }
        if packet.id == 0x26, operation == .idle {
            send(Packet(id: 0x22))
            send(Packet(id: 0x25))
            return
        }
        if operation == .downloading, let download,
           [0x21, 0x23, 0x26, 0x02].contains(packet.id) {
            lastPacketAt = Date()
            let done = try download.receive(packet, invalidFrames: decoder.invalidFrames - operationInvalidStart)
            if done {
                guard let exportDirectory else {
                    throw RaceBoxError.fileError("Download saved, but its destination is unavailable.")
                }
                pointsSaved = download.received
                addDownloadFiles(download)
                self.download = nil
                operation = .idle
                progress = nil
                let directory = exportDirectory.appendingPathComponent("racebox_sessions")
                message = "Saved \(download.savedPointCount.formatted()) new points across \(download.files.count) recordings to \(directory.path). \(download.skippedRecordings.count) already downloaded."
                downloadConfirmation = DownloadConfirmation(
                    directory: directory, files: download.files,
                    skippedFiles: download.skippedRecordings.map(\.url), pointCount: download.savedPointCount,
                    duplicateCheckIssues: download.duplicateCheckIssues,
                    hasIncompleteRecordings: download.recordings.contains { !$0.complete },
                    deletionRequested: deleteWhenDone
                )
                if deleteWhenDone {
                    guard download.safeToErase else {
                        throw RaceBoxError.protocolError("Download saved, but it is not safe to delete device memory. No erase was sent.")
                    }
                    // Recheck the device's current recording state immediately before erasing.
                    operation = .checkingErase
                    operationStartedAt = Date()
                    send(Packet(id: 0x22))
                }
            }
        } else if operation == .erasing {
            if packet.id == 0x24 {
                guard packet.payload.count == 1, packet.payload[0] <= 100 else {
                    throw RaceBoxError.protocolError("Invalid erase-progress response.")
                }
                lastPacketAt = Date()
                progress = Double(packet.payload[0]) / 100
            } else if packet.id == 0x02, packet.payload == [0xff, 0x24] {
                operation = .idle
                progress = nil
                lastPacketAt = Date()
                message = "Device memory cleared. Ready for the next adventure."
                send(Packet(id: 0x22))
            }
        }
    }
}
