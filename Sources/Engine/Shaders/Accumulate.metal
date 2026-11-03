// Crepuscule - Accumulate.metal
// Constantin Clerc (c22dev) - 0.1
// keep in sync with BurstMerger.accumulate and SuperResolution.accumulate
#include <metal_stdlib>
using namespace metal;
// no fma, has to stay bit exact with the cpu
#pragma METAL fp contract(off)

struct MergeAccParams {
    uint W, H;
    int cols, rows;
    uint confWidth, same, hasGhost;
    float baseBlack, altBlack, range, altRange, scale, noiseA, noiseB, minVar;
};

struct MergeSample { float wSum, vSum; };

static void mergeSample(thread MergeSample &s, float bilinear, float tileW, int2 o, int x, int y, float r, float cv, float refVar,
                        device const ushort *ab, device const float *ghost, device const float *table, constant MergeAccParams &p) {
    float fw = p.same ? tileW : tileW + (1 - tileW) * (1 - cv);
    if (!(bilinear > 0) || !(fw > 0.02f)) return;
    int W = int(p.W), H = int(p.H);
    int ax = x + 2 * o.x, ay = y + 2 * o.y;
    if (ax < 0 || ax >= W || ay < 0 || ay >= H) return;
    float v = float(ab[ay * W + ax]) - p.altBlack;
    float ramp = 1;
    if (v > p.altRange * 0.9f) ramp = v >= p.altRange * 0.98f ? 0 : (p.altRange * 0.98f - v) / (p.altRange * 0.98f - p.altRange * 0.9f);
    float k;
    if (p.same) {
        k = min(ramp, cv);
        if (!(k > 0)) return;
        v *= p.scale;
    } else {
        k = (1 - cv) * ramp;
        if (!(k > 0)) return;
        v *= p.scale;
        if (cv < 0.5f && r >= p.range * 0.9f && v < p.range * 0.9f) {
            if (!(tileW > 0.5f) || !(v >= p.range * 0.5f)) return;
        }
        if (p.hasGhost) {
            float g = ghost[y * W + x];
            if (g > 0 && g > p.scale * p.altRange * 0.98f) return;
        }
    }
    float variance = max(p.scale * p.noiseA * max(v, 0.0f) + p.scale * p.scale * p.noiseB, p.minVar);
    float d = (v - r) * (v - r) / (18 * (variance + refVar));
    float robust = 0;
    if (d < 20) {
        float t = d * 204.8f;
        int i = int(t);
        float f = t - float(i);
        robust = table[i] + (table[i + 1] - table[i]) * f;
    }
    robust = cv * robust + (1 - cv);
    float iv = min(refVar / max(variance, 1e-6f), 1.0f);
    float w = bilinear * fw * robust * iv * k;
    s.wSum += w; s.vSum += w * v;
}

