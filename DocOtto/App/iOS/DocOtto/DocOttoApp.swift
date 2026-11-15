import SwiftUI

@main
struct DocOttoApp: App {
    @StateObject private var model = ScanViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .scan

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView(model: model, onOpenSettings: { selectedTab = .settings })
                    .tabItem { Label("Scan", systemImage: "waveform.path.ecg") }
                    .tag(AppTab.scan)

                UpcomingTabView(
                    title: "Live Data",
                    symbol: "speedometer",
                    detail: "Live vehicle gauges and sensor readings will appear here."
                )
                .tabItem { Label("Live", systemImage: "speedometer") }
                .tag(AppTab.live)

                UpcomingTabView(
                    title: "Scan History",
                    symbol: "clock.arrow.circlepath",
                    detail: "Saved scans and previous diagnostic results will appear here."
                )
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

                PrototypeSettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
            }
                // SwiftUI supplies the native floating Liquid Glass tab bar on
                // iOS 26+ and a standard system tab bar on earlier versions.
                .tint(OttoTheme.accent)
                .onChange(of: scenePhase) { phase in
                    // A permission alert makes the app inactive; only backgrounding
                    // ends a scan, so the Local Network prompt can be answered.
                    if phase == .background { model.suspend() }
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--demo") {
                        model.startDemo()
                    }
                    #endif
                }
        }
    }
}

private enum AppTab: Hashable {
    case scan
    case live
    case history
    case settings
}

private struct UpcomingTabView: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(OttoTheme.accent)
                    .frame(width: 90, height: 90)
                    .background(OttoTheme.accent.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(.title, design: .rounded).weight(.bold))

                Text("Coming soon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OttoTheme.accent)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OttoTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
