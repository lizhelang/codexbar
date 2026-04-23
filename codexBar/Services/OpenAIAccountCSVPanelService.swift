import AppKit
import Foundation
import UniformTypeIdentifiers

enum OpenAIAccountCSVToolbarUI {
    static let symbolName = "arrow.up.arrow.down.circle"
    static let accessibilityIdentifier = "codexbar.openai-csv.toolbar"
}

@MainActor
struct OpenAIAccountCSVPanelService {
    typealias AppActivator = @MainActor () -> Void
    typealias ExportURLRequester = @MainActor (_ suggestedFilename: String) -> URL?
    typealias ImportURLRequester = @MainActor () -> URL?

    private let activateApp: AppActivator
    private let requestExportURLAction: ExportURLRequester
    private let requestImportURLAction: ImportURLRequester

    init(
        activateApp: @escaping AppActivator = { OpenAIAccountCSVPanelService.activateApp() },
        requestExportURLAction: @escaping ExportURLRequester = { suggestedFilename in
            OpenAIAccountCSVPanelService.presentExportPanel(suggestedFilename: suggestedFilename)
        },
        requestImportURLAction: @escaping ImportURLRequester = { OpenAIAccountCSVPanelService.presentImportPanel() }
    ) {
        self.activateApp = activateApp
        self.requestExportURLAction = requestExportURLAction
        self.requestImportURLAction = requestImportURLAction
    }

    func requestExportURL() -> URL? {
        self.activateApp()
        return self.requestExportURLAction(self.defaultExportFilename())
    }

    func requestImportURL() -> URL? {
        self.activateApp()
        return self.requestImportURLAction()
    }

    private func defaultExportFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "rhino2api-account-\(formatter.string(from: now)).json"
    }

    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func presentExportPanel(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L.exportOpenAICSVAction
        panel.prompt = L.openAICSVExportPrompt
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedFilename
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func presentImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L.importOpenAICSVAction
        panel.prompt = L.openAICSVImportPrompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
