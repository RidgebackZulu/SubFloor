import DSPCore
import Foundation
import SubFloorCore
import Transcription

/// Bookmarks. An agent's bookmark carries its client name (`addedBy`); any agent may edit or delete those.
/// The owner's bookmarks are only ever appended to (`append_notes`).
extension SubFloorTools {
    static var bookmarkTools: [SubFloorTool] {
        let fields: [String: JSONValue] = [
            "name": .schema("string", "Short and clear, e.g. \"VOLMET Shannon\"."),
            "frequency": .frequencySchema("Display Hz, or a string like \"7.074 MHz\"."),
            "mode": .enumSchema(DemodMode.allCases.map(\.rawValue), "Demodulator."),
            "bandwidth_hz": .schema("number", "Passband width in Hz (clamped to the mode's range)."),
            "group": .schema("string", "Group name; an existing group's spelling is matched."),
            "notes": .schema("string", "What, when, and the evidence."),
            "hamitup": .enumSchema(["on", "off", "auto"], "HamItUp when the bookmark is tuned."),
        ]
        return [
            SubFloorTool("list_bookmarks", title: "List bookmarks", readOnly: true, description: """
                The bookmarks, by frequency, optionally only those whose name, notes, group or added_by contain \
                query, or in group. Each has id, name, frequency_hz, mode, bandwidth_hz, hamitup, group, notes, \
                added_by (the agent that added it; null for the owner's) and created. Also returns the groups.
                """, properties: [
                    "query": .schema("string", "Text to look for (case-insensitive)."),
                    "group": .schema("string", "Only this group (case-insensitive)."),
                ]) { t, args, _ in try t.listBookmarks(args) },

            SubFloorTool("add_bookmark", title: "Add bookmark", readOnly: false, description: """
                Save a bookmark, marked as added by you. name and frequency are needed; mode defaults to the \
                current one, bandwidth_hz to the current or the mode's default, hamitup to as it is now ("auto": \
                on below 30 MHz). Returns {id}.
                """, properties: fields, required: ["name", "frequency"]) { t, args, client in
                try t.addBookmark(args, client: client)
            },

            SubFloorTool("update_bookmark", title: "Update bookmark", readOnly: false, description: """
                Change a bookmark an agent added (any agent): any of name, frequency, mode, bandwidth_hz, group, \
                notes, hamitup. append_notes adds a line to the notes, and is the only change allowed on the \
                owner's own bookmarks (added_by null). Returns {bookmark}.
                """, properties: fields.merging(["id": .schema("string", "The bookmark's id (list_bookmarks)."),
                                                  "append_notes": .schema("string", "A line to add to the notes.")]) { a, _ in a },
                required: ["id"]) { t, args, _ in try t.updateBookmark(args) },

            SubFloorTool("delete_bookmark", title: "Delete bookmark", readOnly: false, description: """
                Delete a bookmark an agent added. The owner's bookmarks can't be deleted. Returns {deleted}.
                """, properties: ["id": .schema("string", "The bookmark's id (list_bookmarks).")],
                required: ["id"]) { t, args, _ in try t.deleteBookmark(args) },
        ]
    }

    static let bookmarkFields = ["name", "frequency", "mode", "bandwidth_hz", "group", "notes", "hamitup"]
    static let tuningFields = ["frequency", "mode", "bandwidth_hz", "hamitup"]

    func bookmarkJSON(_ b: Bookmark) -> JSONValue {
        .object(["id": .string(b.id.uuidString), "name": .string(b.name), "frequency_hz": .hz(b.frequencyHz),
                 "mode": .string(b.mode.rawValue), "bandwidth_hz": .hz(b.bandwidthHz), "hamitup": .bool(b.upconverter),
                 "group": b.group.map { .string($0) }.orNull, "notes": b.notes.map { .string($0) }.orNull,
                 "added_by": b.addedBy.map { .string($0) }.orNull, "created": b.created.map { .time($0) }.orNull])
    }

