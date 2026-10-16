#!/usr/bin/env bash
# Generates sample projects with many snapshot tests, for trying SnapshotKit, demos and screenshots.
#
# Usage: scripts/make-samples.sh [DEST]      (default: ../snapshotkit-samples next to this repository)
#
# Five Swift packages (iOS 17) using swift-snapshot-testing, each a git repository:
#   Shop        product cards, prices, cart and checkout, in light and dark, plus phone screens
#   Weather     conditions, forecast rows, alerts
#   Chat        bubbles, conversation rows, avatars, composer
#   Fitness     activity rings, stat tiles, workouts, weekly bars
#   DesignKit   buttons, badges, tags, banners, cards (left clean on develop)
# References are recorded on `develop` with a real simulator. The first four then get a branch with
# a committed brand-colour change, an uncommitted re-record, a view changed without re-recording (so
# the last run has failures), an orphaned snapshot (Shop) and a new untracked one (Chat).
#
# Requires: Xcode with an iOS simulator runtime, git, network access for swift-snapshot-testing.
# Takes a while: every package builds and runs its tests several times.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/../snapshotkit-samples}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "Build snapkit"
(cd "$ROOT" && swift build --product snapkit 2>&1 | tail -1)
SNAPKIT="$(cd "$ROOT" && swift build --product snapkit --show-bin-path)/snapkit"

step "Use a dedicated simulator, so runs here never disturb one you are using"
XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"
SIM_NAME="SnapshotKit Samples"
read -r CI_DEVICE SIM_OS RUNTIME < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime: continue
    os = runtime.split(".iOS-")[1].replace("-", ".")
    for d in devices:
        if d["name"].startswith("iPhone") and d.get("isAvailable", True):
            key = tuple(int(x) for x in os.split("."))
            if best is None or key > best[0]: best = (key, d["deviceTypeIdentifier"], os, runtime)
if not best: sys.exit("no iPhone simulator available")
print(best[1], best[2], best[3])
')
SIM_ID="$(xcrun simctl list devices available -j | python3 -c "import json,sys; print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='$SIM_NAME'), ''))")"
[ -n "$SIM_ID" ] || SIM_ID="$(xcrun simctl create "$SIM_NAME" "$CI_DEVICE" "$RUNTIME")"
# The CI file names the phone CI uses; .snapshotkit.yml points local runs at the dedicated simulator.
CI_NAME="$(xcrun simctl list devicetypes -j | python3 -c "import json,sys; print(next(t['name'] for t in json.load(sys.stdin)['devicetypes'] if t['identifier']=='$CI_DEVICE'))")"
echo "Xcode $XCODE_VERSION · $SIM_NAME ($CI_NAME) · iOS $SIM_OS"

# xcodebuild test for the package in the current directory. RECORD=all re-records every snapshot.
run_tests() {
  local name="$1" record="${2:-}"
  local env=()
  [ -n "$record" ] && env=(TEST_RUNNER_SNAPSHOT_TESTING_RECORD="$record")
  env ${env[@]+"${env[@]}"} xcodebuild test -scheme "$name" -destination "platform=iOS Simulator,id=$SIM_ID" \
    -derivedDataPath "$DEST/.derived/$name" -quiet >/dev/null 2>&1 || true
}

commit() { git add -A && git commit -qm "$1"; }

