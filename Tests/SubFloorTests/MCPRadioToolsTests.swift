import DSPCore
import Foundation
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// Lines appended from several tasks on the main actor.
@MainActor
private final class Lines {
    var lines: [String] = []
}

/// The radio, cursor, spectrum and bookmark tools, called as an agent would, on a demo-source model.
@MainActor
struct MCPRadioToolsTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10))
    }

    private func call(_ tools: SubFloorTools, _ name: String, _ arguments: [String: JSONValue] = [:],
                      client: String = "test-agent 1.0") async -> MCPToolResult {
        await tools.call(name, arguments: arguments, client: client)
    }

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return condition() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func statusReportsTheTuning() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        tools.connectedClients = { ["claude-code 2.1"] }
        m.setMode(.lsb)
        m.tune(to: 7_150_000)
        let r = await call(tools, "get_status")
        #expect(!r.isError)
        let s = r.structured
        #expect(s?["ok"]?.bool == true)
        #expect(s?["vfo_hz"]?.double == m.vfoHz)
        #expect(s?["mode"]?.string == "lsb")
        #expect(s?["hamitup"]?["on"]?.bool == m.upconverter.enabled)
        #expect(s?["hamitup"]?["lo_hz"]?.double == m.upconverter.loHz)
        #expect(s?["running"]?.bool == false)
        #expect(s?["mcp_clients"]?.array == [.string("claude-code 2.1")])
        // The text is the JSON alone, with no summary line before it.
        #expect(JSONValue.decode(Data(r.content.utf8)) == s)
    }

    @Test func unknownToolsFail() async {
        let tools = SubFloorTools(model: makeModel())
        let r = await call(tools, "no_such_tool")
        #expect(r.isError)
        #expect(r.content == "Unknown tool no_such_tool")
    }

    @Test func descriptorsAreUniqueAndMarkTheReaders() {
        let tools = SubFloorTools(model: makeModel()).tools
        let names = tools.map(\.name)
        #expect(Set(names).count == names.count)
        let readers = Set(tools.filter(\.readOnly).map(\.name))
        #expect(readers == ["get_status", "get_cursor", "get_spectrum", "list_bookmarks", "list_recordings",
                            "get_transcript", "search_transcripts", "get_decodes", "get_ft8_stations"])
        for name in ["start_radio", "stop_radio", "tune", "set_squelch", "add_bookmark", "update_bookmark",
                     "delete_bookmark", "listen", "start_recording", "stop_recording", "set_auto_record", "set_decoder"] {
            #expect(names.contains(name))
        }
    }

    /// Strict clients refuse a whole tool list over one schema they don't take.
    @Test func schemasSuitStrictClients() {
        /// Every `additionalProperties` key and array-valued `type`, anywhere in `v`.
        func offences(_ v: JSONValue, at path: String) -> [String] {
            switch v {
            case .object(let o):
                var found: [String] = []
                if o["additionalProperties"] != nil { found.append("\(path).additionalProperties") }
                if case .array? = o["type"] { found.append("\(path).type is an array") }
                for (k, child) in o { found += offences(child, at: "\(path).\(k)") }
                return found
            case .array(let a): return a.enumerated().flatMap { offences($1, at: "\(path)[\($0)]") }
            default: return []
            }
        }
        for tool in SubFloorTools(model: makeModel()).tools {
            let schema = tool.inputSchema
            #expect(schema["type"]?.string == "object", "\(tool.name)")
            #expect(offences(schema, at: tool.name) == [])
            if let required = schema["required"] { #expect(required.array?.isEmpty == false, "\(tool.name)") }
            for (key, property) in schema["properties"]?.object ?? [:] {
                #expect(property["type"] != nil || property["anyOf"] != nil, "\(tool.name).\(key)")
            }
        }
        // A frequency still takes a number or a string.
        let tune = SubFloorTools(model: makeModel()).tools.first { $0.name == "tune" }!
        #expect(tune.inputSchema["properties"]?["frequency"]?["anyOf"]?.array?.count == 2)
        #expect(tune.inputSchema["required"]?.array == [.string("frequency")])
    }

    @Test func tuneAcceptsStringsAndModes() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "tune", ["frequency": .string("7.200 MHz"), "mode": .string("lsb")])
        #expect(!r.isError)
        #expect(m.vfoHz == 7_200_000)
        #expect(m.mode == .lsb)
        #expect(r.structured?["vfo_hz"]?.double == 7_200_000)
        #expect(r.structured?["mode"]?.string == "lsb")
        #expect(r.structured?["bandwidth_hz"]?.double == m.bandwidthHz)

        let wide = await call(tools, "tune", ["frequency": .number(7_210_000), "bandwidth_hz": .number(3_000)])
        #expect(!wide.isError)
        #expect(m.vfoHz == 7_210_000 && m.mode == .lsb && m.bandwidthHz == 3_000)
    }

    @Test func tuneRejectsUnreachableFrequencies() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        m.tune(to: 14_074_000)
        for bad: JSONValue in [.string("abc"), .number(-5), .number(5e9)] {
            let r = await call(tools, "tune", ["frequency": bad])
            #expect(r.isError, "\(bad)")
            #expect(m.vfoHz == 14_074_000)
        }
        let r = await call(tools, "tune", ["frequency": .number(5e9)])
        #expect(r.content.contains("outside what the RSP1B can tune (1 kHz – 2 GHz)"))
        // With HamItUp on, the top of the range comes down by its LO.
        m.setUpconverter(true)
        let high = await call(tools, "tune", ["frequency": .string("1.95 GHz")])
        #expect(high.isError)
        #expect(m.vfoHz == 14_074_000)
        let missing = await call(tools, "tune")
        #expect(missing.isError)
        #expect(missing.content.contains("frequency"))
    }

    @Test func hamitupAutoUsesTheUpconverterOnHF() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        #expect(!m.upconverter.enabled)
        let hf = await call(tools, "tune", ["frequency": .number(6_925_000), "hamitup": .string("auto")])
        #expect(!hf.isError)
        #expect(m.upconverter.enabled)
        #expect(m.vfoHz == 6_925_000)
        #expect(hf.structured?["hamitup"]?["on"]?.bool == true)

        // Above 30 MHz auto leaves it as it was, on or off.
        _ = await call(tools, "tune", ["frequency": .string("144.39 MHz"), "hamitup": .string("auto")])
        #expect(m.upconverter.enabled)
        #expect(m.vfoHz == 144_390_000)
        m.setUpconverter(false)
        _ = await call(tools, "tune", ["frequency": .string("144.39 MHz"), "hamitup": .string("auto")])
        #expect(!m.upconverter.enabled)

        _ = await call(tools, "tune", ["frequency": .number(6_925_000), "hamitup": .string("on")])
        #expect(m.upconverter.enabled)
        _ = await call(tools, "tune", ["frequency": .number(6_925_000), "hamitup": .string("off")])
        #expect(!m.upconverter.enabled)
        let bad = await call(tools, "tune", ["frequency": .number(6_925_000), "hamitup": .string("maybe")])
        #expect(bad.isError)
    }

    @Test func squelchTool() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "set_squelch", ["enabled": .bool(true), "level_dbfs": .number(-62)])
        #expect(!r.isError)
        #expect(m.squelchEnabled)
        #expect(m.squelchDb == -62)
        #expect(r.structured?["on"]?.bool == true)
        #expect(r.structured?["level_dbfs"]?.double == -62)
        #expect(r.structured?["signal_dbfs"] != nil)

        // The level is clamped to the slider's range; a missing switch leaves the switch.
        _ = await call(tools, "set_squelch", ["level_dbfs": .number(-500)])
        #expect(m.squelchDb == -140)
        #expect(m.squelchEnabled)
        _ = await call(tools, "set_squelch", ["enabled": .bool(false)])
        #expect(!m.squelchEnabled)
        #expect(m.squelchDb == -140)
        let bad = await call(tools, "set_squelch", ["enabled": .string("yes please")])
        #expect(bad.isError)
    }

    @Test func cursorRemembersTheMouse() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        m.hover(at: CGPoint(x: 0.3, y: 0.1))
        let hovered = m.hover!.hz
        m.hover(at: nil)
        #expect(m.hover == nil)
        #expect(m.lastPointer?.hz == hovered)

        let r = await call(tools, "get_cursor")
        #expect(!r.isError)
        let mouse = r.structured?["mouse"]
        #expect(mouse?["hz"]?.double == hovered.rounded())
        #expect((mouse?["seconds_ago"]?.double ?? -1) >= 0)
        #expect(mouse?["decodes_near"]?.array == [])
        #expect(r.structured?["decoder_cursor"] == .null)
        #expect(r.structured?["vfo"]?["hz"]?.double == m.vfoHz)
    }

    @Test func cursorFindsTheNearestBookmark() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        m.setMode(.usb)
        m.tune(to: 7_133_000)   // no default bookmark nearby
        let id = m.addBookmark(Bookmark(name: "Net", frequencyHz: 7_133_500, mode: .usb, bandwidthHz: 2_700))
        let r = await call(tools, "get_cursor")
        #expect(r.structured?["mouse"] == .null)
        #expect(r.structured?["vfo"]?["nearest_bookmark"]?["id"]?.string == id.uuidString)
        m.tune(to: 7_150_000)
        let far = await call(tools, "get_cursor")
        #expect(far.structured?["vfo"]?["nearest_bookmark"] == .null)
    }

    @Test func spectrumAfterTheDemoRuns() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        defer { m.shutdown() }
        let stopped = await call(tools, "get_spectrum")
        #expect(stopped.isError)
        #expect(stopped.content.contains("start_radio"))

        let started = await call(tools, "start_radio")
        #expect(!started.isError)
        #expect(started.structured?["running"]?.bool == true)
        #expect(started.structured?["source"]?.string == "demo")
        #expect(await eventually { m.spectrumSnapshot() != nil })

        let r = await call(tools, "get_spectrum", ["points": .number(64)])
        #expect(!r.isError, "\(r.content)")
        let levels = r.structured?["levels_dbfs"]?.array ?? []
        #expect(levels.count == 64)
        #expect(levels.allSatisfy { $0.double?.isFinite == true })
        #expect((r.structured?["bin_hz"]?.double ?? 0) > 0)
        #expect(r.structured?["peaks"]?.array != nil)
        // The current view by default.
        #expect(abs((r.structured?["from_hz"]?.double ?? 0) - m.viewport.lowerHz) < 1)
        #expect(abs((r.structured?["to_hz"]?.double ?? 0) - m.viewport.upperHz) < 1)

        let tiny = await call(tools, "get_spectrum", ["points": .number(2)])
        #expect(tiny.structured?["levels_dbfs"]?.array?.count == 16)
        let outside = await call(tools, "get_spectrum", ["from_hz": .number(m.centerHz + m.sampleRate),
                                                          "to_hz": .number(m.centerHz + 2 * m.sampleRate)])
        #expect(outside.isError)
        #expect(outside.content.contains("Tune within"))

        let stop = await call(tools, "stop_radio")
        #expect(stop.structured?["running"]?.bool == false)
        #expect(!m.isRunning)
    }

    @Test func peaksAreFoundInASyntheticSpectrum() {
        // A flat −100 dBFS floor with one 3-bin signal at −60 around bin 300 of 1024.
        var average = [Float](repeating: -100, count: 1024)
        average[299] = -66
        average[300] = -60
        average[301] = -64
        let snap = SpectrumSnapshot(centerHz: 10_000_000, spanHz: 1_024_000, average: average)
        let view = SpectrumSlice(snap, from: snap.lowerHz, to: snap.upperHz, points: 1024)
        #expect(view.levels.count == 1024)
        #expect(view.peaks.count == 1)
        let peak = view.peaks[0]
        #expect(peak.hz == snap.hz(ofBin: 300))
        #expect(peak.level == -60)
        #expect(peak.widthHz == 3_000)
    }

    @Test func agentBookmarksAreMarkedAndOwnedOnesProtected() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        let owners = m.bookmarks.first { $0.addedBy == nil }!

        let added = await call(tools, "add_bookmark",
                               ["name": .string("Numbers station"), "frequency": .string("6.925 MHz"),
                                "mode": .string("usb"), "group": .string("Agent finds"),
                                "notes": .string("heard 0400Z")],
                               client: "claude-code 2.1")
        #expect(!added.isError, "\(added.content)")
        let idText = added.structured?["id"]?.string ?? ""
        let id = UUID(uuidString: idText)!
        let agents = m.bookmarks.first { $0.id == id }!
        #expect(agents.addedBy == "claude-code 2.1")
        #expect(agents.frequencyHz == 6_925_000 && agents.mode == .usb && agents.notes == "heard 0400Z")

        let rename = await call(tools, "update_bookmark", ["id": .string(owners.id.uuidString), "name": .string("x")])
        #expect(rename.isError)
        #expect(rename.content == "That bookmark is the owner's: only append_notes is allowed.")
        #expect(m.bookmarks.first { $0.id == owners.id }?.name == owners.name)

        let note = await call(tools, "update_bookmark", ["id": .string(owners.id.uuidString),
                                                          "append_notes": .string("heard 0500Z")])
        #expect(!note.isError, "\(note.content)")
        let noted = m.bookmarks.first { $0.id == owners.id }!
        #expect(noted.notes?.hasSuffix("heard 0500Z") == true)
        #expect(noted.addedBy == nil)

        // Another agent may tidy an agent's bookmark; who added it stays.
        let edit = await call(tools, "update_bookmark", ["id": .string(idText), "name": .string("Numbers (E07?)")],
                              client: "codex 0.5")
        #expect(!edit.isError)
        #expect(m.bookmarks.first { $0.id == id }?.name == "Numbers (E07?)")
        #expect(m.bookmarks.first { $0.id == id }?.addedBy == "claude-code 2.1")

        let list = await call(tools, "list_bookmarks", ["query": .string("numbers")])
        #expect(list.structured?["bookmarks"]?.array?.count == 1)
        let grouped = await call(tools, "list_bookmarks", ["group": .string("agent finds")])
        #expect(grouped.structured?["bookmarks"]?.array?.first?["added_by"]?.string == "claude-code 2.1")

        let delOwner = await call(tools, "delete_bookmark", ["id": .string(owners.id.uuidString)])
        #expect(delOwner.isError)
        #expect(m.bookmarks.contains { $0.id == owners.id })
        let delAgent = await call(tools, "delete_bookmark", ["id": .string(idText)])
        #expect(!delAgent.isError)
        #expect(!m.bookmarks.contains { $0.id == id })
        let again = await call(tools, "delete_bookmark", ["id": .string(idText)])
        #expect(again.isError)
    }

    @Test func mutatingToolsRunOneAtATime() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        m.tune(to: 14_074_000)
        let log = Lines()
        let release = AsyncStream<Void>.makeStream()

        // A probe holds the radio while two tunes queue behind it.
        let probe = Task { @MainActor in
            await tools.withRadio {
                log.lines.append("probe start")
                for await _ in release.stream { break }
                log.lines.append("probe end")
            }
        }
        #expect(await eventually { log.lines == ["probe start"] })
        let first = Task { @MainActor in
            _ = await tools.call("tune", arguments: ["frequency": .number(7_100_000)], client: "a")
            log.lines.append("tune 7.1 done, vfo \(Int(m.vfoHz))")
        }
        #expect(await eventually { tools.radioWaiting == 1 })
        let second = Task { @MainActor in
            _ = await tools.call("tune", arguments: ["frequency": .number(7_200_000)], client: "b")
            log.lines.append("tune 7.2 done, vfo \(Int(m.vfoHz))")
        }
        #expect(await eventually { tools.radioWaiting == 2 })
        // Read-only tools don't wait.
        let status = await call(tools, "get_status")
        #expect(status.structured?["vfo_hz"]?.double == 14_074_000)
        #expect(m.vfoHz == 14_074_000)

        release.continuation.yield()
        await probe.value
        await first.value
        await second.value
        #expect(log.lines == ["probe start", "probe end", "tune 7.1 done, vfo 7100000", "tune 7.2 done, vfo 7200000"])
        #expect(tools.radioWaiting == 0)
        #expect(m.vfoHz == 7_200_000)
    }
}
