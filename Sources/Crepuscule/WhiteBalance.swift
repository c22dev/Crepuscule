// Crepuscule - WhiteBalance.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public enum WhiteBalance {
    static let d65 = SIMD2<Float>(0x1.40346ep-2, 0x1.50e56p-2)
    static let pivot = SIMD2<Float>(Float(bitPattern: 0x3e33c610), Float(bitPattern: 0x3bad77ec))
    static let cosA = Float(bitPattern: 0x3f6820a9), sinA = Float(bitPattern: 0xbed7e56c)
    static let origin = SIMD2<Float>(0.035, 0.01)
    static let scale = SIMD2<Float>(1.24, 1.0)

    static let locus: [(Float, Float)] = rawLocus.map {
        (Float(bitPattern: UInt32(truncatingIfNeeded: $0)), Float(bitPattern: UInt32($0 >> 32)))
    }
    private static let rawLocus: [UInt64] = [
        0x3d8def1bbcc8bb18, 0x3dab8652ba92e4cb, 0x3dc91d8a3cb65e7f, 0x3de6b4c13d3af5a5,
        0x3e0225fc3d8d5e06, 0x3e10f1983dbd4138, 0x3e1fbd333ded246b, 0x3e2e88cf3e0e83cf,
        0x3e3d546b3e267569, 0x3e4a67d13e3db06d, 0x3e55c0c93e5408aa, 0x3e5f6e4c3e6990d6,
        0x3e67ce1c3e7e5f18, 0x3e6f0b1b3e897e14, 0x3e7501273e936045, 0x3e79e9e83e9d179a,
        0x3e7db72f3ea67ad2, 0x3e80402d3eafa9e4, 0x3e810eb83eb89174, 0x3e8156233ec14012,
        0x3e811bb33ec9a447, 0x3e805d963ed1c8f7, 0x3e7e27353ed9c757, 0x3e7a7c213ee1713b,
        0x3e75aee23ee8da60, 0x3e6fb4353ef001ad, 0x3e68822a3ef6d5ad, 0x3e5f94033efd4b6a,
        0x3e55546d3f01b8bf, 0x3e4b14d83f04cbc8, 0x3e40d5423f07ded2, 0x3e3695ad3f0af1dc,
        0x3e2c56173f0e04e6,
    ]

    static func locusY(_ x: Float) -> Float {
        var a = locus[0], b = locus[1]
        if x >= locus[0].0 {
            if x > locus[locus.count - 1].0 {
                a = locus[locus.count - 2]; b = locus[locus.count - 1]
            } else {
                for i in 0..<locus.count {
                    if x == locus[i].0 { return locus[i].1 }
                    if x < locus[i].0 { a = locus[i - 1]; b = locus[i]; break }
                }
            }
        }
        return a.1 + ((x - a.0) / (b.0 - a.0)) * (b.1 - a.1)
    }

    static func warp(_ xy: SIMD2<Float>) -> SIMD2<Float> {
        let v = xy - pivot
        let u = cosA * v.x - sinA * v.y
        let w = (sinA * v.x + cosA * v.y) * (0.19 / locusY(u))
        return SIMD2(u, w) * scale + origin
    }

    static func unwarp(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = (p - origin) / scale
        let w = (locusY(q.x) / 0.19) * q.y
        return SIMD2(q.x * cosA + w * sinA, w * cosA - q.x * sinA) + pivot
    }

    public static func gains(colorTemp: Float, tint: Float) -> (red: Float, green: Float, blue: Float) {
        let xy = unwarp(warp(d65) + SIMD2(colorTemp, tint))
        let a = xy.x / xy.y, b = (1 - xy.x - xy.y) / xy.y
        let g = a * Float(bitPattern: 0xbf7821d1) + Float(bitPattern: 0x3ff0211f) + b * Float(bitPattern: 0x3d2a36a0)
        let r = a * 3.2404542 - 1.5371385 - b * 0.49853140
        let bl = a * 0.055643398 - 0.20402589 + b * 1.0572252
        return (r / g, 1, bl / g)
    }
}
