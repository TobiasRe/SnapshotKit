import AppKit
import Foundation
import Observation
import SnapshotKitCore

@MainActor @Observable
final class AppModel {
    let store: ProjectStore
    private(set) var projects: [Project] = []
    var selectedPath: String? {
        didSet { if oldValue != selectedPath { openSelected() } }
    }
    private(set) var current: ProjectModel?
    var showQuickSwitcher = false
    private(set) var isScanning = false
    private(set) var startupNotice: String?
    /// Shared zoom/pan state for whichever compare view is visible (driven by ⌘= / ⌘− / ⌘0).
    var viewport = Viewport()
    /// Bumped by View ▸ Zoom to Change; the visible compare view frames the changed pixels.
    var zoomToChangeRequest = 0
    /// Failing test count per project path, from each repository's last run.
    var failingCounts: [String: Int] = [:]

    @ObservationIgnored private var models: [String: ProjectModel] = [:]

    /// Whether the menu bar item is shown (its own object; see `MenuBarSetting`).
    let menuBar: MenuBarSetting
    /// Projects with a run, record or flakiness check going on, for the menu bar.
    private(set) var runningPaths: [String] = []
    /// Posted by a project model when an operation starts and when it ends.
    static let runStarted = Notification.Name("SnapshotKitRunStarted")
    static let runFinished = Notification.Name("SnapshotKitRunFinished")
    @ObservationIgnored private var runObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isRefreshingCounts = false

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        menuBar = MenuBarSetting(store: store)
        let center = NotificationCenter.default
        runObservers = [
            center.addObserver(forName: Self.runStarted, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunningPaths() }
            },
            center.addObserver(forName: Self.runFinished, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateRunningPaths()
                    self?.refreshFailingCounts()
                }
            },
        ]
        restoreLeftoverPatches()
        refreshProjects()
        // Opens it: an @Observable property's didSet runs in init too, unlike a stored property's.
        if let last = store.settings.lastProject, projects.contains(where: { $0.path == last }) {
            selectedPath = last
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

    /// Reads every project's last-run summary in the background (cheap: one small JSON per repo).
    func refreshFailingCounts() {
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

    /// Adds dropped folders: a repository (or a folder inside one) opens as a project; any other
    /// folder becomes a scan folder, so dropping ~/Developer finds the projects in it.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        var repositories: [URL] = [], folders: [URL] = []
        for url in urls {
            if let root = Git.repository(containing: url)?.root { repositories.append(root) }
            else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { folders.append(url) }
        }
        guard !repositories.isEmpty || !folders.isEmpty else { return false }
        for root in repositories { store.markOpened(Project(path: root.path)) }
        if let last = repositories.last { open(path: last.path) }
        if !folders.isEmpty {
            for folder in folders { store.addScanRoot(folder.path) }
            rescan()
        }
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
        // Let its model (and the model's file watcher) go, unless it is still running something.
        if models[project.path]?.isRunning == false { models[project.path] = nil }
        refreshProjects()
    }

    /// The loaded model of a project, if it has been opened this session.
    func projectModel(path: String) -> ProjectModel? { models[path] }

    func updateRunningPaths() {
        let running = models.values.filter(\.isRunning).map(\.project.path).sorted()
        if running != runningPaths { runningPaths = running }
    }

    /// Runs a project's snapshot tests from outside its window (the menu bar), opening it first.
    func runTests(path: String) {
        open(path: path)
        guard let model = models[Project(path: path).path] else { return }
        // A project opened just now is still checking Xcode and the simulator.
        Task {
            for _ in 0..<300 where model.environment == nil && model.environmentError == nil && model.configError == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.runTests()
        }
    }

    func open(path: String) {
        let project = Project(path: path)
        store.markOpened(project)
        refreshProjects()
        selectedPath = project.path
    }

    /// Opens the repository (adding it if it's new) and selects the snapshot at `path` in its library
    /// once the library has loaded.
    func reveal(snapshot path: String, in repository: URL) {
        open(path: repository.path)
        guard let model = models[Project(path: repository.path).path] else { return }
        Task {
            for _ in 0..<100 where !model.isInLibrary(path) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.showInLibrary(path: path)
        }
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

    /// Scans every scan folder and says what came of it, so an empty result is never silent.
    func rescan() {
        isScanning = true
        let store = store
        Task {
            let reports = await Task.detached { store.rescanReports() }.value
            isScanning = false
            refreshProjects()
            startupNotice = Self.scanSummary(reports)
        }
    }

    /// "Found 3 projects with snapshot tests in ~/Developer." or why there are none.
    nonisolated static func scanSummary(_ reports: [ProjectScanner.Report]) -> String? {
        guard !reports.isEmpty else { return nil }
        func name(_ url: URL) -> String { url.path.abbreviatingWithTildeInPath }
        let unreadable = reports.filter { !$0.readable }
        if !unreadable.isEmpty {
            return "SnapshotKit can't read \(unreadable.map { name($0.root) }.joined(separator: ", ")). "
                + "Allow it in System Settings › Privacy & Security › Files and Folders, then rescan."
        }
        let count = reports.reduce(0) { $0 + $1.projects.count }
        let folders = reports.map { name($0.root) }.joined(separator: ", ")
        if count == 0 {
            return "No git repositories with snapshot tests in \(folders) (looked \(ProjectScanner.defaultDepth) folders deep). "
                + "A repository counts when it has __Snapshots__ images, a .snapshotkit.yml or depends on swift-snapshot-testing."
        }
        return "Found \(count) project\(count == 1 ? "" : "s") with snapshot tests in \(folders)."
    }

    /// Asks for a folder in an open panel; nil when cancelled.
    private func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func addProjectFromPanel() {
        guard let url = chooseFolder(message: "Choose a git repository with snapshot tests"),
              let root = Git.repository(containing: url)?.root else { return }
        open(path: root.path)
    }

    /// Asks for a folder to scan, then scans it.
    func addScanRootFromPanel() {
        guard let url = chooseFolder(message: "Choose a folder to scan for repositories with snapshot tests") else { return }
        addScanRoot(url)
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

/// The menu bar item setting, which the menu bar scene binds to.
@MainActor @Observable
final class MenuBarSetting {
    private let store: ProjectStore
    var isShown: Bool {
        didSet { if isShown != store.settings.showMenuBarItem { store.update { $0.showMenuBarItem = isShown } } }
    }

    init(store: ProjectStore) {
        self.store = store
        isShown = store.settings.showMenuBarItem
    }
}