# Package.swift, CI workflow, .gitignore and the shared test helper for package $1.
scaffold() {
  local name="$1" dir="$DEST/$1"
  rm -rf "$dir"
  mkdir -p "$dir/Sources/$name" "$dir/Tests/${name}Tests" "$dir/.github/workflows"
  cat > "$dir/Package.swift" <<EOF
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "$name",
    platforms: [.iOS(.v17)],
    products: [.library(name: "$name", targets: ["$name"])],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "$name"),
        .testTarget(
            name: "${name}Tests",
            dependencies: ["$name", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
EOF
  cat > "$dir/.github/workflows/snapshots.yml" <<EOF
name: Snapshot tests
on:
  pull_request:
    branches: [develop]
env:
  XCODE_VERSION: "$XCODE_VERSION"
  DESTINATION: "platform=iOS Simulator,name=$CI_NAME,OS=$SIM_OS"
jobs:
  snapshots:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo xcode-select -s "/Applications/Xcode_\${{ env.XCODE_VERSION }}.app"
      - name: Snapshot tests
        run: xcodebuild test -scheme $name -destination "\${{ env.DESTINATION }}"
EOF
  printf '.build/\n.swiftpm/\n*.xcresult\n' > "$dir/.gitignore"
  printf 'device: %s\nos: "%s"\n' "$SIM_NAME" "$SIM_OS" > "$dir/.snapshotkit.yml"
  cat > "$dir/Tests/${name}Tests/Snapshot.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import UIKit

/// Snapshots a view in light and dark ("<name>-light", "<name>-dark").
@MainActor
func snap<V: View>(_ view: V, width: CGFloat = 340, height: CGFloat? = nil, named name: String? = nil,
                   fileID: StaticString = #fileID, file: StaticString = #filePath,
                   testName: String = #function, line: UInt = #line, column: UInt = #column) {
    for style in [UIUserInterfaceStyle.light, .dark] {
        let layout: SwiftUISnapshotLayout = height.map { .fixed(width: width, height: $0) } ?? .fixed(width: width, height: 120)
        let label = style == .dark ? "dark" : "light"
        assertSnapshot(of: view.padding().background(Color(uiColor: .systemBackground)),
                       as: .image(layout: layout, traits: UITraitCollection(userInterfaceStyle: style)),
                       named: [name, label].compactMap { $0 }.joined(separator: "-"),
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
    }
}

/// Snapshots a whole screen on a small and a large phone.
@MainActor
func snapScreen<V: View>(_ view: V, fileID: StaticString = #fileID, file: StaticString = #filePath,
                         testName: String = #function, line: UInt = #line, column: UInt = #column) {
    for (config, name) in [(ViewImageConfig.iPhoneSe, "iPhoneSE"), (.iPhone13ProMax, "iPhone13ProMax")] {
        assertSnapshot(of: view, as: .image(layout: .device(config: config)), named: name,
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
    }
}
EOF
  (cd "$dir" && git init -q -b develop && git config user.email sample@example.com && git config user.name "Sample" \
    && git config commit.gpgsign false)
}

# Splits Tests/<name>Tests/<name>Tests.swift into one file per suite, as real projects have them:
# swift-snapshot-testing names the __Snapshots__ folder after the test file.
split_suites() {
  python3 - "$DEST/$1/Tests/$1Tests/$1Tests.swift" <<'PY'
import re, sys, os
path = sys.argv[1]
text = open(path).read()
header, _, rest = text.partition("@MainActor\n@Suite")
blocks = ["@MainActor\n@Suite" + b for b in rest.split("@MainActor\n@Suite") if b.strip()]
for block in blocks:
    name = re.search(r"struct (\w+)", block).group(1)
    open(os.path.join(os.path.dirname(path), name + ".swift"), "w").write(header + block.rstrip() + "\n")
os.remove(path)
PY
}

# Records references on develop: the first run writes the missing ones (and fails), the second checks them.
record_develop() {
  local name="$1"
  split_suites "$name"
  step "$name: record the references on develop"
  (cd "$DEST/$name" && commit "Add $name views and snapshot tests" && run_tests "$name" && run_tests "$name" \
    && commit "Record $name snapshots")
  echo "$(cd "$DEST/$name" && git ls-files | grep -c '__Snapshots__') snapshots"
}

# A branch with a committed brand change, an uncommitted re-record and a failing run.
make_branch() {
  local name="$1" branch="$2" brand="$3" tweak_file="$4" tweak_from="$5" tweak_to="$6" break_file="$7" break_from="$8" break_to="$9"
  step "$name: $branch"
  (
    cd "$DEST/$name"
    git checkout -qb "$branch"
    sed -i '' "s/static let brand = .*/static let brand = $brand/" "Sources/$name/Theme.swift"
    run_tests "$name" all
    commit "New brand colour"
    # Uncommitted: a tweak re-recorded but not committed yet.
    sed -i '' "s/$tweak_from/$tweak_to/" "Sources/$name/$tweak_file"
    run_tests "$name" all
    git add "Sources/$name/$tweak_file" && git commit -qm "Tweak $tweak_file"
    # Failing: a view changed without re-recording, then run like CI so the app has a last run.
    sed -i '' "s/$break_from/$break_to/" "Sources/$name/$break_file"
    "$SNAPKIT" run >/dev/null 2>&1 || true
    git add "Sources/$name/$break_file" && git commit -qm "Change $break_file"
  )
}

# ---------------------------------------------------------------------------------------------
step "Shop"
scaffold Shop
cat > "$DEST/Shop/Sources/Shop/Theme.swift" <<'EOF'
import SwiftUI

public enum Theme {
    static let brand = Color(red: 0.20, green: 0.40, blue: 0.95)
    static let sale = Color(red: 0.90, green: 0.25, blue: 0.30)
}
EOF
cat > "$DEST/Shop/Sources/Shop/Views.swift" <<'EOF'
import SwiftUI

public struct Product: Identifiable {
    public var id: String { name }
    public var name: String, price: Double, oldPrice: Double?, rating: Int, symbol: String
    public init(name: String, price: Double, oldPrice: Double? = nil, rating: Int, symbol: String) {
        self.name = name; self.price = price; self.oldPrice = oldPrice; self.rating = rating; self.symbol = symbol
    }
    public static let samples = [
        Product(name: "Trail Shoes", price: 129, oldPrice: 159, rating: 4, symbol: "shoe.fill"),
        Product(name: "Rain Jacket", price: 89, rating: 5, symbol: "cloud.rain.fill"),
        Product(name: "Daypack", price: 64, rating: 3, symbol: "backpack.fill"),
        Product(name: "Water Bottle", price: 19, oldPrice: 24, rating: 4, symbol: "waterbottle.fill"),
    ]
}

public struct PriceTag: View {
    var price: Double, oldPrice: Double?
    public init(price: Double, oldPrice: Double? = nil) { self.price = price; self.oldPrice = oldPrice }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(price, format: .currency(code: "EUR")).font(.headline).foregroundStyle(oldPrice == nil ? Color.primary : Theme.sale)
            if let oldPrice { Text(oldPrice, format: .currency(code: "EUR")).font(.subheadline).strikethrough().foregroundStyle(.secondary) }
        }
    }
}

public struct RatingStars: View {
    var rating: Int
    public init(rating: Int) { self.rating = rating }
    public var body: some View {
        HStack(spacing: 2) { ForEach(1...5, id: \.self) { Image(systemName: $0 <= rating ? "star.fill" : "star").foregroundStyle(.orange) } }
            .font(.caption)
    }
}

public struct ProductCard: View {
    var product: Product
    public init(product: Product) { self.product = product }
    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: product.symbol).font(.title).foregroundStyle(Theme.brand)
                .frame(width: 64, height: 64).background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline)
                RatingStars(rating: product.rating)
                PriceTag(price: product.price, oldPrice: product.oldPrice)
            }
            Spacer()
            if product.oldPrice != nil {
                Text("SALE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.sale, in: Capsule()).foregroundStyle(.white)
            }
        }
    }
}

