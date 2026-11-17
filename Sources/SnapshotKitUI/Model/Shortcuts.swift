import SnapshotKitCore
import SwiftUI

/// A key that works without a modifier wherever a list or an image has the keyboard, never in a
/// text field: stepping through a review and picking a compare mode take one key each, as V marks a
/// change viewed. The shortcuts with ⌘ and ⌥ do the same from anywhere.
enum SingleKey: Equatable {
    /// J and K: the next and the previous item of the section's list, as ⌥⌘↓ and ⌥⌘↑.
    case next, previous
    /// 1–4: the compare mode, as ⌘1–⌘4.
    case compare(CompareMode)
    /// V: the selected change's Viewed mark, as ⌥⌘V. The changes list has its own V; this one is the image's.
    case viewed
    /// ?: the list of shortcuts.
    case shortcuts

    /// The keys a list takes (its V is the changes list's own).
    static let listCharacters = CharacterSet(charactersIn: "jk1234?")
    /// The keys an image takes.
    static let imageCharacters = CharacterSet(charactersIn: "jk1234v?")

    /// The key that types `characters`; nil for any other.
    init?(_ characters: String) {
        switch characters {
        case "j": self = .next
        case "k": self = .previous
        case "1": self = .compare(.sideBySide)
        case "2": self = .compare(.slider)
        case "3": self = .compare(.difference)
        case "4": self = .compare(.toggle)
        case "v": self = .viewed
        case "?": self = .shortcuts
        default: return nil
        }
    }

    /// Whether holding the key down repeats it: stepping does, a toggle would flicker.
    var repeats: Bool { self == .next || self == .previous }
}

extension AppModel {
    /// Does what `key` stands for in the open project; false when it has nothing to do there, so the key
    /// goes on to whoever else wants it. `setCompareMode` stores the mode where the view keeps it.
    func press(_ key: SingleKey, setCompareMode: (CompareMode) -> Void) -> Bool {
        switch key {
        case .shortcuts:
            showsShortcuts.toggle()
            return true
        case .next, .previous:
            guard let project = current, project.section.content != .run else { return false }
            project.selectAdjacent(key == .next ? 1 : -1)
            return true
        case .compare(let mode):
            guard current != nil else { return false }
            setCompareMode(mode)
            return true
        case .viewed:
            guard let project = current, project.section.content == .changes, let change = project.selectedChange else { return false }
            project.setViewed(!project.viewedChanges.contains(change.id), for: change)
            return true
        }
    }
}

/// The single keys on a list: J K step, 1–4 pick the compare mode, ? lists the shortcuts.
struct SingleKeys: ViewModifier {
    @Environment(AppModel.self) private var app
    @AppStorage("compareMode") private var compareMode = CompareMode.sideBySide.rawValue

    func body(content: Content) -> some View {
        content.onKeyPress(characters: SingleKey.listCharacters) { press in
            // With ⌘, ⌥ or ⌃ it is a shortcut of its own (⌘1), not this key.
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]), let key = SingleKey(press.characters) else { return .ignored }
            if press.phase == .repeat, !key.repeats { return .handled }
            return app.press(key) { compareMode = $0.rawValue } ? .handled : .ignored
        }
    }
}

extension View {
    /// Gives a list the single keys (see `SingleKey`).
    func singleKeys() -> some View { modifier(SingleKeys()) }
}

/// One line of the shortcut list: the keys as the documentation writes them, and what they do.
struct ShortcutEntry: Identifiable, Equatable {
    var keys: String
    var action: String
    var id: String { keys + " " + action }
}

struct ShortcutGroup: Identifiable {
    var title: String
    var entries: [ShortcutEntry]
    var id: String { title }
}

