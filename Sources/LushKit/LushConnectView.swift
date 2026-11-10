import SwiftUI

/// Find a toy and connect it. Scanning runs only while this screen is up.
/// The first time, opening it brings up the system's Bluetooth prompt.
public struct LushConnectView: View {
    @Bindable var bluetooth: LushBluetooth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(bluetooth: LushBluetooth) {
        self.bluetooth = bluetooth
    }

    public var body: some View {
        List {
            if !bluetooth.toys.isEmpty {
                Section("Connected") {
                    ForEach(bluetooth.toys, id: \.hwKey) { toy in
                        HStack {
                            Label(toy.name, systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if let b = toy.battery {
                                Text("\(b)%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Button("Disconnect", role: .destructive) { bluetooth.disconnect(hwKey: toy.hwKey) }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                        }
                    }
                }
            }

            switch bluetooth.availability {
            case .idle, .starting:
                Section { HStack { ProgressView(); Text("Getting Bluetooth ready…").foregroundStyle(.secondary) } }
            case .poweredOff:
                problem("Bluetooth is off", "Turn Bluetooth on in Control Center or Settings.", settings: false)
            case .denied:
                problem("Bluetooth isn't allowed", "Allow Bluetooth for this app in Settings to connect a toy.", settings: true)
            case .unsupported:
                problem("No Bluetooth here", "This device can't connect to toys.", settings: false)
            case .ready:
                Section {
                    if bluetooth.found.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for toys. Turn yours on and keep it close.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(bluetooth.found) { toy in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toy.model)
                                Text(toy.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if bluetooth.connecting.contains(toy.id) {
                                ProgressView()
                            } else {
                                Button("Connect") { bluetooth.connect(toy.id) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    if let error = bluetooth.lastError {
                        Text(error).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Connect a toy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { bluetooth.scan() }
        .onDisappear { bluetooth.stopScan() }
    }

    private func problem(_ title: String, _ detail: String, settings: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "exclamationmark.triangle").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }.padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
