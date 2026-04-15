import AppKit

protocol StringPasteboardWriting {
    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: StringPasteboardWriting {}

enum OpenAIAccountGroupEmailCopyAction {
    @discardableResult
    static func perform(
        email: String,
        pasteboard: any StringPasteboardWriting = NSPasteboard.general
    ) -> String? {
        guard let copyableEmail = OpenAIAccountPresentation.copyableAccountGroupEmail(email) else {
            return nil
        }

        _ = pasteboard.clearContents()
        _ = pasteboard.setString(copyableEmail, forType: .string)
        return copyableEmail
    }
}