kernel void mergeAccumulate(device const ushort *rb [[buffer(0)]], device const ushort *ab [[buffer(1)]],
                            device const float *conf [[buffer(2)]], device const int2 *off [[buffer(3)]],
                            device const float *tw [[buffer(4)]], device const float *ghost [[buffer(5)]],
                            device const float *table [[buffer(6)]], device float *sw [[buffer(7)]], device float *sv [[buffer(8)]],
                            constant MergeAccParams &p [[buffer(9)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.W || gid.y >= p.H) return;
    int x = int(gid.x), y = int(gid.y), W = int(p.W);
    float fyRaw = (float(y) - 16) * 0.03125f;
    int ty0 = int(fyRaw);
    float fy = fyRaw >= 0 ? fyRaw - float(int(fyRaw)) : 0;
    if (fyRaw < 0) ty0 = 0;
    if (ty0 >= p.rows - 1) { ty0 = p.rows - 1; fy = 0; }
    int ty1 = min(ty0 + 1, p.rows - 1);
    float r = float(rb[y * W + x]) - p.baseBlack;
    float cv = conf[(y >> 1) * int(p.confWidth) + (x >> 1)];
    float refVar = max(p.minVar, p.noiseB + max(r, 0.0f) * p.noiseA);
    float fxRaw = (float(x) - 16) * 0.03125f;
    int tx0 = int(fxRaw);
    float fx = fxRaw >= 0 ? fxRaw - float(int(fxRaw)) : 0;
    if (fxRaw < 0) tx0 = 0;
    if (tx0 >= p.cols - 1) { tx0 = p.cols - 1; fx = 0; }
    int tx1 = min(tx0 + 1, p.cols - 1);
    int i00 = ty0 * p.cols + tx0, i01 = ty0 * p.cols + tx1, i10 = ty1 * p.cols + tx0, i11 = ty1 * p.cols + tx1;
    MergeSample s = { 0, 0 };
    int2 o00 = off[i00], o01 = off[i01], o10 = off[i10], o11 = off[i11];
    if (all(o00 == o01) && all(o00 == o10) && all(o00 == o11)) {
        float blended = (1 - fy) * (1 - fx) * tw[i00] + (1 - fy) * fx * tw[i01] + fy * (1 - fx) * tw[i10] + fy * fx * tw[i11];
        mergeSample(s, 1, blended, o00, x, y, r, cv, refVar, ab, ghost, table, p);
    } else {
        mergeSample(s, (1 - fy) * (1 - fx), tw[i00], o00, x, y, r, cv, refVar, ab, ghost, table, p);
        mergeSample(s, (1 - fy) * fx, tw[i01], o01, x, y, r, cv, refVar, ab, ghost, table, p);
        mergeSample(s, fy * (1 - fx), tw[i10], o10, x, y, r, cv, refVar, ab, ghost, table, p);
        mergeSample(s, fy * fx, tw[i11], o11, x, y, r, cv, refVar, ab, ghost, table, p);
    }
    uint idx = gid.y * p.W + gid.x;
    sw[idx] += s.wSum;
    sv[idx] += s.vSum;
}

struct SRParams {
    uint OW, OH, ww, wh, cols, cbw, frames;
    int p0, p1, p2, p3;
    float minW, scaleOut;
};

struct SRFrame { uint dataOffset, gridOffset; int robustOffset; float black; };
struct SRLerp { int t0, t1; float w; };

static float3 demosaicAt(device const ushort *d, int W, int H, float black, int4 pat, float x, float y) {
    int x0 = int(floor(x)), y0 = int(floor(y));
    float s[3] = { 0, 0, 0 }, w[3] = { 0, 0, 0 };
    for (int yy = y0 - 1; yy <= y0 + 2; yy++) {
        float wy = max(0.0f, 1 - abs(float(yy) - y) / 2);
        if (!(wy > 0)) continue;
        int cy = min(max(yy, 0), H - 1);
        for (int xx = x0 - 1; xx <= x0 + 2; xx++) {
            float wx = max(0.0f, 1 - abs(float(xx) - x) / 2);
            if (!(wx > 0)) continue;
            int cx = min(max(xx, 0), W - 1);
            int c = pat[(yy & 1) * 2 + (xx & 1)];
            s[c] += wx * wy * (float(d[cy * W + cx]) - black); w[c] += wx * wy;
        }
    }
    return float3(w[0] > 0 ? s[0] / w[0] : 0, w[1] > 0 ? s[1] / w[1] : 0, w[2] > 0 ? s[2] / w[2] : 0);
}

kernel void superResAccumulate(device const ushort *data [[buffer(0)]], device const SRFrame *frames [[buffer(1)]],
                               device const float *fxs [[buffer(2)]], device const float *fys [[buffer(3)]],
                               device const float *robusts [[buffer(4)]], device const float *kernels [[buffer(5)]],
                               device const float *table [[buffer(6)]], device const float *px [[buffer(7)]],
                               device const float *py [[buffer(8)]], device const int *bxs [[buffer(9)]], device const int *bys [[buffer(10)]],
                               device const SRLerp *colLerp [[buffer(11)]], device const SRLerp *rowLerp [[buffer(12)]],
                               device ushort *out [[buffer(13)]], device atomic_uint *covered [[buffer(14)]],
                               constant SRParams &p [[buffer(15)]], uint2 gid [[thread_position_in_grid]]) {
    bool inside = gid.x < p.OW && gid.y < p.OH;
    bool full = false;
    if (inside) {
        int i = int(gid.x), j = int(gid.y);
        int ww = int(p.ww), wh = int(p.wh), cols = int(p.cols);
        int4 pat = int4(p.p0, p.p1, p.p2, p.p3);
        SRLerp rl = rowLerp[j], cl = colLerp[i];
        float pyj = py[j], pxi = px[i];
        int k = bys[j] * int(p.cbw) + bxs[i];
        float ka = kernels[k * 3], kb = kernels[k * 3 + 1], kc = kernels[k * 3 + 2];
        int a00 = rl.t0 * cols + cl.t0, a01 = rl.t0 * cols + cl.t1, a10 = rl.t1 * cols + cl.t0, a11 = rl.t1 * cols + cl.t1;
        float wx = cl.w, wy = rl.w;
        float ap[6] = { 0, 0, 0, 0, 0, 0 };
        for (uint f = 0; f < p.frames; f++) {
            SRFrame st = frames[f];
            float r = 1;
            if (st.robustOffset >= 0) { r = robusts[st.robustOffset + k]; if (r < 0.01f) continue; }
            device const float *fxp = fxs + st.gridOffset, *fyp = fys + st.gridOffset;
            float ox = (fxp[a00] * (1 - wx) + fxp[a01] * wx) * (1 - wy) + (fxp[a10] * (1 - wx) + fxp[a11] * wx) * wy;
            float oy = (fyp[a00] * (1 - wx) + fyp[a01] * wx) * (1 - wy) + (fyp[a10] * (1 - wx) + fyp[a11] * wx) * wy;
            float Px = pxi + 2 * ox, Py = pyj + 2 * oy;
            int xc = int(floor(Px + 0.5f)), yc = int(floor(Py + 0.5f));
            if (xc < 1 || yc < 1 || xc >= ww - 1 || yc >= wh - 1) continue;
            device const ushort *d = data + st.dataOffset;
            float ddx = float(xc) - Px, ddy = float(yc) - Py;
            for (int ky = -1; ky <= 1; ky++) {
                float dy = ddy + float(ky);
                int row = (yc + ky) * ww;
                int prow = ((yc + ky) & 1) * 2;
                for (int kx = -1; kx <= 1; kx++) {
                    float dx = ddx + float(kx);
                    float q = (ka * dx * dx + 2 * kb * dx * dy + kc * dy * dy) * 64;
                    if (!(q < 9 * 64)) continue;
                    int qi = int(q);
                    float qf = q - float(qi);
                    float w = (table[qi] + (table[qi + 1] - table[qi]) * qf) * r;
                    int c = pat[prow + ((xc + kx) & 1)];
                    ap[c] += w;
                    ap[3 + c] += w * (float(d[row + xc + kx]) - st.black);
                }
            }
        }
        full = true;
        bool haveFallback = false;
        float3 fb = 0;
        uint o = (gid.y * p.OW + gid.x) * 3;
        for (int c = 0; c < 3; c++) {
            float w = ap[c], v;
            if (w >= p.minW) {
                v = ap[3 + c] / w;
            } else {
                full = false;
                if (!haveFallback) { fb = demosaicAt(data + frames[0].dataOffset, ww, wh, frames[0].black, pat, pxi, pyj); haveFallback = true; }
                float alpha = w / p.minW;
                v = w > 0 ? alpha * (ap[3 + c] / w) + (1 - alpha) * fb[c] : fb[c];
            }
            out[o + c] = ushort(min(max(v * p.scaleOut + 0.5f, 0.0f), 65535.0f));
        }
    }
    uint n = simd_sum(full ? 1u : 0u);
    if (simd_is_first() && n > 0) atomic_fetch_add_explicit(covered, n, memory_order_relaxed);
}
