import Testing
import Foundation
import DSPCore
@testable import Modems

private let text = "the quick brown fox JUMPS over the lazy dog 0123456789 CQ CQ DE W1AW PSE K"
private let other = "CQ CQ CQ DE G3PLX G3PLX K RRR TU 73 ES GL QRZ? 599 5NN NAME HR IS PETER QTH KENDAL"
private func burst(_ a: [Float]) -> Double { let t = a[12_000...]; return t.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(t.count) }
private final class Box<T>: @unchecked Sendable { var v: [T?]; let l = NSLock(); init(_ n: Int) { v = .init(repeating: nil, count: n) } }
private func par<T>(_ n: Int, _ f: @Sendable (Int) -> T) -> [T] {
    let b = Box<T>(n); DispatchQueue.concurrentPerform(iterations: n) { i in let r = f(i); b.l.lock(); b.v[i] = r; b.l.unlock() }; return b.v.map { $0! }
}
private func dec(_ a: [Float], _ f: Double = 1_500) -> (String, Bool) {
    let d = PSK31SignalDecoder(frequencyHz: f); var o = ""; var q = false
    for s in stride(from: 0, to: a.count, by: 1_024) { o += a[s..<min(s + 1_024, a.count)].withUnsafeBufferPointer { d.process($0) }; if d.submode == "QPSK31" { q = true } }
    return (o, q)
}
private func acc(_ o: String, _ t: String = text) -> Double { ModemTestSignals.characterAccuracy(sent: t, received: o.trimmingCharacters(in: .whitespacesAndNewlines)) }
private func stats(_ x: [Double]) -> String { String(format: "mean %.3f min %.3f below0.95 %d/%d", x.reduce(0, +) / Double(x.count), x.min()!, x.filter { $0 < 0.95 }.count, x.count) }

