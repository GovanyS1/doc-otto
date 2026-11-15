import SwiftUI
import UIKit
@preconcurrency import CoreBluetooth
import DocOttoDiagnostics

enum OttoTheme {
    // Doc Otto brand cyan: #00CCFF
    static let accent = Color(red: 0, green: 204.0 / 255.0, blue: 1)
    static let amber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.60, blue: 0.23, alpha: 1)
            : UIColor(red: 0.65, green: 0.33, blue: 0.02, alpha: 1)
    })
    static let buttonFill = accent
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

/// One-screen scanning prototype. Adapter configuration and diagnostic tools
/// live in Settings, leaving only the primary action and the code results here.
struct ContentView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image("DocOttoLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Doc Otto")
                        .padding(.bottom, 52)

                    Button(action: scanTapped) {
                        HStack(spacing: 10) {
                            if model.isScanning {
                                ProgressView()
                                    .tint(.black)
                            }
                            Text(model.isScanning ? "Cancel scan" : "Scan now")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.black)
                    .background(OttoTheme.accent, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("primaryScanAction")
                    .padding(.bottom, 42)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Diagnostics")
                            .font(.title2.weight(.bold))
                        Spacer()
                        if model.isDemo && model.hasResult {
                            Text("Sample data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 16)

                    diagnostics
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(OttoTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func scanTapped() {
        if model.isScanning {
            model.cancel()
        } else if model.hasConnection {
            model.startScan()
        } else {
            // Only first-time adapter configuration needs another screen.
            onOpenSettings()
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if model.isScanning {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(OttoTheme.accent)
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("scanStatus")
        } else if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase == .cancelled ? "Scan cancelled" : "Scan failed")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("scanStatus")
        } else if let result = model.result {
            if result.faultRead.faults.isEmpty {
                emptyMessage("No pending or confirmed engine codes found.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(result.faultRead.faults, id: \.code) { fault in
                        DiagnosticCodeRow(
                            code: fault.code,
                            status: fault.supportedStatus & 0x08 != 0 ? "Confirmed" : "Pending"
                        )
                    }
                }
            }
        } else if let result = model.genericResult {
            if result.codes.isEmpty {
                emptyMessage("No emissions-related diagnostic codes found.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(result.codes) { item in
                        DiagnosticCodeRow(code: item.code, status: item.status.rawValue.capitalized)
                    }
                }
            }
        } else {
            emptyMessage("No scan results yet.")
        }
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("scanStatus")
    }
}

private struct DiagnosticCodeRow: View {
    let code: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Spacer()
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(OttoTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Secondary diagnostic utilities stay available without appearing on Scan.
struct PrototypeSettingsView: View {
    @ObservedObject var model: ScanViewModel
    @State private var showingConnection = false
    @State private var showingLog = false
    @State private var shareItem: SharedReport?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Scanner") {
                    Button {
                        showingConnection = true
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Connection settings")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(model.connectionSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(model.isScanning)
                    .accessibilityIdentifier("connectionSettings")
                }

                if model.canExport {
                    Section("Last scan") {
                        Button("Scan log") { showingLog = true }
                        Button("Share report", action: shareReport)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingConnection) {
                ConnectionView(model: model)
            }
            .sheet(isPresented: $showingLog) {
                ScanLogView(model: model)
            }
            .sheet(item: $shareItem) { item in
                ReportShareView(url: item.url)
            }
            .alert("Report could not be created", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private func shareReport() {
        do { shareItem = SharedReport(url: try model.exportReport()) }
        catch { exportError = error.localizedDescription }
    }
}

private struct ConnectionView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BLEDiscovery()
    @State private var medium: ConnectionMedium = .wifi
    @State private var scannerProtocol: WiFiScannerProtocol = .standard
    @State private var autoDiscoverENET = true
    @State private var host = ""
    @State private var port = "35000"
    @State private var selectedID: UUID?
    @State private var selectedName = ""
    @State private var preset: BLEUARTPreset = .ffe0
    @State private var service = ""
    @State private var write = ""
    @State private var notify = ""
    @State private var withResponse = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection type") {
                    Picker("Adapter", selection: $medium) {
                        ForEach(ConnectionMedium.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented)
                }
                if medium == .wifi {
                    Section {
                        Picker("Scanner protocol", selection: $scannerProtocol) {
                            ForEach(WiFiScannerProtocol.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                        if scannerProtocol == .bmwENET {
                            Toggle("Find BMW gateway automatically", isOn: $autoDiscoverENET)
                                .accessibilityIdentifier("automaticENETDiscovery")
                        }
                        if scannerProtocol == .standard || !autoDiscoverENET {
                            TextField("Adapter IP (for example 192.168.0.10)", text: $host)
                                .keyboardType(.decimalPad)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("gatewayHost")
                        }
                        if scannerProtocol == .standard {
                            TextField("TCP port", text: $port).keyboardType(.numberPad)
                        } else { LabeledContent("Port", value: "6801") }
                    } header: { Text("Wi-Fi adapter") } footer: {
                        Text(scannerProtocol == .standard ?
                             "Join the adapter Wi-Fi in iPhone Settings. Use the IP and TCP port documented by its manufacturer (often 35000)." :
                             (autoDiscoverENET ?
                              "Join the MHD ENET Wi-Fi first. Discovery uses UDP broadcast and requires Apple's Multicast Networking entitlement on a physical iPhone. If unavailable, turn this off and enter a verified gateway IP." :
                              "Manual fallback: enter a verified MHD ENET diagnostic gateway IP. This is not a universal scanner."))
                    }
                } else {
                    Section {
                        Button(discovery.scanning ? "Stop searching" : "Search for BLE scanners") {
                            discovery.scanning ? discovery.stop() : discovery.start()
                        }
                        if let message = discovery.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        ForEach(discovery.devices) { device in
                            Button {
                                selectedID = device.id
                                selectedName = device.name
                            } label: {
                                HStack {
                                    Text(device.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedID == device.id { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                        if let selectedID { Text("Selected: \(selectedName) (\(selectedID.uuidString))").font(.caption) }
                        Picker("BLE UART profile", selection: $preset) {
                            ForEach(BLEUARTPreset.allCases) { value in Text(value.rawValue).tag(value) }
                        }
                        if preset == .custom {
                            TextField("Service UUID", text: $service).textInputAutocapitalization(.characters)
                            TextField("Write characteristic UUID", text: $write).textInputAutocapitalization(.characters)
                            TextField("Notify characteristic UUID", text: $notify).textInputAutocapitalization(.characters)
                            Toggle("Write with response", isOn: $withResponse)
                        }
                    } header: { Text("Bluetooth LE scanner") } footer: {
                        Text("BLE only, not Bluetooth Classic SPP. Choose the UART profile documented by the adapter vendor; a detected device is not necessarily ELM327-compatible. BLE scanning requires a physical iPhone.")
                    }
                }
                Section("Before you scan") {
                    Text("Park the vehicle, plug in the scanner and turn the ignition on. Close other diagnostic apps. Generic scans are read-only.")
                        .font(.subheadline)
                }
                if let validationError {
                    Section { Text(validationError).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discovery.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try model.saveConnection(medium: medium, wifiProtocol: scannerProtocol,
                                host: host, port: port, peripheralID: selectedID, peripheralName: selectedName,
                                blePreset: preset, service: service, write: write,
                                notify: notify, withResponse: withResponse,
                                autoDiscoverENET: autoDiscoverENET)
                            discovery.stop()
                            dismiss()
                        } catch { validationError = error.localizedDescription }
                    }.disabled(model.isScanning)
                     .accessibilityIdentifier("saveConnection")
                }
            }
            .onAppear {
                medium = model.medium; scannerProtocol = model.wifiProtocol
                autoDiscoverENET = model.autoDiscoverENET
                host = model.host; port = model.portString
                selectedID = model.peripheralID; selectedName = model.peripheralName
                preset = model.blePreset; service = model.customService
                write = model.customWrite; notify = model.customNotify
                withResponse = model.customWithResponse
            }
            .onDisappear { discovery.stop() }
        }
    }
}

@MainActor
private final class BLEDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Device: Identifiable { let id: UUID; let name: String }
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var message: String?
    private var manager: CBCentralManager?

    func start() {
        devices = []
        scanning = true
        message = "Looking for nearby Bluetooth LE adapters…"
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        manager?.stopScan()
        manager?.delegate = nil
        manager = nil
        scanning = false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard scanning else { return }
        if central.state == .poweredOn {
            message = "Choose your scanner from the discovered devices."
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if central.state == .unauthorized {
            message = "Allow Bluetooth access for Doc Otto in Settings."
            stop()
        } else if central.state == .poweredOff {
            message = "Turn on Bluetooth to discover an adapter."
            stop()
        } else if central.state == .unsupported {
            message = "Bluetooth LE discovery is unavailable on this device."
            stop()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unnamed BLE device"
        devices.append(Device(id: peripheral.identifier, name: name))
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct ScanLogView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.isDemo ? "Demo session · synthetic data" : "Latest scan · local session")
                    Text("The report contains the VIN, endpoint, status masks, and available raw frames. Share it only when you intend to share those details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Events") {
                    ForEach(model.events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.message).font(.subheadline)
                            if let hex = event.hex, !hex.isEmpty {
                                Text(hex).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SharedReport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ReportShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
