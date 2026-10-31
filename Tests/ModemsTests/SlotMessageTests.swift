import Foundation
import Testing
@testable import Modems

struct SlotMessageTests {
    @Test func cqWithGrid() {
        let m = SlotMessage.parse("CQ K1ABC FN42", mode: .ft8)
        #expect(m.kind == .cq)
        #expect(m.from == "K1ABC")
        #expect(m.to == nil)
        #expect(m.grid == "FN42")
    }

    @Test func cqWithModifier() {
        let dx = SlotMessage.parse("CQ DX K1ABC FN42", mode: .ft8)
        #expect(dx.kind == .cq)
        #expect(dx.from == "K1ABC")
        #expect(dx.grid == "FN42")
        let pota = SlotMessage.parse("CQ POTA W1AW FN31", mode: .ft8)
        #expect(pota.from == "W1AW")
        #expect(pota.grid == "FN31")
    }

    @Test func callPairWithGrid() {
        let m = SlotMessage.parse("W9XYZ K1ABC FN42", mode: .ft8)
        #expect(m.kind == .call)
        #expect(m.to == "W9XYZ")
        #expect(m.from == "K1ABC")
        #expect(m.grid == "FN42")
    }

    @Test func reports() {
        let report = SlotMessage.parse("W9XYZ K1ABC -12", mode: .ft8)
        #expect(report.kind == .report)
        #expect(report.report == "-12")
        let roger = SlotMessage.parse("W9XYZ K1ABC R-07", mode: .ft8)
        #expect(roger.kind == .rogerReport)
        #expect(roger.report == "-07")
        #expect(SlotMessage.parse("W9XYZ K1ABC RR73", mode: .ft8).kind == .rr73)
        #expect(SlotMessage.parse("W9XYZ K1ABC RRR", mode: .ft8).kind == .rrr)
        #expect(SlotMessage.parse("W9XYZ K1ABC 73", mode: .ft8).kind == .seventyThree)
    }

    @Test func rr73IsNotAGrid() {
        let m = SlotMessage.parse("W9XYZ K1ABC RR73", mode: .ft8)
        #expect(m.grid == nil)
        #expect(m.to == "W9XYZ")
        #expect(m.from == "K1ABC")
    }

    @Test func wsprMessage() {
        let m = SlotMessage.parse("K1ABC FN42 37", mode: .wspr)
        #expect(m.kind == .wspr)
        #expect(m.from == "K1ABC")
        #expect(m.grid == "FN42")
        #expect(m.report == "37")
    }

    @Test func hashedCall() {
        let m = SlotMessage.parse("<PJ4/K1ABC> W9XYZ", mode: .ft8)
        #expect(m.to == "PJ4/K1ABC")
        #expect(m.from == "W9XYZ")
    }

    @Test func freeTextIsOther() {
        let m = SlotMessage.parse("TNX BOB 73 GL", mode: .ft8)
        #expect(m.kind == .other)
        #expect(m.from == nil)
    }

    @Test func lowercaseIsNormalised() {
        let m = SlotMessage.parse("cq k1abc fn42", mode: .ft8)
        #expect(m.from == "K1ABC")
        #expect(m.grid == "FN42")
    }

    @Test func gridCenters() throws {
        let fn42 = try #require(Maidenhead.center("FN42"))
        #expect(abs(fn42.lat - 42.5) < 0.01)
        #expect(abs(fn42.lon - -71.0) < 0.01)
        let jo65 = try #require(Maidenhead.center("JO65aa"))
        #expect(abs(jo65.lat - 55.0208) < 0.001)
        #expect(abs(jo65.lon - 12.0417) < 0.001)
        // The subsquare letters are longitude then latitude: "b" is the second 2.5' row.
        let jo65ab = try #require(Maidenhead.center("JO65ab"))
        #expect(abs(jo65ab.lat - 55.0625) < 0.001)
        #expect(abs(jo65ab.lon - 12.0417) < 0.001)
        #expect(Maidenhead.center("ZZ99") == nil)
        #expect(Maidenhead.center("FN4") == nil)
    }

    @Test func gridAndCallsignShapes() {
        #expect(Maidenhead.isGrid("fn42"))
        #expect(Maidenhead.isGrid("JO65AB"))
        #expect(!Maidenhead.isGrid("RR73"))
        #expect(!Maidenhead.isGrid("FN4"))
        #expect(SlotMessage.isCallsign("K1ABC"))
        #expect(SlotMessage.isCallsign("<PJ4/K1ABC>"))
        #expect(!SlotMessage.isCallsign("CQ"))
        #expect(!SlotMessage.isCallsign("TNX"))
        #expect(!SlotMessage.isCallsign("ABCDEFGHIJK1M"))
    }
}
