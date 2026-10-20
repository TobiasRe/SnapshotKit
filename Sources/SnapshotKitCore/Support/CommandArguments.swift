import Foundation

/// A `snapkit` command's arguments, checked against the options that command takes, so a typo or
/// a missing value is an error instead of quietly doing something else.
package struct CommandArguments: Sendable {
    package enum Option: Sendable {
        case flag
        /// Takes the next argument as its value; repeating it collects every value.
        case value
        /// Takes the next argument when it isn't an option (`--remote` or `--remote HOST`). Only for
        /// commands without arguments of their own, which it could swallow.
        case optionalValue
    }

    package private(set) var positional: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    /// - Parameters:
    ///   - options: every option the command takes, by name (`--repo`, `-o`).
    ///   - count: how many other arguments it takes.
    package init(_ arguments: [String], options: [String: Option], positional count: ClosedRange<Int> = 0...0) throws(UsageError) {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("-"), argument != "-" else {
                positional.append(argument)
                continue
            }
            switch options[argument] {
            case nil:
                throw UsageError("unknown option \(argument)")
            case .flag:
                flags.insert(argument)
            case .value:
                guard let value = rest.popFirst(), !value.hasPrefix("-") else { throw UsageError("\(argument) needs a value") }
                values[argument, default: []].append(value)
            case .optionalValue:
                if let next = rest.first, !next.hasPrefix("-") {
                    values[argument, default: []].append(next)
                    rest.removeFirst()
                } else {
                    flags.insert(argument)
                }
            }
        }
        if self.positional.count > count.upperBound {
            throw UsageError("unexpected argument '\(self.positional[count.upperBound])'")
        }
        if self.positional.count < count.lowerBound { throw UsageError("missing arguments") }
    }

    /// The option's value; the last one when it was given more than once.
    package func value(_ name: String) -> String? { values[name]?.last }
    package func all(_ name: String) -> [String] { values[name] ?? [] }
    package func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }

    /// The option's value as a whole number of at least `minimum`, nil when the option isn't given.
    package func integer(_ name: String, atLeast minimum: Int) throws(UsageError) -> Int? {
        guard let text = value(name) else { return nil }
        guard let number = Int(text), number >= minimum else {
            throw UsageError("\(name) needs a whole number of at least \(minimum), not '\(text)'")
        }
        return number
    }
}

package struct UsageError: Error, Equatable, CustomStringConvertible {
    package var description: String

    package init(_ description: String) {
        self.description = description
    }
}
