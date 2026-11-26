#if canImport(UIKit)
import UIKit
#endif

enum DeviceWord {
#if canImport(UIKit)
    static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
#else
    // Phone/SyncCheck builds the sync engine for macOS, where it stands for an iPhone.
    static var name: String { "iPhone" }
#endif
}
