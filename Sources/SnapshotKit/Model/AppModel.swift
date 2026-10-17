import AppKit
import Combine
import Foundation
import SnapshotKitCore

@MainActor
final class AppModel: ObservableObject {
    let store: ProjectStore
    @Published private(set) var projects: [Project] = []
    @Published var selectedPath: String? {
        didSet { if oldValue != selectedPath { openSelected() } }
    }
    @Published private(set) var current: ProjectModel? {
        didSet { menuState.follow(current) }
    }
    /// What the menu bar observes: the current project's changes, throttled.
    let menuState = MenuState()
    @Published var showQuickSwitcher = false
    @Published private(set) var isScanning = false
    @Published private(set) var startupNotice: String?
    /// Shared zoom/pan state for whichever compare view is visible (driven by ⌘= / ⌘− / ⌘0).
    @Published var viewport = Viewport()
    /// Bumped by View ▸ Zoom to Change; the visible compare view frames the changed pixels.
    @Published var zoomToChangeRequest = 0
    /// Failing test count per project path, from each repository's last run.
    @Published var failingCounts: [String: Int] = [:]

    private var models: [String: ProjectModel] = [:]

    /// Whether the menu bar item is shown (its own object; see `MenuBarSetting`).
    let menuBar: MenuBarSetting
    var showMenuBarItem: Bool {
        get { menuBar.isShown }
        set { menuBar.isShown = newValue }
    }
    /// Projects with a run, record or flakiness check going on, for the menu bar.
    @Published private(set) var runningPaths: [String] = []
    static let runStarted = Notification.Name("SnapshotKitRunStarted")
    private var runObservers: [NSObjectProtocol] = []

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        menuBar = MenuBarSetting(store: store)
        for name in [Self.runStarted, Self.runFinished] {
            runObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunningPaths() }
            })
        }
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
        let home = NSHomeDirectory()
        func name(_ url: URL) -> String { url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path }
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

/// Relays the current project's changes to the menu bar, at most five times a second, so menu
/// items (Cancel while running, Re-record Selected Test) are enabled when they should be
/// without redrawing the menus on every line of test output.
@MainActor
final class MenuState: ObservableObject {
    private var subscription: AnyCancellable?

    func follow(_ project: ProjectModel?) {
        subscription = project?.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
    }
}

/// The menu bar item setting, which the menu bar scene binds to.
@MainActor
final class MenuBarSetting: ObservableObject {
    private let store: ProjectStore
    @Published var isShown: Bool {
        didSet { if isShown != store.settings.showMenuBarItem { store.update { $0.showMenuBarItem = isShown } } }
    }

    init(store: ProjectStore) {
        self.store = store
        isShown = store.settings.showMenuBarItem
    }
}
