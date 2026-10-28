import AppKit

extension NSPasteboard {
    /// Replaces what's on the pasteboard with `text`. Concealed text, such as a secret, is
    /// marked so clipboard history, ours and other apps', leaves it out.
    func copy(_ text: String, concealed: Bool = false) {
        clearContents()
        setString(text, forType: .string)
        if concealed {
            setString("", forType: ClipboardController.concealedType)
        }
    }
}
