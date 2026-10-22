import Foundation

/// A Semantic Versioning value used to compare the app version with release tags.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]
    public let prerelease: [String]

    public init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }

        let withoutMetadata = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !core.isEmpty else { return nil }

        var numbers: [Int] = []
        for component in core {
            guard !component.isEmpty, component.allSatisfy(\.isNumber), let number = Int(component) else {
                return nil
            }
            numbers.append(number)
        }

        let prerelease = parts.count == 2
            ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }

        self.components = numbers
        self.prerelease = prerelease
    }

    public var description: String {
        let core = components.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (.some(leftNumber), .some(rightNumber)):
                return leftNumber < rightNumber
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return lhs.prerelease == rhs.prerelease
    }
}