@Test func measureAll() {
    guard ProcessInfo.processInfo.environment["PSK31_MEASURE"] != nil else { return }
    let a = PSK31Encoder.audio(text: text, frequencyHz: 1_500)
    if ProcessInfo.processInfo.environment["PSK31_POOL"] != nil {
        let c = PSK31Encoder.audio(text: text, frequencyHz: 1_500); let p = burst(c)
        let r = par(2000) { i in dec(ModemTestSignals.awgn(c, snrDb: 10, seed: UInt64(20001 + i), signalPower: p)).0.trimmingCharacters(in: .whitespacesAndNewlines) }
        print("POOL: \(r.enumerated().filter { $0.1 != text }.map { "\(20001 + $0.0): \($0.1.prefix(8))" })")
        return
    }
    if ProcessInfo.processInfo.environment["PSK31_ONLY2"] != nil {
        for (q, snr) in [(false, 10.0), (false, 0.0), (true, 10.0), (true, 3.0)] {
            let c = PSK31Encoder.audio(text: text, frequencyHz: 1_500, qpsk: q); let p = burst(c)
            let r = par(200) { i in dec(ModemTestSignals.awgn(c, snrDb: snr, seed: UInt64(9001 + i), signalPower: p)).0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("ITEM2 qpsk=\(q) \(snr) dB: \(r.enumerated().filter { $0.1 != text }.map { "\(9001 + $0.0): \($0.1.prefix(8))" })")
        }
        return
    }
    // Held-out -10 dB.
    for off in [0.0, -12, 12] {
        let c = PSK31Encoder.audio(text: text, frequencyHz: 1_500 + off); let p = burst(c)
        print("HELD -10 dB off \(off): " + stats(par(20) { i in acc(dec(ModemTestSignals.awgn(c, snrDb: -10, seed: UInt64(1001 + i), signalPower: p)).0) }))
    }
    // Item 1 on reviewer seeds 6001-6040.
    for (off, snr) in [(50.0, 5.0), (-50.0, 5.0), (50.0, 30.0)] {
        let b = PSK31Encoder.audio(text: other, frequencyHz: 1_500 + off, leadInSeconds: 0.3)
        var m = [Float](repeating: 0, count: max(a.count, b.count)); for i in 0..<a.count { m[i] += a[i] }; for i in 0..<b.count { m[i] += Float(pow(10, 0.5)) * b[i] }
        let mm = m
        let r = par(40) { i in dec(ModemTestSignals.awgn(mm, snrDb: snr, seed: UInt64(6001 + i), signalPower: burst(a))).0 }
        let leaks = r.filter { o in ["G3PLX", "KENDAL", "PETER", "QTH"].contains { o.contains($0) } }.count
        print("ITEM1 neighbour \(off) Hz +10 dB, wanted \(snr) dB: " + stats(r.map { acc($0) }) + " leaks \(leaks)")
    }
    // Item 2 on 9001-9200.
    for (q, snr) in [(false, 10.0), (false, 0.0), (true, 10.0), (true, 3.0)] {
        let c = PSK31Encoder.audio(text: text, frequencyHz: 1_500, qpsk: q); let p = burst(c)
        let r = par(200) { i in dec(ModemTestSignals.awgn(c, snrDb: snr, seed: UInt64(9001 + i), signalPower: p)).0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let junk = r.filter { !$0.isEmpty && !text.hasPrefix(String($0.prefix(1))) }.count
        print("ITEM2 qpsk=\(q) \(snr) dB: exact \(r.filter { $0 == text }.count)/200, first char not 't' \(junk): \(r.filter { $0 != text }.map { String($0.prefix(12)) })")
    }
    // Item 3.
    for (off, snr) in [(-8.0, 5.0), (8.0, 5.0), (-8.0, 0.0), (8.0, 0.0), (-6.0, 5.0), (6.0, 5.0)] {
        let c = PSK31Encoder.audio(text: text, frequencyHz: 1_500 + off); let p = burst(c)
        let r = par(40) { i in dec(ModemTestSignals.awgn(c, snrDb: snr, seed: UInt64(6001 + i), signalPower: p)) }
        print("ITEM3 BPSK \(off) Hz \(snr) dB: falseQPSK \(r.filter { $0.1 }.count)/40, " + stats(r.map { acc($0.0) }))
    }
    var sent = ""
    while Double(PSK31Encoder.bits(for: sent).count - 32) / 31.25 < 41 { sent += (sent.isEmpty ? "" : " ") + text }
    let drift = PSK31Encoder.audio(text: sent, frequencyAt: { t in 1_490 + 0.5 * min(max(t - 1, 0), 40) }); let dp = burst(drift)
    print("ITEM3 drift 9301-9340: " + stats(par(40) { [sent] i in acc(dec(ModemTestSignals.awgn(drift, snrDb: 5, seed: UInt64(9301 + i), signalPower: dp)).0, sent) }))
    // Item 4.
    for (wpm, snr) in [(25.0, 0.0), (30.0, 0.0), (30.0, -5.0), (40.0, 0.0), (40.0, -5.0), (50.0, 0.0), (50.0, -5.0)] {
        let unit = Int(1.2 / wpm * 12_000); var k = [Bool](repeating: false, count: 6_000)
        while k.count < 240_000 { for e in MorseCode.timeline(for: "CQ CQ DE W1AW W1AW K TEST 5NN ") { k += Array(repeating: e.on, count: e.units * unit) } }
        let kk = k
        let cw = kk.enumerated().map { i, on in on ? Float(0.5 * sin(2 * Double.pi * 1_500 * Double(i) / 12_000)) : 0 }
        let r = par(40) { i in dec(ModemTestSignals.awgn(cw, snrDb: snr, seed: UInt64(6001 + i), signalPower: 0.125)).0 }
        print("ITEM4 CW \(wpm) WPM \(snr) dB: runs with text \(r.filter { !$0.isEmpty }.count)/40, chars \(r.map(\.count).reduce(0, +))")
    }
    // Inverted QPSK.
    let inv = PSK31Encoder.audio(text: text, qpsk: true, frequencyAt: { _ in 1_500 }, invertedSense: true); let ip = burst(inv)
    print("MINOR inverted QPSK +10 dB 6001-6040: " + stats(par(40) { i in acc(dec(ModemTestSignals.awgn(inv, snrDb: 10, seed: UInt64(6001 + i), signalPower: ip)).0) }))
    print("MINOR inverted QPSK 0 dB 6001-6040: " + stats(par(40) { i in acc(dec(ModemTestSignals.awgn(inv, snrDb: 0, seed: UInt64(6001 + i), signalPower: ip)).0) }))
    // Noise.
    let nr = par(40) { i in dec(ModemTestSignals.noise(seconds: 60, seed: UInt64(8001 + i))).0 }
    print("NOISE 40 x 60 s (8001-8040): chars \(nr.map(\.count).reduce(0, +))")
}
