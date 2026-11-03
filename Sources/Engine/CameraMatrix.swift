// Crepuscule - CameraMatrix.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

typealias M3 = [Double]
private func mul(_ a: M3, _ b: M3) -> M3 {
    var o = M3(repeating: 0, count: 9)
    for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { o[r * 3 + c] += a[r * 3 + k] * b[k * 3 + c] } } }
    return o
}
private func mulv(_ m: M3, _ v: [Double]) -> [Double] {
    (0..<3).map { m[$0 * 3] * v[0] + m[$0 * 3 + 1] * v[1] + m[$0 * 3 + 2] * v[2] }
}
private func diag(_ v: [Double]) -> M3 { [v[0], 0, 0, 0, v[1], 0, 0, 0, v[2]] }
private func inv(_ m: M3) -> M3? {
    let c0 = m[4] * m[8] - m[7] * m[5], c1 = m[5] * m[6] - m[8] * m[3], c2 = m[3] * m[7] - m[6] * m[4]
    let det = m[0] * c0 + m[1] * c1 + m[2] * c2
    guard abs(det) > 1e-12 else { return nil }
    let d = 1 / det
    return [c0 * d, (m[7] * m[2] - m[1] * m[8]) * d, (m[1] * m[5] - m[4] * m[2]) * d,
            c1 * d, (m[0] * m[8] - m[6] * m[2]) * d, (m[3] * m[2] - m[0] * m[5]) * d,
            c2 * d, (m[6] * m[1] - m[0] * m[7]) * d, (m[0] * m[4] - m[3] * m[1]) * d]
}
private func lerp(_ w: Double, _ a: M3, _ b: M3) -> M3 { zip(a, b).map { w * $0 + (1 - w) * $1 } }

private let identity: M3 = [1, 0, 0, 0, 1, 0, 0, 0, 1]
private let xyzD50ToLinearSRGB: M3 = [3.1338561, -1.6168667, -0.4906146, -0.9787684, 1.9161415, 0.033454, 0.0719453, -0.2289914, 1.4052427]
private let bradford: M3 = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
private let d50White = [0.96422, 1.0, 0.82521]

private func illuminantKelvin(_ code: Int) -> Double? {
    let table: [Int: Double] = [1: 5500, 2: 4200, 3: 2850, 4: 5500, 9: 5200, 10: 6000, 11: 7000, 12: 6430, 13: 5700,
                                14: 4200, 15: 3000, 17: 2850, 18: 4874, 19: 6774, 20: 5500, 21: 6500, 22: 7500, 23: 5000, 24: 3200]
    return table[code]
}
private func mccamy(_ xyz: [Double]) -> Double? {
    let sum = xyz[0] + xyz[1] + xyz[2]
    guard sum > 0 else { return nil }
    let n = (xyz[0] / sum - 0.332) / (0.1858 - xyz[1] / sum)
    return min(max(n * 6823.3 + n * n * 3525.0 + n * n * n * 449.0 + 5520.33, 1500), 25000)
}

func cameraToXYZ(_ m: DNGMetadata) -> M3? {
    let valid = (0..<2).map { m.colorMatrices[$0].count == 9 && illuminantKelvin(m.illuminants[$0]) != nil }
    guard valid[0] || valid[1] else { return nil }
    let ab = m.analogBalance.count == 3 ? diag(m.analogBalance) : identity
    var neutral = m.asShotNeutral
    if neutral.count != 3 || neutral.contains(where: { $0 <= 0 }) {
        let mult = m.asShotMultipliers
        neutral = (mult.count == 3 && !mult.contains { $0 <= 0 }) ? mult.map { 1 / $0 } : [1, 1, 1]
    }
    let single = !(valid[0] && valid[1])
    let ka = valid[0] ? illuminantKelvin(m.illuminants[0])! : illuminantKelvin(m.illuminants[1])!
    let kb = valid[1] ? illuminantKelvin(m.illuminants[1])! : ka
    let swap = kb < ka
    let (lowK, highK) = swap ? (kb, ka) : (ka, kb)
    let (lo, hi) = swap ? (1, 0) : (0, 1)
    let isSingle = single || highK <= lowK
    func weight(_ t: Double) -> Double {
        isSingle ? 1 : min(max((t - 1 / highK) / (1 / lowK - 1 / highK), 0), 1)
    }
    func pick(_ arr: [[Double]], _ i: Int) -> M3 { arr[i].count == 9 ? arr[i] : arr[1 - i] }
    func cal(_ i: Int) -> M3 { m.cameraCalibrations[i].count == 9 ? m.cameraCalibrations[i] : identity }

    var w = weight(0.0002)
    for _ in 0..<8 {
        let cm = lerp(w, pick(m.colorMatrices, lo), pick(m.colorMatrices, hi))
        let cc = lerp(w, cal(lo), cal(hi))
        guard let i = inv(mul(mul(ab, cc), cm)), let t = mccamy(mulv(i, neutral)) else { break }
        let next = weight(1 / t)
        let delta = abs(next - w)
        w = next
        if delta < 0.0001 { break }
    }

    let abcc = mul(ab, lerp(w, cal(lo), cal(hi)))
    let hasFM = m.forwardMatrices[0].count == 9 || m.forwardMatrices[1].count == 9
    if hasFM, let i = inv(abcc) {
        let v = mulv(i, neutral)
        if !v.contains(where: { $0 <= 0 }) {
            let fm = lerp(w, pick(m.forwardMatrices, lo), pick(m.forwardMatrices, hi))
            return mul(mul(fm, diag(v.map { 1 / $0 })), i)
        }
    }
    let cm = lerp(w, pick(m.colorMatrices, lo), pick(m.colorMatrices, hi))
    guard let c2x = inv(mul(abcc, cm)), let bi = inv(bradford) else { return nil }
    let src = mulv(bradford, mulv(c2x, neutral)), dst = mulv(bradford, d50White)
    let adapt = mul(mul(bi, diag((0..<3).map { dst[$0] / src[$0] })), bradford)
    return mul(adapt, c2x)
}

public func linearSRGBToCameraSpace(_ m: DNGMetadata) -> [Float] {
    guard let c2x = cameraToXYZ(m), let i = inv(mul(xyzD50ToLinearSRGB, c2x)) else {
        return identity.map(Float.init)
    }
    var mult = m.asShotMultipliers
    if mult.count != 3 || mult.contains(where: { $0 <= 0 }) { mult = [1, 1, 1] }
    let floor = mult.min()!
    return mul(diag(mult.map { $0 / floor }), i).map(Float.init)
}