public struct CartRow: View {
    var product: Product, quantity: Int
    public init(product: Product, quantity: Int) { self.product = product; self.quantity = quantity }
    public var body: some View {
        HStack {
            Text(product.name)
            Spacer()
            Text("× \(quantity)").foregroundStyle(.secondary)
            PriceTag(price: product.price * Double(quantity))
        }
    }
}

public struct CheckoutButton: View {
    public enum State { case ready, loading, disabled }
    var state: State
    public init(state: State) { self.state = state }
    public var body: some View {
        HStack {
            if state == .loading { ProgressView().tint(.white) }
            Text(state == .loading ? "Placing order…" : "Checkout").bold()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(state == .disabled ? Color.gray.opacity(0.4) : Theme.brand, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

public struct OrderSummary: View {
    var items: [(Product, Int)]
    public init(items: [(Product, Int)]) { self.items = items }
    var total: Double { items.reduce(0) { $0 + $1.0.price * Double($1.1) } }
    public var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.0.id) { CartRow(product: $0.0, quantity: $0.1) }
            Divider()
            HStack { Text("Total").bold(); Spacer(); PriceTag(price: total) }
        }
    }
}

public struct ProductListScreen: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            List(Product.samples) { ProductCard(product: $0) }
                .navigationTitle("Outdoor")
        }
    }
}
EOF
cat > "$DEST/Shop/Tests/ShopTests/ShopTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import Shop

