import AppKit
import Foundation
import SnapshotKitCore

@MainActor
final class AppModel: ObservableObject {
    let store: ProjectStore
    @Published private(set) var projects: [Project] = []
    @Published var selectedPath: String? {
        didSet { if oldValue != selectedPath { openSelected() } }
    }
    @Published private(set) var current: ProjectModel?
    @Published var showQuickSwitcher = false
    @Published var showProjectSettings = false
    @Published private(set) var isScanning = false
    @Published private(set) var startupNotice: String?
    /// Shared zoom/pan state for whichever compare view is visible (driven by ⌘= / ⌘− / ⌘0).
    @Published var viewport = Viewport()
    /// Bumped by View ▸ Zoom to Change; the visible compare view frames the changed pixels.
    @Published var zoomToChangeRequest = 0
    /// Failing test count per project path, from each repository's last run.
    @Published var failingCounts: [String: Int] = [:]

    private var models: [String: ProjectModel] = [:]

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        restoreLeftoverPatches()
        refreshProjects()
        if let last = store.settings.lastProject, projects.contains(where: { $0.path == last }) {
            selectedPath = last
            openSelected()
        }
    }

    /// A record patch can survive a crash or force quit; undo it before anything else.
    private func restoreLeftoverPatches() {
        let reports = RecordSession.restoreAllLeftovers().filter { !$0.files.isEmpty }
        guard !reports.isEmpty else { return }
        startupNotice = "Restored a record patch left by an interrupted run:\n" + reports.map(\.summary).joined(separator: "\n")
    }

    func dismissStartupNotice() { startupNotice = nil }

    func refreshProjects() {
        projects = store.allProjects
        refreshFailingCounts()
    }

    static let runFinished = Notification.Name("SnapshotKitRunFinished")
    private var isRefreshingCounts = false
    private var runObserver: NSObjectProtocol?

    /// Reads every project's last-run summary in the background (cheap: one small JSON per repo).
    func refreshFailingCounts() {
        if runObserver == nil {
            runObserver = NotificationCenter.default.addObserver(forName: Self.runFinished, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFailingCounts() }
            }
        }
        guard !isRefreshingCounts else { return }
        isRefreshingCounts = true
        let paths = projects.map(\.path)
        Task {
            defer { isRefreshingCounts = false }
            let counts = await Task.detached { () -> [String: Int] in
                var counts: [String: Int] = [:]
                for path in paths where FileManager.default.fileExists(atPath: path + "/.git") {
                    if let last = LastRun.load(repository: URL(fileURLWithPath: path)), last.failed > 0 { counts[path] = last.failed }
                }
                return counts
            }.value
            if !DS.solidSurfaces { failingCounts = counts }
        }
    }

    /// Adds dropped folders that are (inside) git repositories; returns whether any was added.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        let roots = urls.compactMap { Git.repository(containing: $0)?.root }
        guard let last = roots.last else { return false }
        for root in roots { store.markOpened(Project(path: root.path)) }
        open(path: last.path)
        return true
    }

    func isPinned(_ project: Project) -> Bool { store.isPinned(project) }

    func togglePin(_ project: Project) {
        store.togglePin(project)
        refreshProjects()
    }

    func remove(_ project: Project) {
        store.remove(project)
        if selectedPath == project.path { selectedPath = nil }
        refreshProjects()
    }

    func open(path: String) {
        let project = Project(path: path)
        store.markOpened(project)
        refreshProjects()
        selectedPath = project.path
    }

    private func openSelected() {
        guard let path = selectedPath else {
            current = nil
            return
        }
        let project = Project(path: path)
        store.markOpened(project)
        if let existing = models[path] {
            current = existing
        } else {
            let model = ProjectModel(project: project, store: store)
            models[path] = model
            current = model
        }
        viewport.reset()
        refreshProjects()
    }

    func addScanRoot(_ url: URL) {
        store.addScanRoot(url.path)
        rescan()
    }

    func rescan() {
        isScanning = true
        let store = store
        Task {
            _ = await Task.detached { store.rescan() }.value
            isScanning = false
            refreshProjects()
        }
    }

    func chooseFolder(message: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    func addProjectFromPanel() {
        chooseFolder(message: "Choose a git repository with snapshot tests") { [weak self] url in
            guard let root = Git.repository(containing: url)?.root else { return }
            self?.open(path: root.path)
        }
    }

    func importResultBundleFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an .xcresult bundle (for example a CI artifact)"
        if panel.runModal() == .OK, let url = panel.url { current?.importResultBundle(url) }
    }

    /// Shows a prepared project model (snapshot tests and previews).
    func show(_ model: ProjectModel) {
        models[model.project.path] = model
        selectedPath = model.project.path
        current = model
    }

    /// Called on quit: undo any active record patch.
    func applicationWillTerminate() {
        _ = InterruptGuard.restoreAll()
    }
}
