import SwiftUI
import ABSClient
import BookrestCore

/// Server address and credentials.
///
/// The address is validated against `/ping` before credentials are sent, so a typo
/// in the host is reported as "can't reach that server" rather than the much more
/// confusing "wrong password".
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var stage: Stage = .server
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Stage { case server, credentials }
    private enum Field: Hashable { case server, username, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                VStack(spacing: 16) {
                    serverField

                    if stage == .credentials {
                        credentialFields
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    primaryButton
                }
                .frame(maxWidth: 380)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.25), value: stage)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focusedField = .server }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Bookrest")
                .font(.largeTitle.weight(.semibold))
            Text("Connect to your Audiobookshelf server")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server Address")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("audiobooks.example.com", text: $serverAddress)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .server)
                .disabled(stage == .credentials)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .onSubmit { Task { await advance() } }

            if stage == .server {
                Text("https:// is assumed if you leave off the scheme.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .username)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await advance() } }

            Button("Use a different server") {
                stage = .server
                errorMessage = nil
                focusedField = .server
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var primaryButton: some View {
        Button {
            Task { await advance() }
        } label: {
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Text(stage == .server ? "Continue" : "Sign In")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking || !canSubmit)
    }

    private var canSubmit: Bool {
        switch stage {
        case .server: !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
        case .credentials: !username.isEmpty && !password.isEmpty
        }
    }

    private func advance() async {
        guard canSubmit, !isWorking else { return }
        guard let url = ServerConnection.normalize(urlString: serverAddress) else {
            errorMessage = "That doesn't look like a valid server address."
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        switch stage {
        case .server:
            do {
                try await environment.client.ping(serverURL: url)
                stage = .credentials
                focusedField = .username
            } catch {
                errorMessage = "Couldn't reach that server. Check the address and that it's running."
            }

        case .credentials:
            do {
                try await environment.signIn(serverURL: url, username: username, password: password)
            } catch let error as ABSError where error == .unauthorized {
                errorMessage = "Incorrect username or password."
            } catch {
                errorMessage = (error as? ABSError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