@MainActor
@Suite
struct ProductCardTests {
    @Test func trailShoes() { snap(ProductCard(product: Product.samples[0]), height: 110) }
    @Test func rainJacket() { snap(ProductCard(product: Product.samples[1]), height: 110) }
    @Test func daypack() { snap(ProductCard(product: Product.samples[2]), height: 110) }
    @Test func waterBottle() { snap(ProductCard(product: Product.samples[3]), height: 110) }
}

@MainActor
@Suite
struct PriceTagTests {
    @Test func regular() { snap(PriceTag(price: 89), width: 200, height: 60) }
    @Test func sale() { snap(PriceTag(price: 129, oldPrice: 159), width: 200, height: 60) }
    @Test func rating() { snap(RatingStars(rating: 3), width: 160, height: 50) }
}

@MainActor
@Suite
struct CheckoutTests {
    @Test func ready() { snap(CheckoutButton(state: .ready), height: 90) }
    @Test func loading() { snap(CheckoutButton(state: .loading), height: 90) }
    @Test func disabled() { snap(CheckoutButton(state: .disabled), height: 90) }
    @Test func summary() {
        snap(OrderSummary(items: [(Product.samples[0], 1), (Product.samples[3], 2)]), height: 160)
    }
    @Test func singleItem() { snap(CartRow(product: Product.samples[1], quantity: 1), height: 60) }
}

@MainActor
@Suite
struct ShopScreenTests {
    @Test func productList() { snapScreen(ProductListScreen()) }
}
EOF
record_develop Shop
make_branch Shop feature/brand-refresh "Color(red: 0.10, green: 0.60, blue: 0.45)" \
  Views.swift "cornerRadius: 12" "cornerRadius: 20" Views.swift 'Text("SALE")' 'Text("DEAL")'
# An orphaned snapshot: its test is renamed, so the old reference has no test any more.
(cd "$DEST/Shop" && sed -i '' 's/@Test func singleItem()/@Test func oneItem()/' Tests/ShopTests/CheckoutTests.swift \
  && git add Tests/ShopTests/CheckoutTests.swift && git commit -qm "Rename singleItem")

# ---------------------------------------------------------------------------------------------
step "Weather"
scaffold Weather
cat > "$DEST/Weather/Sources/Weather/Theme.swift" <<'EOF'
import SwiftUI

public enum Theme {
    static let brand = Color(red: 0.25, green: 0.55, blue: 0.95)
}
EOF
cat > "$DEST/Weather/Sources/Weather/Views.swift" <<'EOF'
import SwiftUI

public enum Condition: String, CaseIterable {
    case sunny, cloudy, rain, snow, storm
    var symbol: String {
        switch self {
        case .sunny: "sun.max.fill"
        case .cloudy: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .storm: "cloud.bolt.rain.fill"
        }
    }
    var tint: Color {
        switch self {
        case .sunny: .orange
        case .cloudy: .gray
        case .rain: Theme.brand
        case .snow: .cyan
        case .storm: .purple
        }
    }
}

public struct ConditionBadge: View {
    var condition: Condition
    public init(_ condition: Condition) { self.condition = condition }
    public var body: some View {
        Label(condition.rawValue.capitalized, systemImage: condition.symbol)
            .symbolRenderingMode(.multicolor).padding(.horizontal, 12).padding(.vertical, 8)
            .background(condition.tint.opacity(0.15), in: Capsule())
    }
}

public struct ForecastRow: View {
    var day: String, condition: Condition, low: Int, high: Int
    public init(day: String, condition: Condition, low: Int, high: Int) {
        self.day = day; self.condition = condition; self.low = low; self.high = high
    }
    public var body: some View {
        HStack {
            Text(day).frame(width: 52, alignment: .leading)
            Image(systemName: condition.symbol).symbolRenderingMode(.multicolor).frame(width: 30)
            Text("\(low)°").foregroundStyle(.secondary).frame(width: 36)
            Capsule().fill(LinearGradient(colors: [Theme.brand, .orange], startPoint: .leading, endPoint: .trailing))
                .frame(height: 5)
            Text("\(high)°").frame(width: 36)
        }
    }
}

