import Foundation

public enum WindowKind: String, CaseIterable, Codable, Sendable {
    case blackmanHarris, hann, flatTop

    public var label: String {
        switch self {
        case .blackmanHarris: "Blackman-Harris"
        case .hann: "Hann"
        case .flatTop: "Flat-top"
        }
    }

    public func coefficients(count n: Int) -> [Float] {
        let m = Double(max(n - 1, 1))
        var out = [Float]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let x = 2 * Double.pi * Double(i) / m
            out.append(Float(value(at: x)))
        }
        return out
    }

    private func value(at x: Double) -> Double {
        switch self {
        case .hann:
            return 0.5 - 0.5 * cos(x)
        case .blackmanHarris:
            let a0: Double = 0.35875
            let a1: Double = 0.48829 * cos(x)
            let a2: Double = 0.14128 * cos(2 * x)
            let a3: Double = 0.01168 * cos(3 * x)
            return a0 - a1 + a2 - a3
        case .flatTop:
            let a0: Double = 0.21557895
            let a1: Double = 0.41663158 * cos(x)
            let a2: Double = 0.277263158 * cos(2 * x)
            let a3: Double = 0.083578947 * cos(3 * x)
            let a4: Double = 0.006947368 * cos(4 * x)
            return a0 - a1 + a2 - a3 + a4
        }
    }
}
