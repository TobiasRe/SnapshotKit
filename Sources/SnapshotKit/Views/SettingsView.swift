import SnapshotKitCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var roots: [String] = []
    @State private var iterations = 5
    @State private var verify = true

    var body: some View {
        Form {
            Section("Scan folders") {
                List {
                    ForEach(roots, id: \.self) { root in
                        HStack {
                            Text(root).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.store.removeScanRoot(root); reload() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 80)
                HStack {
                    Button("Add Folder…") {
                        model.chooseFolder(message: "Choose a folder to scan for repositories with snapshot tests") {
                            model.addScanRoot($0)
                            reload()
                        }
                    }
                    Button("Rescan") { model.rescan() }
                }
            }
            Section("Testing") {
                Stepper("Flakiness check runs: \(iterations)", value: $iterations, in: 2...50)
                    .onChange(of: iterations) { _, v in model.store.update { $0.flakeIterations = v } }
                Toggle("Verify after re-recording", isOn: $verify)
                    .onChange(of: verify) { _, v in model.store.update { $0.verifyAfterRecord = v } }
            }
            Section {
                Text("Settings are stored in \(model.store.url.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .onAppear(perform: reload)
    }

    private func reload() {
        roots = model.store.settings.scanRoots
        iterations = model.store.settings.flakeIterations
        verify = model.store.settings.verifyAfterRecord
    }
}
