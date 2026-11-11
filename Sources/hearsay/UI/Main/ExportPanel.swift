import AppKit
import UniformTypeIdentifiers

/// Export…: a save panel with a format popup (Markdown, JSON, plain text, subtitles). The
/// transcript it writes is what the window shows: hidden voices are already out of the
/// `TranscriptExport`. The suggested name is the title, else the transcript's own date name.
/// The last format chosen is remembered.
@MainActor
enum ExportPanel {
    private static let formatKey = "exportFormat"

    static var lastFormat: ExportFormat {
        get { ExportFormat(rawValue: Prefs.store.string(forKey: formatKey) ?? "") ?? .markdown }
        set { Prefs.store.set(newValue.rawValue, forKey: formatKey) }
    }

    /// As a sheet on `window` when there is one (the main window), else a standalone panel.
    static func run(_ export: TranscriptExport, in window: NSWindow?, format chosen: ExportFormat? = nil) {
        guard !export.lines.isEmpty else { return }
        let format = chosen ?? lastFormat
        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.nameFieldLabel = "Export as:"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let chooser = FormatChooser(panel: panel, format: format)
        panel.accessoryView = chooser.view
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = export.defaultName + "." + format.fileExtension
        let done = { (response: NSApplication.ModalResponse) in
            _ = chooser   // kept alive until the panel is done
            guard response == .OK, let url = panel.url else { return }
            lastFormat = chooser.format
            do {
                try export.write(chooser.format, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                Log.error("transcript: export failed: \(error)")
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }
}

/// "Format: [Markdown (.md) ▾]" under the name field. Changing it swaps the panel's allowed
/// type and the name's extension, so the saved file always matches the popup.
@MainActor
private final class FormatChooser: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    var format: ExportFormat { ExportFormat.allCases[max(0, popup.indexOfSelectedItem)] }

    init(panel: NSSavePanel, format: ExportFormat) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        label.font = .systemFont(ofSize: 13)
        for f in ExportFormat.allCases { popup.addItem(withTitle: f.title) }
        popup.selectItem(at: ExportFormat.allCases.firstIndex(of: format) ?? 0)
        popup.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            row.topAnchor.constraint(equalTo: box.topAnchor), row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(greaterThanOrEqualTo: row.widthAnchor),
        ])
        view = box
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        guard let panel = panel else { return }
        let f = format
        panel.allowedContentTypes = [f.contentType]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (name.isEmpty ? "transcript" : name) + "." + f.fileExtension
    }
}