    func listBookmarks(_ args: ToolArguments) throws -> [String: JSONValue] {
        let query = try args.string("query"), group = try args.string("group")
        let found = model.bookmarks.filter { b in
            if let group, b.group?.caseInsensitiveCompare(group) != .orderedSame { return false }
            guard let query else { return true }
            return [b.name, b.notes, b.group, b.addedBy].contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
        return ["bookmarks": .array(found.sorted { $0.frequencyHz < $1.frequencyHz }.map(bookmarkJSON)),
                "groups": .array(model.bookmarkGroups.map { .string($0) })]
    }

    /// The bookmark `args["id"]` names.
    private func bookmark(_ args: ToolArguments) throws -> Bookmark {
        let text = try args.required("id", args.string)
        guard let id = UUID(uuidString: text), let b = model.bookmarks.first(where: { $0.id == id }) else {
            throw ToolError("No bookmark has id \(text): call list_bookmarks for the ids.")
        }
        return b
    }

    /// `b` with the mode, bandwidth, HamItUp and frequency in `args` (bandwidth clamped to the mode's range; a
    /// new mode without a bandwidth takes its default), checked to be tunable.
    private func applyTuning(_ args: ToolArguments, to b: inout Bookmark) throws {
        let hz = try args.frequency("frequency") ?? b.frequencyHz
        if let mode = try Self.demodMode(args), mode != b.mode {
            b.mode = mode
            b.bandwidthHz = mode.defaultBandwidth
        }
        if let bw = try args.double("bandwidth_hz") { b.bandwidthHz = bw }
        let range = b.mode.bandwidthRange
        b.bandwidthHz = min(max(b.bandwidthHz, range.lowerBound), range.upperBound).rounded()
        let current = Upconverter(enabled: b.upconverter, loHz: model.upconverter.loHz)
        let up = Self.upconverter(for: hz, setting: try Self.hamitupSetting(args), current: current)
        try Self.checkTunable(hz, up)
        b.upconverter = up.enabled
        b.frequencyHz = hz
    }

    func addBookmark(_ args: ToolArguments, client: String) throws -> [String: JSONValue] {
        let m = model
        var b = Bookmark(name: try args.required("name", args.string), frequencyHz: try args.required("frequency", args.frequency),
                         mode: m.mode, bandwidthHz: m.bandwidthHz, upconverter: m.upconverter.enabled,
                         group: try args.string("group"), notes: try args.string("notes"), addedBy: client)
        try applyTuning(args, to: &b)
        return ["id": .string(m.addBookmark(b).uuidString)]
    }

    func updateBookmark(_ args: ToolArguments) throws -> [String: JSONValue] {
        var b = try bookmark(args)
        let edits = Self.bookmarkFields.filter(args.has)
        let append = try args.string("append_notes")
        guard b.isFromAgent || edits.isEmpty else {
            throw ToolError("That bookmark is the owner's: only append_notes is allowed.")
        }
        guard !edits.isEmpty || append != nil else { throw ToolError("Nothing to change: give a field or append_notes.") }
        if args.has("name") {
            guard let name = try args.string("name") else { throw ToolError("name can't be empty.") }
            b.name = name
        }
        if args.has("group") { b.group = BookmarkGroups.normalized(try args.string("group"), existing: model.bookmarkGroups) }
        if args.has("notes") { b.notes = try args.string("notes") }
        if edits.contains(where: Self.tuningFields.contains) { try applyTuning(args, to: &b) }
        if let append { b.notes = [b.notes, append].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
        model.updateBookmark(b)
        return ["bookmark": bookmarkJSON(b)]
    }

    func deleteBookmark(_ args: ToolArguments) throws -> [String: JSONValue] {
        let b = try bookmark(args)
        guard b.isFromAgent else {
            throw ToolError("That bookmark is the owner's: agents may delete only bookmarks an agent added.")
        }
        model.deleteBookmark(b.id)
        return ["deleted": .string(b.id.uuidString)]
    }
}