public struct CurrentConditions: View {
    var city: String, temperature: Int, condition: Condition
    public init(city: String, temperature: Int, condition: Condition) {
        self.city = city; self.temperature = temperature; self.condition = condition
    }
    public var body: some View {
        VStack(spacing: 4) {
            Text(city).font(.title2)
            Text("\(temperature)°").font(.system(size: 64, weight: .thin))
            ConditionBadge(condition)
        }
        .frame(maxWidth: .infinity)
    }
}

public struct AlertBanner: View {
    public enum Level { case info, warning, severe }
    var level: Level, text: String
    public init(level: Level, text: String) { self.level = level; self.text = text }
    var color: Color { switch level { case .info: Theme.brand; case .warning: .orange; case .severe: .red } }
    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

public struct TodayScreen: View {
    public init() {}
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CurrentConditions(city: "Lisbon", temperature: 21, condition: .sunny)
                AlertBanner(level: .warning, text: "Strong winds expected this evening.")
                VStack(spacing: 10) {
                    ForEach(Array(zip(["Mon", "Tue", "Wed", "Thu", "Fri"], Condition.allCases)), id: \.0) {
                        ForecastRow(day: $0.0, condition: $0.1, low: 12, high: 22)
                    }
                }
            }
            .padding()
        }
    }
}
EOF
cat > "$DEST/Weather/Tests/WeatherTests/WeatherTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import Weather

@MainActor
@Suite
struct ConditionTests {
    @Test(arguments: Condition.allCases)
    func badge(condition: Condition) { snap(ConditionBadge(condition), width: 200, height: 70, named: condition.rawValue) }
}

@MainActor
@Suite
struct ForecastTests {
    @Test func monday() { snap(ForecastRow(day: "Mon", condition: .sunny, low: 14, high: 24), height: 60) }
    @Test func rainyDay() { snap(ForecastRow(day: "Tue", condition: .rain, low: 11, high: 16), height: 60) }
    @Test func coldDay() { snap(ForecastRow(day: "Sat", condition: .snow, low: -4, high: 1), height: 60) }
    @Test func current() { snap(CurrentConditions(city: "Lisbon", temperature: 21, condition: .sunny), height: 200) }
    @Test func currentCold() { snap(CurrentConditions(city: "Oslo", temperature: -3, condition: .snow), height: 200) }
}

@MainActor
@Suite
struct AlertTests {
    @Test func info() { snap(AlertBanner(level: .info, text: "Pollen count is low today."), height: 80) }
    @Test func warning() { snap(AlertBanner(level: .warning, text: "Strong winds expected this evening."), height: 80) }
    @Test func severe() { snap(AlertBanner(level: .severe, text: "Thunderstorm warning until 22:00. Stay indoors."), height: 90) }
}

@MainActor
@Suite
struct WeatherScreenTests {
    @Test func today() { snapScreen(TodayScreen()) }
}
EOF
record_develop Weather
make_branch Weather feature/new-palette "Color(red: 0.35, green: 0.35, blue: 0.85)" \
  Views.swift "frame(height: 5)" "frame(height: 7)" Views.swift "size: 64, weight: .thin" "size: 56, weight: .light"

# ---------------------------------------------------------------------------------------------
step "Chat"
scaffold Chat
cat > "$DEST/Chat/Sources/Chat/Theme.swift" <<'EOF'
import SwiftUI

public enum Theme {
    static let brand = Color(red: 0.15, green: 0.65, blue: 0.40)
}
EOF
cat > "$DEST/Chat/Sources/Chat/Views.swift" <<'EOF'
import SwiftUI

public struct Avatar: View {
    var name: String, size: CGFloat
    public init(name: String, size: CGFloat = 40) { self.name = name; self.size = size }
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
    public var body: some View {
        Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(Theme.brand.gradient, in: Circle())
    }
}

public struct MessageBubble: View {
    var text: String, outgoing: Bool
    public init(text: String, outgoing: Bool) { self.text = text; self.outgoing = outgoing }
    public var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 40) }
            Text(text).padding(.horizontal, 14).padding(.vertical, 10)
                .background(outgoing ? Theme.brand : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(outgoing ? Color.white : Color.primary)
            if !outgoing { Spacer(minLength: 40) }
        }
    }
}

