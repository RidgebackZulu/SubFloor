import Foundation

/// Squelch of one PSK31 decoding path (BPSK or QPSK) on a per-symbol fit metric in [-1, 1]
/// (cos 2φ or cos 4φ).
///
/// Opens when all of these hold: a carrier line is present, the average fit is high and the last
/// `run` symbols each fitted, the envelope carries the 31.25 Hz symbol clock, few recent symbols fell
/// near zero amplitude, and the confident symbols are balanced over the constellation (a PSK31
/// signal reverses; a keyed or steady carrier sits on one point). Closes when the average fit falls,
/// the clock or the balance goes, or too many symbols fall near zero. Losing the carrier line only
/// closes it if the fit has dropped too: a strong neighbour can hide the line of a signal that still
/// decodes cleanly.
struct PSK31Squelch {
    private(set) var isOpen = false
    /// Symbol index at which it last opened.
    private(set) var openedAt = Int.min
    private var average: Float = 0
    private var goodRun = 0
    var level: Float { average }

    mutating func forceClose() { isOpen = false; average = min(average, 0); goodRun = 0 }

    /// - Parameters:
    ///   - lowSymbols: how many of the last 32 symbols fell near zero amplitude.
    ///   - clocked: the envelope carries the 31.25 Hz symbol clock.
    ///   - balanced: the recent confident symbols are not all on one constellation point.
    ///   - symbol: index of the symbol `q` belongs to.
    mutating func update(_ q: Float, present: Bool, lowSymbols: Int, clocked: Bool, balanced: Bool, symbol: Int) {
        average += (q - average) * Self.alpha
        goodRun = q > Self.good ? goodRun + 1 : 0
        if isOpen {
            let lineLost = !present && average < Self.holdWithoutLine
            if lineLost || !clocked || !balanced || average < Self.close || lowSymbols > Self.lowToClose {
                isOpen = false
            }
        } else if present && clocked && balanced && average > Self.open && goodRun >= Self.run
                    && lowSymbols <= Self.lowToOpen {
            isOpen = true
            openedAt = symbol
        }
    }

    private static let alpha: Float = 1.0 / 12
    private static let open: Float = 0.5
    private static let close: Float = 0.3
    /// Without a carrier line the squelch stays open only while the fit is at least this good.
    private static let holdWithoutLine: Float = 0.7
    private static let good: Float = 0.5
    private static let run = 8
    private static let lowToOpen = 4
    private static let lowToClose = 8
}

/// Counts which constellation point each recent confident symbol sat on, over a sliding window.
struct ConstellationBalance {
    private var ring: [Int8]
    private var head = 0
    private var counts = [Int](repeating: 0, count: 4)
    private let window: Int

    init(window: Int = 64) {
        self.window = window
        ring = [Int8](repeating: -1, count: window)
    }

    /// `point` is 0...3 for a confident symbol on that point, or nil.
    mutating func push(_ point: Int?) {
        let old = ring[head]
        if old >= 0 { counts[Int(old)] -= 1 }
        let new = Int8(point ?? -1)
        ring[head] = new
        if new >= 0 { counts[Int(new)] += 1 }
        head = (head + 1) % window
    }

    /// At least `minimum` confident symbols, and at least `fraction` of them off the busiest point.
    func isBalanced(minimum: Int = 8, fraction: Double = 0.1) -> Bool {
        let total = counts.reduce(0, +)
        guard total >= minimum else { return false }
        return Double(total - counts.max()!) >= fraction * Double(total)
    }

    mutating func reset() {
        for i in ring.indices { ring[i] = -1 }
        for i in counts.indices { counts[i] = 0 }
        head = 0
    }
}
