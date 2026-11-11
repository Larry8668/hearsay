import AppKit
import SwiftUI

/// The inline editors of the content header: the title, the tag row and a voice chip's rename
/// field, plus the sidebar's search field and the small tag chip the sidebar rows use. All of
/// them edit in place (no sheet, no popover): a field appears where the text was, Enter saves,
/// Esc cancels, and clicking elsewhere saves what was typed, as a Finder rename does.
///
/// Which editor is open is `MainWindowState.editing`, one at a time for the live and the saved
/// views alike, so the dev script can open each for a screenshot.
enum MetaEditing: Equatable {
    case title, tag, rename(Voice)
}

/// A one-line editable title. Shows `title`, or `placeholder` (the date range, "Live
/// transcript") while there is none; the pencil appears on hover, and the text itself is
/// clickable too. Saving an empty field removes the title.
struct TitleEditor: View {
    let title: String?
    let placeholder: String
    @Binding var editing: Bool
    let save: (String?) -> Void
    @State private var draft = ""
    @State private var hover = false
    @State private var cancelled = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("Add a title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($focused)
                    .onSubmit { finish(save: true) }
                    .onExitCommand { finish(save: false) }
                    .onAppear {
                        draft = title ?? ""
                        cancelled = false
                        DispatchQueue.main.async { focused = true }   // the field must exist before it can take focus
                    }
                    .onChange(of: focused) { if !focused && editing { finish(save: !cancelled) } }
            } else {
                Text(title ?? placeholder)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                    .help(title == nil ? "Click to add a title" : "Click to edit the title")
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .medium)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
                .accessibilityLabel("Edit title")
            }
        }
        .onHover { hover = $0 }
    }

    private func finish(save keep: Bool) {
        if !keep { cancelled = true }
        editing = false
        if keep { save(draft) }
    }
}

/// The transcript's tags as removable chips and a "+ Tag" affordance that turns into a field.
/// While typing, the tags used elsewhere that match are offered beside the field; a click adds
/// one, Enter adds what was typed, and the field stays open for the next tag until Esc or a
/// click elsewhere.
struct TagRow: View {
    let tags: [String]
    /// Tags in use across the library, most used first.
    let suggestions: [String]
    @Binding var adding: Bool
    let save: ([String]) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                TagChip(text: t, size: 11, remove: { save(tags.filter { $0 != t }) })
            }
            if adding {
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("tag", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 11, weight: .medium))
                        .frame(width: 96)
                        .focused($focused)
                        .onSubmit { add(draft) }
                        .onExitCommand { adding = false }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                .onAppear { draft = ""; DispatchQueue.main.async { focused = true } }
                .onChange(of: focused) { if !focused && adding { if !draft.isEmpty { add(draft) }; adding = false } }
                ForEach(matching, id: \.self) { s in
                    Button { add(s) } label: {
                        Text(s).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add \"\(s)\"")
                }
            } else {
                Button { adding = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 8.5, weight: .bold))
                        Text("Tag")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Add a tag")
            }
        }
    }

    /// Suggestions not already on this transcript that contain what was typed (all of them
    /// while the field is empty), at most five so the row stays short.
    private var matching: [String] {
        Array(suggestions.filter { s in
            !tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                && (draft.isEmpty || s.localizedCaseInsensitiveContains(draft))
        }.prefix(5))
    }

    private func add(_ s: String) {
        let next = TranscriptMeta.cleanTags(tags + [s])
        if next != tags { save(next) }
        draft = ""
        focused = true
    }
}

/// "design" in a small neutral capsule; with `remove`, an × that takes it off the transcript.
struct TagChip: View {
    let text: String
    var size: CGFloat = 10
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: size, weight: .medium)).lineLimit(1)
            if let remove = remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: size - 3, weight: .bold)).frame(width: 10, height: 10)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("Remove \"\(text)\"")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, remove == nil ? 6 : 8).padding(.trailing, remove == nil ? 6 : 5).padding(.vertical, remove == nil ? 1.5 : 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// One voice's toggle chip (as before: on = filled, off = hollow with an eye) with its name
/// editable in place: right-click ▸ Rename…, or the pencil that appears on hover. The field
/// starts with the current custom name; empty puts the built-in label back. Colours never
/// change with the name.
struct VoiceChip: View {
    let voice: Voice
    let label: String
    /// The name set for this voice on this transcript (nil: built-in label or Settings ▸ Your name).
    let customName: String?
    /// The transcript's diarized speakers: the speaker's tint and generated label.
    var roster = SpeakerRoster()
    let off: Bool
    @Binding var renaming: Bool
    let toggle: () -> Void
    let rename: (String?) -> Void
    @State private var draft = ""
    @State private var hover = false
    @State private var cancelled = false
    @FocusState private var focused: Bool

    private var color: Color { LaneColors.adaptive(voice, roster) }

    var body: some View {
        if renaming {
            HStack(spacing: 4) {
                Image(systemName: "pencil").font(.system(size: 8.5, weight: .bold))
                TextField(LaneColors.chipLabel(voice, roster), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 104)
                    .focused($focused)
                    .onSubmit { finish(save: true) }
                    .onExitCommand { finish(save: false) }
                    .onChange(of: focused) { if !focused && renaming { finish(save: !cancelled) } }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .onAppear { draft = customName ?? ""; cancelled = false; DispatchQueue.main.async { focused = true } }
        } else {
            HStack(spacing: 3) {
                Button(action: toggle) {
                    HStack(spacing: 4) {
                        Image(systemName: off ? "eye.slash" : "checkmark").font(.system(size: 8.5, weight: .bold))
                        Text(label)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(off ? Color.secondary : color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(off ? Color.clear : color.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(off ? Color.primary.opacity(0.18) : Color.clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(off ? "Show \(label)" : "Hide \(label)")
                .contextMenu {
                    Button("Rename…") { renaming = true }
                    if customName != nil { Button("Use the default name") { rename(nil) } }
                }
                Button { renaming = true } label: {
                    Image(systemName: "pencil").font(.system(size: 9.5, weight: .semibold)).frame(width: 12, height: 14)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
                .accessibilityLabel("Rename \(label)")
            }
            .onHover { hover = $0 }
        }
    }

    private func finish(save keep: Bool) {
        if !keep { cancelled = true }
        renaming = false
        if keep { rename(draft) }
    }
}

/// The sidebar's search: filters the list by title, tag, name and line text. The typed text
/// reaches `query` 250 ms after the last keystroke, so the list isn't refiltered per key.
struct SidebarSearchField: View {
    @Binding var query: String
    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search transcripts", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(focused ? 0.2 : 0.1), lineWidth: 1))
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        .onChange(of: text) {
            pending?.cancel()
            let t = text
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled && query != t { query = t }
            }
        }
        .onChange(of: query) { if query != text { text = query } }   // set from outside (the dev script)
    }
}