public struct ConversationRow: View {
    var name: String, preview: String, time: String, unread: Int, muted: Bool
    public init(name: String, preview: String, time: String, unread: Int = 0, muted: Bool = false) {
        self.name = name; self.preview = preview; self.time = time; self.unread = unread; self.muted = muted
    }
    public var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).font(.headline)
                    if muted { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(time).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(preview).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    if unread > 0 {
                        Text("\(unread)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.brand, in: Capsule()).foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

public struct TypingIndicator: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 5) { ForEach(0..<3) { Circle().fill(.secondary).frame(width: 8, height: 8).opacity(0.4 + Double($0) * 0.25) } }
            .padding(12).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }
}

public struct Composer: View {
    var text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        HStack {
            Text(text.isEmpty ? "Message" : text).foregroundStyle(text.isEmpty ? .secondary : .primary)
            Spacer()
            Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(text.isEmpty ? Color.gray : Theme.brand)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(Capsule().strokeBorder(Color.gray.opacity(0.4)))
    }
}

public struct ConversationScreen: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    VStack(spacing: 8) {
                        MessageBubble(text: "Are we still on for Saturday?", outgoing: false)
                        MessageBubble(text: "Yes! Trailhead at 9.", outgoing: true)
                        MessageBubble(text: "I'll bring snacks 🍫", outgoing: false)
                        HStack { TypingIndicator(); Spacer() }
                    }
                    .padding()
                }
                Composer(text: "").padding()
            }
            .navigationTitle("Hiking Club")
        }
    }
}
EOF
cat > "$DEST/Chat/Tests/ChatTests/ChatTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

@MainActor
@Suite
struct BubbleTests {
    @Test func incoming() { snap(MessageBubble(text: "Are we still on for Saturday?", outgoing: false), height: 70) }
    @Test func outgoing() { snap(MessageBubble(text: "Yes! Trailhead at 9.", outgoing: true), height: 70) }
    @Test func long() {
        snap(MessageBubble(text: "Bring a rain jacket, the forecast says showers in the afternoon, and maybe gloves.", outgoing: false), height: 110)
    }
    @Test func emoji() { snap(MessageBubble(text: "🎉🎉🎉", outgoing: true), height: 70) }
    @Test func typing() { snap(TypingIndicator(), width: 120, height: 70) }
}

@MainActor
@Suite
struct ConversationRowTests {
    @Test func unread() { snap(ConversationRow(name: "Hiking Club", preview: "I'll bring snacks", time: "9:41", unread: 3), height: 80) }
    @Test func read() { snap(ConversationRow(name: "Ana Lima", preview: "See you tomorrow!", time: "Yesterday"), height: 80) }
    @Test func muted() { snap(ConversationRow(name: "Neighbours", preview: "Parcel at no. 12", time: "Mon", unread: 12, muted: true), height: 80) }
    @Test func avatars() {
        snap(HStack { Avatar(name: "Ana Lima"); Avatar(name: "Kai"); Avatar(name: "Sam Okafor", size: 56) }, width: 220, height: 90)
    }
}

@MainActor
@Suite
struct ComposerTests {
    @Test func empty() { snap(Composer(text: ""), height: 70) }
    @Test func typing() { snap(Composer(text: "On my way"), height: 70) }
}

@MainActor
@Suite
struct ChatScreenTests {
    @Test func conversation() { snapScreen(ConversationScreen()) }
}
EOF
record_develop Chat
make_branch Chat feature/rounder-bubbles "Color(red: 0.05, green: 0.55, blue: 0.75)" \
  Views.swift "cornerRadius: 18" "cornerRadius: 22" Views.swift "size \* 0.4" "size * 0.45"
# A new snapshot, recorded but not committed.
(cd "$DEST/Chat" && cat > Tests/ChatTests/ReactionTests.swift <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

@MainActor
@Suite
struct ReactionTests {
    @Test func reacted() { snap(MessageBubble(text: "Summit! ⛰️", outgoing: true).overlay(alignment: .bottomTrailing) { Text("❤️") }, height: 80) }
}
EOF
run_tests Chat)

