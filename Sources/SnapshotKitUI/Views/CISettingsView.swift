import SnapshotKitCore
import SwiftUI

/// What CI jobs load with: the GitLab project and how SnapshotKit signs in to it, and the SSH login on the
/// runners, which copies the images a failed job's tests took. Shown from the CI section and a job's header.
struct CISettingsView: View {
    let project: ProjectModel
    /// How SnapshotKit signs in, when not this process's (the snapshot tests).
    var fixedSignIn: GitLabSignIn?
    @State private var ciLogin = ""
    @State private var signIn = GitLabSignIn()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PropertySection("GitLab", footer: signInFooter) {
                PropertyRow("Project", value: project.ciProject.map { "\($0.host)/\($0.projectPath)" } ?? "None: origin isn’t on GitLab",
                            code: project.ciProject != nil)
                PropertyRow("Sign-in", value: signInValue)
            }
            PropertySection("Runners", footer: "The SSH login on the runners, to copy the images a failed job’s tests took. Empty: "
                                + "ssh’s default, or `~/.ssh/config`. `ssh <login>@<runner> true` must work without a password.") {
                PropertyRow("CI login", alignment: .center) {
                    TextField("", text: $ciLogin)
                        .textFieldStyle(.plain)
                        // A hint, not a value: a name here read as one already set.
                        .placeholder("user, or user@host", shown: ciLogin.isEmpty)
                        .fieldChrome()
                        .accessibilityLabel("CI login")
                        .focused($focused)
                        .onSubmit(save)
                }
                // A loaded job found the login to use: the runner refused this one, or it can't read the images.
                if let suggestion = project.suggestedCILogin {
                    PropertyRow("") {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            StatusNote(loginNote(suggestion.login, job: suggestion.job), symbol: "exclamationmark.triangle.fill", color: DS.Status.flaky)
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Log In as \(suggestion.login)") {
                                ciLogin = suggestion.login
                                project.useCILogin(suggestion.login, reloading: suggestion.job)
                            }
                            .quietControl()
                            .help("Set the CI login to \(suggestion.login), then load \(suggestion.job.name) #\(suggestion.job.id) again")
                        }
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .frame(width: 420, alignment: .leading)
        .controlSize(.small)
        .onAppear {
            ciLogin = project.settings.ciLogin ?? ""
            signIn = fixedSignIn ?? GitLabSignIn.current()
        }
        // Saved like any Mac field: on Return, and also when you click or tab away or close the panel.
        .onChange(of: focused) { save() }
        .onDisappear(perform: save)
    }

    /// glab is tried first, then the token.
    private var signInValue: String {
        switch (signIn.glab, signIn.tokenVariable) {
        case (.some, .some(let variable)): "glab, else \(variable)"
        case (.some, nil): "glab"
        case (nil, .some(let variable)): variable
        case (nil, nil): "None"
        }
    }

    private var signInFooter: String {
        let host = project.ciProject?.host ?? "gitlab.example.com"
        if signIn.glab == nil, signIn.tokenVariable == nil {
            return "Install glab (`brew install glab`) and sign in with `glab auth login --hostname \(host)`, or set GITLAB_TOKEN "
                + "to a token with read_api where SnapshotKit starts: an app opened from the Dock doesn’t see your shell’s variables."
        }
        // The command on a line of its own: wrapped, it broke at its `--`.
        return signIn.glab.map { "glab at `\($0)`. To sign in:\n`glab auth login --hostname \(host)`" }
            ?? "The token is read from the environment, and never stored or logged."
    }

    /// Why a loaded CI job suggests another login.
    private func loginNote(_ login: String, job: GitLabJob) -> String {
        let owner = login.split(separator: "@").first.map(String.init) ?? login
        let current = ciLogin.isEmpty ? "with ssh’s default login" : "as `\(ciLogin)`"
        return "\(job.name) #\(job.id) couldn’t copy its images \(current): they are `\(owner)`’s."
    }

    private func save() {
        if (ciLogin.isEmpty ? nil : ciLogin) != project.settings.ciLogin { project.setCILogin(ciLogin) }
    }
}
