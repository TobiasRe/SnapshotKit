import AppKit
import SnapshotKitCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [String] = []
    @State private var iterations = 5
    @State private var verify = true

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: Bindable(model.menuBar).isShown)
            } header: {
                Text("General")
            } footer: {
                FormFooter("Run progress and quick access to recent projects. SnapshotKit keeps running when its window is closed.")
            }

            Section {
                if roots.isEmpty {
                    Text("No folders yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(roots, id: \.self) { root in
                    LabeledContent {
                        Button { model.store.removeScanRoot(root); reload() } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop scanning this folder")
                        .accessibilityLabel("Remove \(root.abbreviatingWithTildeInPath)")
                    } label: {
                        Label(root.abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root)
                    }
                }
            } header: {
                HStack {
                    Text("Scan Folders")
                    Spacer()
                    Button("Rescan") { model.rescan() }
                        .disabled(roots.isEmpty)
                    Button("Add Folder…") {
                        model.addScanRootFromPanel()
                        reload()
                    }
                }
                .controlSize(.small)
            } footer: {
                FormFooter("Git repositories with snapshot tests in these folders appear in the sidebar.")
            }

            Section("Testing") {
                LabeledContent("Flakiness check runs") {
                    HStack(spacing: DS.Space.s) {
                        Text("\(iterations)").monospacedDigit()
                        Stepper("Flakiness check runs", value: $iterations, in: 2...50).labelsHidden()
                    }
                }
                .onChange(of: iterations) { _, v in model.store.update { $0.flakeIterations = v } }
                Toggle("Verify after re-recording", isOn: $verify)
                    .onChange(of: verify) { _, v in model.store.update { $0.verifyAfterRecord = v } }
            }

            Section {
                LabeledContent("Settings file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                        .help(model.store.url.path)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .onAppear(perform: reload)
    }

    private func reload() {
        roots = model.store.settings.scanRoots
        iterations = model.store.settings.flakeIterations
        verify = model.store.settings.verifyAfterRecord
    }
}

extension String {
    /// A path as people say it: the home folder as "~".
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