# ---------------------------------------------------------------------------------------------
step "Fitness"
scaffold Fitness
cat > "$DEST/Fitness/Sources/Fitness/Theme.swift" <<'EOF'
import SwiftUI

public enum Theme {
    static let brand = Color(red: 0.95, green: 0.30, blue: 0.35)
}
EOF
cat > "$DEST/Fitness/Sources/Fitness/Views.swift" <<'EOF'
import SwiftUI

public struct ActivityRing: View {
    var progress: Double
    public init(progress: Double) { self.progress = progress }
    public var body: some View {
        ZStack {
            Circle().stroke(Theme.brand.opacity(0.2), lineWidth: 14)
            Circle().trim(from: 0, to: min(progress, 1)).stroke(Theme.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%").font(.headline)
        }
        .frame(width: 90, height: 90)
    }
}

public struct StatTile: View {
    var title: String, value: String, symbol: String
    public init(title: String, value: String, symbol: String) { self.title = title; self.value = value; self.symbol = symbol }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

public struct WorkoutRow: View {
    var kind: String, symbol: String, minutes: Int, distance: String
    public init(kind: String, symbol: String, minutes: Int, distance: String) {
        self.kind = kind; self.symbol = symbol; self.minutes = minutes; self.distance = distance
    }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.brand).frame(width: 40, height: 40)
                .background(Theme.brand.opacity(0.12), in: Circle())
            VStack(alignment: .leading) { Text(kind).font(.headline); Text("\(minutes) min").foregroundStyle(.secondary) }
            Spacer()
            Text(distance).font(.headline.monospacedDigit())
        }
    }
}

public struct WeeklyBars: View {
    var values: [Double]
    public init(values: [Double]) { self.values = values }
    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack {
                    RoundedRectangle(cornerRadius: 4).fill(index == values.count - 1 ? Theme.brand : Theme.brand.opacity(0.4))
                        .frame(width: 22, height: 100 * value)
                    Text(["M", "T", "W", "T", "F", "S", "S"][index % 7]).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

public struct SummaryScreen: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 20) { ActivityRing(progress: 0.72); ActivityRing(progress: 0.4); ActivityRing(progress: 1.0) }
                    HStack { StatTile(title: "Steps", value: "8,412", symbol: "figure.walk"); StatTile(title: "Energy", value: "512 kcal", symbol: "flame.fill") }
                    WeeklyBars(values: [0.4, 0.7, 0.55, 0.9, 0.3, 0.8, 0.65])
                    WorkoutRow(kind: "Morning Run", symbol: "figure.run", minutes: 42, distance: "7.2 km")
                }
                .padding()
            }
            .navigationTitle("Today")
        }
    }
}
EOF
cat > "$DEST/Fitness/Tests/FitnessTests/FitnessTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import Fitness

@MainActor
@Suite
struct RingTests {
    @Test(arguments: [0.0, 0.25, 0.6, 1.0])
    func ring(progress: Double) { snap(ActivityRing(progress: progress), width: 140, height: 130, named: "\(Int(progress * 100))") }
}

@MainActor
@Suite
struct TileTests {
    @Test func steps() { snap(StatTile(title: "Steps", value: "8,412", symbol: "figure.walk"), width: 200, height: 110) }
    @Test func energy() { snap(StatTile(title: "Energy", value: "512 kcal", symbol: "flame.fill"), width: 200, height: 110) }
    @Test func distance() { snap(StatTile(title: "Distance", value: "6.1 km", symbol: "map.fill"), width: 200, height: 110) }
}

@MainActor
@Suite
struct WorkoutTests {
    @Test func run() { snap(WorkoutRow(kind: "Morning Run", symbol: "figure.run", minutes: 42, distance: "7.2 km"), height: 80) }
    @Test func swim() { snap(WorkoutRow(kind: "Pool Swim", symbol: "figure.pool.swim", minutes: 30, distance: "1.2 km"), height: 80) }
    @Test func ride() { snap(WorkoutRow(kind: "Evening Ride", symbol: "figure.outdoor.cycle", minutes: 75, distance: "28 km"), height: 80) }
    @Test func week() { snap(WeeklyBars(values: [0.4, 0.7, 0.55, 0.9, 0.3, 0.8, 0.65]), height: 160) }
}

