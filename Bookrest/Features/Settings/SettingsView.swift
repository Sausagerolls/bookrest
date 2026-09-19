import SwiftUI
import ABSClient
import BookrestCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingSignOut = false
    @State private var storageUsed: Int64 = 0

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Skip Forward", selection: Binding(
                    get: { environment.player.skipForwardInterval },
                    set: { environment.player.skipForwardInterval = $0 }
                )) {
                    ForEach(SkipInterval.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("Skip Back", selection: Binding(
                    get: { environment.player.skipBackwardInterval },
                    set: { environment.player.skipBackwardInterval = $0 }
                )) {
                    ForEach(SkipInterval.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("Default Speed", selection: Binding(
                    get: { environment.player.rate },
                    set: { environment.player.setRate($0) }
                )) {
                    ForEach(PlaybackRate.options, id: \.self) { rate in
                        Text(PlaybackRate.format(rate)).tag(rate)
                    }
                }
            }

            Section {
                Toggle("Immersive Theme", isOn: Binding(
                    get: { environment.theme.isImmersive },
                    set: {
                        environment.theme.isImmersive = $0
                        environment.theme.update(for: environment.player.context)
                    }
                ))
            } header: {
                Text("Appearance")
            } footer: {
                Text("Tints the app with colours drawn from the cover of whatever is playing.")
            }

            Section {
                Toggle("Download over Cellular", isOn: Binding(
                    get: { environment.downloads.allowsCellularAccess },
                    set: { environment.downloads.allowsCellularAccess = $0 }
                ))
                LabeledContent("Storage Used", value: Format.bytes(storageUsed))
                if let free = StorageLocations.availableCapacityBytes() {
                    LabeledContent("Available", value: Format.bytes(free))
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Turning this off restricts new downloads to Wi‑Fi.")
            }

            Section("Server") {
                if let connection = environment.connection {
                    LabeledContent("Address", value: connection.displayHost)
                    LabeledContent("Signed in as", value: connection.username)
                }
                Button("Sign Out", role: .destructive) { isConfirmingSignOut = true }
            }

            Section {
                LabeledContent("Version", value: DeviceIdentity.clientVersion)
            }
        }
        .formStyle(.grouped)
        .immersiveScrollBackground(environment.theme.activePalette)
        .navigationTitle("Settings")
        .task { storageUsed = await environment.offlineStore.totalBytesOnDisk() }
        .confirmationDialog("Sign out of Bookrest?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await environment.signOut() }
            }
        } message: {
            Text("Downloads stay on this device and will be available when you sign back in.")
        }
    }
}
