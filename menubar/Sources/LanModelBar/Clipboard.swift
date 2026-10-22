import AppKit

enum Clipboard {
    /// Copies a secret and clears the pasteboard after `seconds` if it still holds that exact value.
    static func copySecret(_ value: String, clearAfter seconds: TimeInterval = 60) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if pb.changeCount == count, pb.string(forType: .string) == value { pb.clearContents() }
        }
    }

    static func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }
}
