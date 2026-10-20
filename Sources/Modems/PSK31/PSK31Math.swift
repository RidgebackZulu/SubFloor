import simd

/// Complex helpers on SIMD2 (x = real, y = imaginary) for the PSK31 decoder.
@inline(__always) func cmul(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
}

@inline(__always) func rotate(_ a: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
    cmul(a, SIMD2(cos(angle), sin(angle)))
}

@inline(__always) func wrap(_ a: Float) -> Float {
    var x = a
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}
