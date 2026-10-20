import Foundation

/// Two-state maximum-likelihood sequence detector for BPSK through the PSK31 matched filter, whose
/// output is z[k] = A·a[k] + c·(a[k-1] + a[k+1]) + noise. Ungerboeck's metric for that channel is
/// Σ a[k]·z[k] − c·a[k]·a[k-1], so the state is the previous symbol. Register-exchange survivors.
struct BPSKSequenceDetector {
    static let depth = 12

    private var metric: (Float, Float) = (0, 0)   // state 0: previous symbol +1, state 1: −1
    private var survivor: (UInt32, UInt32) = (0, 0)
    private var pushed = 0

    struct Decision {
        /// Symbols at depth + 1, depth and depth − 1 (older to newer), as ±1.
        var previous: Float
        var current: Float
        var next: Float
    }

    mutating func push(_ z: Float, isi c: Float) -> Decision? {
        // New symbol +1: from +1 costs c, from −1 gains c.
        let plusFromPlus = metric.0 + z - c, plusFromMinus = metric.1 + z + c
        let minusFromPlus = metric.0 - z + c, minusFromMinus = metric.1 - z - c
        let newPlus: Float, newMinus: Float
        let survPlus: UInt32, survMinus: UInt32
        if plusFromPlus >= plusFromMinus { newPlus = plusFromPlus; survPlus = survivor.0 << 1 }
        else { newPlus = plusFromMinus; survPlus = survivor.1 << 1 }
        if minusFromPlus >= minusFromMinus { newMinus = minusFromPlus; survMinus = survivor.0 << 1 | 1 }
        else { newMinus = minusFromMinus; survMinus = survivor.1 << 1 | 1 }
        let top = max(newPlus, newMinus)
        metric = (newPlus - top, newMinus - top)
        survivor = (survPlus, survMinus)
        pushed += 1
        guard pushed > Self.depth + 1 else { return nil }
        let best = newPlus >= newMinus ? survPlus : survMinus
        func symbol(_ age: Int) -> Float { (best >> UInt32(age)) & 1 == 1 ? -1 : 1 }
        return Decision(previous: symbol(Self.depth + 1), current: symbol(Self.depth), next: symbol(Self.depth - 1))
    }
}