/// The shortcuts the ? panel lists: the ones worth knowing by heart, grouped by what you are doing.
/// docs/keyboard-shortcuts.md has them all; a test keeps every line here in it.
enum ShortcutCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Reviewing", entries: [
            ShortcutEntry(keys: "J / K", action: "Next / previous snapshot, change or failure"),
            ShortcutEntry(keys: "V", action: "Mark the change viewed, and go to the next"),
            ShortcutEntry(keys: "1 – 4", action: "Side by side, slider, difference, toggle"),
            ShortcutEntry(keys: "Space", action: "Quick Look; in Toggle mode, flip the images"),
            ShortcutEntry(keys: "← / →", action: "Move the slider divider"),
            ShortcutEntry(keys: "⌘C", action: "Copy the selected image"),
        ]),
        ShortcutGroup(title: "Zoom", entries: [
            ShortcutEntry(keys: "⌘= / ⌘−", action: "Zoom in / out"),
            ShortcutEntry(keys: "⌘0", action: "Zoom to fit"),
            ShortcutEntry(keys: "⇧⌘0", action: "Zoom to the changed pixels"),
            ShortcutEntry(keys: "Arrow keys", action: "Look around a zoomed-in image"),
        ]),
        ShortcutGroup(title: "Running and recording", entries: [
            ShortcutEntry(keys: "⌘R", action: "Run the snapshot tests"),
            ShortcutEntry(keys: "⇧⌘R", action: "Re-record the selected test"),
            ShortcutEntry(keys: "⌥⇧⌘R", action: "Re-record the failing suites"),
            ShortcutEntry(keys: "⌥⌘R", action: "Check flakiness of the failing tests"),
            ShortcutEntry(keys: "⌃⌘R", action: "Run on the remote machine"),
            ShortcutEntry(keys: "⌘.", action: "Cancel the run"),
        ]),
        ShortcutGroup(title: "Getting around", entries: [
            ShortcutEntry(keys: "⌘K", action: "Go to a project or run a command"),
            ShortcutEntry(keys: "⌥⌘1 – ⌥⌘6", action: "The sidebar’s sections"),
            ShortcutEntry(keys: "⌘F", action: "Filter the list"),
            ShortcutEntry(keys: "⌥⌘O", action: "Open the test in Xcode"),
            ShortcutEntry(keys: "⇧⌘O", action: "Import a result bundle"),
            ShortcutEntry(keys: "⇧⌘L", action: "Load a CI job or pipeline"),
            ShortcutEntry(keys: "?", action: "Show or hide this list"),
        ]),
    ]
}

/// The shortcuts, over the window: ? (with a list or an image in focus), ⌘/ or Help › Keyboard Shortcuts
/// shows it, and the same keys, Escape or a click beside it close it.
struct KeyboardShortcutsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let groups = ShortcutCatalog.groups
        let half = (groups.count + 1) / 2
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(DS.Font.heading)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { close() }
                        .keyboardShortcut(.cancelAction)
                        .quietControl()
                        .controlSize(.small)
                }
                .padding(.horizontal, DS.Space.l)
                .frame(height: DS.Bar.header)
                Divider()
                ScrollView {
                    HStack(alignment: .top, spacing: DS.Space.xl) {
                        column(Array(groups.prefix(half)))
                        column(Array(groups.dropFirst(half)))
                    }
                    .padding(DS.Space.l)
                }
            }
            .frame(width: 680)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            // Takes the keyboard while it is up, so ? and Escape close it and J doesn't step behind it.
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(characters: CharacterSet(charactersIn: "?")) { _ in close(); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .accessibilityAddTraits(.isModal)
            // Floats over content, so it's glass (see docs/design.md).
            .floatingGlass(in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .padding(DS.Space.xl)
        }
        .onAppear { focused = true }
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(group.title)
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                            Text(entry.action)
                                .font(DS.Font.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: DS.Space.s)
                            Text(entry.keys)
                                .font(DS.Font.secondary.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        // One stop each: "Run the snapshot tests, ⌘R".
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func close() {
        model.showsShortcuts = false
    }
}