@MainActor
@Suite
struct FitnessScreenTests {
    @Test func summary() { snapScreen(SummaryScreen()) }
}
EOF
record_develop Fitness
make_branch Fitness feature/energy-orange "Color(red: 0.98, green: 0.55, blue: 0.10)" \
  Views.swift "lineWidth: 14)" "lineWidth: 18)" Views.swift "width: 22, height" "width: 26, height"

# ---------------------------------------------------------------------------------------------
step "DesignKit"
scaffold DesignKit
cat > "$DEST/DesignKit/Sources/DesignKit/Components.swift" <<'EOF'
import SwiftUI

public enum Tone: String, CaseIterable { case neutral, accent, success, warning, danger
    var color: Color {
        switch self {
        case .neutral: .gray
        case .accent: .indigo
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }
}

public struct KitButton: View {
    public enum Kind: String, CaseIterable { case primary, secondary, destructive, plain }
    var title: String, kind: Kind, enabled: Bool
    public init(_ title: String, kind: Kind, enabled: Bool = true) { self.title = title; self.kind = kind; self.enabled = enabled }
    public var body: some View {
        let fill: Color = switch kind { case .primary: .indigo; case .secondary: .indigo.opacity(0.12); case .destructive: .red; case .plain: .clear }
        let text: Color = switch kind { case .primary, .destructive: .white; case .secondary, .plain: .indigo }
        Text(title).bold().padding(.horizontal, 18).padding(.vertical, 11)
            .background(fill, in: Capsule()).foregroundStyle(text).opacity(enabled ? 1 : 0.4)
    }
}

public struct Badge: View {
    var text: String, tone: Tone
    public init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    public var body: some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.color.opacity(0.18), in: Capsule()).foregroundStyle(tone.color)
    }
}

public struct Banner: View {
    var title: String, message: String, tone: Tone
    public init(title: String, message: String, tone: Tone) { self.title = title; self.message = message; self.tone = tone }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(tone.color)
            Text(message).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tone.color.opacity(0.4)))
    }
}

public struct Card: View {
    var title: String, subtitle: String, symbol: String
    public init(title: String, subtitle: String, symbol: String) { self.title = title; self.subtitle = subtitle; self.symbol = symbol }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.indigo)
            VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
EOF
cat > "$DEST/DesignKit/Tests/DesignKitTests/DesignKitTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import DesignKit

@MainActor
@Suite
struct ButtonTests {
    @Test(arguments: KitButton.Kind.allCases)
    func button(kind: KitButton.Kind) { snap(KitButton("Continue", kind: kind), width: 200, height: 70, named: kind.rawValue) }
    @Test(arguments: KitButton.Kind.allCases)
    func disabled(kind: KitButton.Kind) { snap(KitButton("Continue", kind: kind, enabled: false), width: 200, height: 70, named: kind.rawValue) }
}

@MainActor
@Suite
struct BadgeTests {
    @Test(arguments: Tone.allCases)
    func badge(tone: Tone) { snap(Badge(tone.rawValue.capitalized, tone: tone), width: 140, height: 50, named: tone.rawValue) }
}

@MainActor
@Suite
struct BannerTests {
    @Test func success() { snap(Banner(title: "Saved", message: "Your changes are live.", tone: .success), height: 100) }
    @Test func warning() { snap(Banner(title: "Almost full", message: "You have used 90% of your storage.", tone: .warning), height: 100) }
    @Test func danger() { snap(Banner(title: "Payment failed", message: "Check your card details and try again.", tone: .danger), height: 100) }
    @Test func card() { snap(Card(title: "Notifications", subtitle: "Sounds, badges, banners", symbol: "bell.badge.fill"), height: 90) }
}
EOF
record_develop DesignKit

rm -rf "$DEST/.derived"
step "Done"
for name in Shop Weather Chat Fitness DesignKit; do
  (cd "$DEST/$name" && printf '%-10s %3s snapshots · %s\n' "$name" "$(find . -path '*__Snapshots__*' -name '*.png' | wc -l | tr -d ' ')" "$(git branch --show-current)")
done
echo "Samples in $DEST. Add the folder in SnapshotKit (sidebar + › Add Scan Folder, or drop it onto the window)."
