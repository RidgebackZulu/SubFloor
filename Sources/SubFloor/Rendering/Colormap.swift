import simd

enum Colormap: String, CaseIterable, Codable, Sendable {
    case turbo, viridis, grayscale

    var label: String { rawValue.capitalized }

    func lut() -> [SIMD4<Float>] {
        (0..<256).map { i in
            let t = Float(i) / 255
            switch self {
            case .turbo: return Self.turbo(t)
            case .viridis: return Self.viridis(t)
            case .grayscale: return SIMD4(t, t, t, 1)
            }
        }
    }

    private static func turbo(_ x: Float) -> SIMD4<Float> {
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        return SIMD4(simd_clamp(r, 0, 1), simd_clamp(g, 0, 1), simd_clamp(b, 0, 1), 1)
    }

    private static func viridis(_ t: Float) -> SIMD4<Float> {
        let c0 = SIMD3<Float>(0.2777273272234177, 0.005407344544966578, 0.3340998053353061)
        let c1 = SIMD3<Float>(0.1050930431085774, 1.404613529898575, 1.384590162594685)
        let c2 = SIMD3<Float>(-0.3308618287255563, 0.214847559468213, 0.09509516302823659)
        let c3 = SIMD3<Float>(-4.634230498983486, -5.799100973351585, -19.33244095627987)
        let c4 = SIMD3<Float>(6.228269936347081, 14.17993336680509, 56.69055260068105)
        let c5 = SIMD3<Float>(4.776384997670288, -13.74514537774601, -65.35303263337234)
        let c6 = SIMD3<Float>(-5.435455855934631, 4.645852612178535, 26.3124352495832)
        var c = c6
        for k in [c5, c4, c3, c2, c1, c0] { c = k + t * c }
        let clamped = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD4(clamped, 1)
    }
}
