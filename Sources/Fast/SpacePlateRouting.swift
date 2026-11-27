import Foundation

/// Which pages a turn can show: a swipe has only real neighbors; a key
/// crosses the range. And what a space's plate shows, for its pages' keys.
enum SpacePlateRouting {
    struct Plate: Equatable {
        let shown: Bool
        let extensionHeight: CGFloat
        let extensions: [String]

        init(shown: Bool, extensionHeight: CGFloat = 0, extensions: [String] = []) {
            self.shown = shown
            self.extensionHeight = shown ? extensionHeight : 0
            self.extensions = shown ? extensions : []
        }
    }

    static func places(home: Int, count: Int, toward target: Int?) -> [Int] {
        guard count > 0, (0..<count).contains(home) else { return [] }
        if let target {
            guard (0..<count).contains(target) else { return [] }
            return (min(home, target)...max(home, target)).filter { $0 != home }
        }
        return [home - 1, home + 1].filter { (0..<count).contains($0) }
    }
}
