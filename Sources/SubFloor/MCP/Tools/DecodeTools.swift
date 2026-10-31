import Foundation
import Modems
import SubFloorCore
import Transcription

/// The decoder switch, and what it has decoded: the FT8/WSPR history and the live CW/PSK31 rows.
extension SubFloorTools {
    static var decodeTools: [SubFloorTool] {
        let modes = ModeID.allCases.map(\.rawValue)
        return [
            SubFloorTool("set_decoder", title: "Set decoder", readOnly: false, description: """
                Turn the decoder on in one mode, or "off". It decodes what the receiver's passband holds, so tune \
                first (FT8 on 20 m: tune to 14.074 MHz in usb). FT8 and WSPR need a live source, not an IQ \
                recording. Modes SubFloor does not offer yet are refused. Returns {decoder}.
                """, properties: [
                    "mode": .enumSchema(["ft8", "wspr", "cw", "psk31", "rtty", "off"], "The decoder's mode, or off."),
                ], required: ["mode"]) { t, args, _ in try t.setDecoder(args) },

            SubFloorTool("get_decodes", title: "Get decodes", readOnly: true, description: """
                What the decoder has heard in the last since_minutes (default 15, up to 10080), optionally in one \
                mode: decodes, the FT8/WSPR messages, newest first, each {utc, mode, hz, audio_hz, snr_db, message, \
                kind, from, to, grid}, at most limit (default 200, up to 1000); and live, the CW/PSK31 signals \
                being decoded now {hz, mode, snr_db, text, cursor}. Returns {decodes, live, truncated}.
                """, properties: [
                    "since_minutes": .schema("number", "How far back (default 15 minutes)."),
                    "mode": .enumSchema(modes, "Only this mode."),
                    "limit": .schema("integer", "At most this many decodes (default 200, up to 1000)."),
                ]) { t, args, _ in try await t.decodes(args) },

            SubFloorTool("get_ft8_stations", title: "Get FT8 stations", readOnly: true, description: """
                The stations heard calling in FT8 in the last hours (default 24, up to 168), most recently heard \
                first: call, grid with its centre lat/lon (null if none was sent), best_snr_db, last_heard, \
                count and bands. Returns {stations}.
                """, properties: [
                    "hours": .schema("number", "How far back (default 24, up to 168)."),
                ]) { t, args, _ in try await t.ft8Stations(args) },
        ]
    }

    func setDecoder(_ args: ToolArguments) throws -> [String: JSONValue] {
        let offered = ModemControl.offeredModes
        let choice = try args.required("mode") { try args.choice($0, ModeID.allCases.map(\.rawValue) + ["off"]) }
        let mode = ModeID(rawValue: choice)
        if let mode, !offered.contains(mode) {
            throw ToolError("SubFloor does not offer \(mode.label) yet. Offered: \(offered.map(\.rawValue).joined(separator: ", ")), or off.")
        }
        model.setModemMode(mode)
        var r: [String: JSONValue] = ["decoder": .string(model.modemSettings.mode?.rawValue ?? "off")]
        if let mode, mode.isSlotMode, !model.modemSettings.slotModesEnabled {
            r["note"] = .string("An IQ recording is playing: \(mode.label) decodes only from a live source.")
        }
        return r
    }

    func decodes(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let minutes = try args.double("since_minutes", default: 15, in: 0...10_080)
        let mode = try args.choice("mode", ModeID.allCases.map(\.rawValue))
        let limit = try args.int("limit", default: 200, in: 1...1_000)
        let history = model.decodeHistory, since = Date().addingTimeInterval(-minutes * 60)
        let found = await offMain { history.decodes(since: since, mode: mode) }
        let box = model.modemBox
        let live = model.decodeLog.liveRows.filter { row in mode == nil || row.mode?.rawValue == mode }
        return [
            "decodes": .array(found.prefix(limit).map { d in
                .object(["utc": .time(d.time), "mode": .string(d.mode), "hz": .hz(d.rfHz), "audio_hz": .hz(d.audioHz),
                         "snr_db": .db(d.snrDb), "message": .string(d.message), "kind": .string(d.kind),
                         "from": d.from.map { .string($0) }.orNull, "to": d.to.map { .string($0) }.orNull,
                         "grid": d.grid.map { .string($0) }.orNull])
            }),
            "truncated": .bool(found.count > limit),
            "live": .array(live.map { row in
                .object(["hz": .hz(box.rfHz(forAudio: row.frequencyHz)), "mode": row.mode.map { .string($0.rawValue) }.orNull,
                         "snr_db": .db(row.snrDb), "text": .string(row.recentText), "cursor": .bool(row.isCursor)])
            }),
        ]
    }

    func ft8Stations(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let hours = try args.double("hours", default: 24, in: 0...168)
        let history = model.decodeHistory, since = Date().addingTimeInterval(-hours * 3_600)
        let stations = await offMain { history.stations(since: since, mode: ModeID.ft8.rawValue) }
        return ["stations": .array(stations.map { s in
            .object(["call": .string(s.call), "grid": s.grid.map { .string($0) }.orNull,
                     "lat": s.lat.map { .num($0) }.orNull, "lon": s.lon.map { .num($0) }.orNull,
                     "best_snr_db": .db(s.bestSnrDb), "last_heard": .time(s.lastHeard), "count": .number(Double(s.count)),
                     "bands": .array(s.bands.map { .string($0) })])
        })]
    }
}
