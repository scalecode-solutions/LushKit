import SwiftUI

/// LushLab login — authenticates against mvServer via MvAuth. The same
/// account's JWT is what mvLush validates. Defaults to Local for development.
struct LoginView: View {
    let auth: AuthModel

    @State private var server: LabServer = .local
    @State private var username = ""
    @State private var password = ""
    @State private var localHost = UserDefaults.standard.string(forKey: "LushLab.localHost") ?? ""
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && !auth.isLoggingIn
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.pink.gradient)
                    .symbolEffect(.breathe.plain, options: .repeat(.continuous))
                Text("LushLab")
                    .font(.largeTitle.bold())
                Text("Sign in with your mvchat account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Picker("Server", selection: $server) {
                    ForEach(LabServer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if server == .local {
                    // A real phone can't reach the Mac's "localhost".
                    TextField("Mac's address (localhost)", text: $localHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote.monospaced())
                        .padding(10)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                        .onChange(of: localHost) { LabServer.localHost = localHost }
                }

                TextField("Username, handle, or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { submit() }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                if case .failed(let message) = auth.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    HStack {
                        if auth.isLoggingIn { ProgressView() }
                        Text(auth.isLoggingIn ? "Signing in…" : "Sign In").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubmit)
            }

            Spacer()
            Spacer()
        }
        .padding(28)
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await auth.login(server: server, username: username, password: password) }
    }
}
