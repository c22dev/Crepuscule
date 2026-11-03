// Crepuscule - Shaders.metal
// Constantin Clerc (c22dev) - 0.1
#include <metal_stdlib>
using namespace metal;

constant float kGrainCurve[65] = {
    -3.800010681e-02f, -2.325260639e-02f, -1.989215612e-02f, -1.781263202e-02f,
    -1.615393162e-02f, -1.492491364e-02f, -1.381588727e-02f, -1.297718659e-02f,
    -1.213848591e-02f, -1.142418757e-02f, -1.073449478e-02f, -1.004480198e-02f,
    -9.452603757e-03f, -8.867178112e-03f, -8.281754330e-03f, -7.722431794e-03f,
    -7.187329233e-03f, -6.652226672e-03f, -6.117124110e-03f, -5.652377382e-03f,
    -5.207348615e-03f, -4.762317985e-03f, -4.317288287e-03f, -3.878783435e-03f,
    -3.456486389e-03f, -3.034189343e-03f, -2.611891367e-03f, -2.189594321e-03f,
    -1.794829033e-03f, -1.422494650e-03f, -1.050161198e-03f, -6.778268144e-04f,
    3.054924309e-04f, 6.778268144e-04f, 1.050161198e-03f, 1.422494650e-03f,
    1.794829033e-03f, 2.189594321e-03f, 2.611891367e-03f, 3.034189343e-03f,
    3.456486389e-03f, 3.878783435e-03f, 4.317288287e-03f, 4.762317985e-03f,
    5.207348615e-03f, 5.652377382e-03f, 6.117124110e-03f, 6.652226672e-03f,
    7.187329233e-03f, 7.722431794e-03f, 8.281754330e-03f, 8.867178112e-03f,
    9.452603757e-03f, 1.004480198e-02f, 1.073449478e-02f, 1.142418757e-02f,
    1.213848591e-02f, 1.297718659e-02f, 1.381588727e-02f, 1.492491364e-02f,
    1.615393162e-02f, 1.781263202e-02f, 1.989215612e-02f, 2.325260639e-02f,
    3.800010681e-02f
};
constant float kBtLogCTable[66] = {
    6.600000052e-05f, 9.807077004e-04f, 2.165831160e-03f, 3.961895593e-03f,
    6.670943927e-03f, 1.064087357e-02f, 1.648214646e-02f, 2.314566821e-02f,
    3.039930202e-02f, 3.809111193e-02f, 4.638190195e-02f, 5.526538938e-02f,
    6.480616331e-02f, 7.508048415e-02f, 8.616304398e-02f, 9.812471271e-02f,
    1.109681427e-01f, 1.262416095e-01f, 1.452325135e-01f, 1.679344773e-01f,
    1.937834024e-01f, 2.224663496e-01f, 2.540330589e-01f, 2.881623507e-01f,
    3.241688609e-01f, 3.612439632e-01f, 3.993163109e-01f, 4.389700294e-01f,
    4.800421000e-01f, 5.215102434e-01f, 5.621172190e-01f, 6.017746925e-01f,
    6.411643028e-01f, 6.798673272e-01f, 7.164124250e-01f, 7.492358685e-01f,
    7.777392864e-01f, 8.024988174e-01f, 8.241971135e-01f, 8.433321118e-01f,
    8.602374792e-01f, 8.747937083e-01f, 8.867760897e-01f, 8.965301514e-01f,
    9.047199488e-01f, 9.117856622e-01f, 9.175593853e-01f, 9.218138456e-01f,
    9.248608351e-01f, 9.272415638e-01f, 9.293916821e-01f, 9.314255118e-01f,
    9.332891703e-01f, 9.349926114e-01f, 9.365718365e-01f, 9.380599260e-01f,
    9.394915104e-01f, 9.408984184e-01f, 9.423141479e-01f, 9.437738657e-01f,
    9.453099370e-01f, 9.469420910e-01f, 9.486493468e-01f, 9.504019022e-01f,
    9.521883130e-01f, 9.539949894e-01f
};

struct LightWrapParams { float redSens, redIntens, colorR, colorG, colorB; };
struct EdgeBlurParams { float normSens, gradientStride; };
struct AtanContrastParams { float contrast, pivot; };
struct PreExposureParams { float redGain, greenGain, blueGain, saturation; };
struct ShoulderToeParams { float highlights, shadows, highlightsFalloff, shadowsFalloff; uint enabled; };
struct PostHalationParams { float grainAmplitude; uint blackAndWhite; };
struct FusedGradeParams { float redGain, greenGain, blueGain, saturation, grainAmplitude; uint blackAndWhite; };
struct LinearPreviewParams { float exposure; };
struct RawUnpackParams { uint srcWidth, srcHeight, dstWidth, dstHeight; float parameterB, parameterC; };

// linear filter at i/N not texel centres (thats part of the look)
constexpr sampler kLUTSampler(coord::normalized, address::clamp_to_edge, filter::linear);

static inline float logCEnc(float x) {
    return x > 0.0105910003f ? log10(x * 5.55555582f + 0.0522719994f) * 0.247189999f + 0.385536999f
                             : x * 5.3676548f + 0.0928089991f;
}
static inline float logCDec(float x) {
    return x > 0.149657831f ? (pow(10.0f, (x - 0.385536999f) * 4.04547119f) - 0.0522719994f) * 0.179999992f
                            : (x - 0.0928089991f) * 0.186301097f;
}
static inline float3 logCEncClamped(float3 v) {
    return float3(clamp(logCEnc(v.x), 0.0f, 1.0f), clamp(logCEnc(v.y), 0.0f, 1.0f), clamp(logCEnc(v.z), 0.0f, 1.0f));
}

// trilinear despite the name (kept the original symbol)
static float3 tetrahedralLUTValue(texture3d<float, access::sample> lut, float3 c) {
    float3 size = float3(lut.get_width(), lut.get_height(), lut.get_depth());
    float3 p = (size - 1.0f) * c;
    float3 base = float3(int3(floor(p)));
    float3 f = p - base;
    float3 c000 = lut.sample(kLUTSampler, base / size).rgb;
    float3 c100 = lut.sample(kLUTSampler, (base + float3(1, 0, 0)) / size).rgb;
    float3 c010 = lut.sample(kLUTSampler, (base + float3(0, 1, 0)) / size).rgb;
    float3 c001 = lut.sample(kLUTSampler, (base + float3(0, 0, 1)) / size).rgb;
    float3 c101 = lut.sample(kLUTSampler, (base + float3(1, 0, 1)) / size).rgb;
    float3 c011 = lut.sample(kLUTSampler, (base + float3(0, 1, 1)) / size).rgb;
    float3 c110 = lut.sample(kLUTSampler, (base + float3(1, 1, 0)) / size).rgb;
    float3 c111 = lut.sample(kLUTSampler, (base + float3(1, 1, 1)) / size).rgb;
    float3 y0 = mix(mix(c000, c100, f.xxx), mix(c010, c110, f.xxx), f.yyy);
    float3 y1 = mix(mix(c001, c101, f.xxx), mix(c011, c111, f.xxx), f.yyy);
    return mix(y0, y1, f.zzz);
}

static float atanContrast(float x, float contrast, float pivot) {
    if (fabs(contrast) < 9.99999975e-05f) return x;
    if (contrast >= 0.0f) {
        if (x < pivot) {
            float a = atan(contrast);
            return (a + atan((x / pivot - 1.0f) * contrast)) * pivot / a;
        }
        float inv = 1.0f - pivot;
        float a = atan(contrast);
        return 1.0f - (a + atan(((1.0f - x) / inv - 1.0f) * contrast)) * inv / a;
    }
    if (x < pivot) {
        return (1.0f - tan(atan(-contrast) * (x / pivot - 1.0f)) / contrast) * pivot;
    }
    float inv = 1.0f - pivot;
    return 1.0f - (1.0f - tan(atan(-contrast) * ((1.0f - x) / inv - 1.0f)) / contrast) * inv;
}

static float3 saturationGamma(float3 v, float sat) {
    float len = pow(pow(v.x, 2.0f) + pow(v.y, 2.0f) + pow(v.z, 2.0f), 0.5f);
    float3 u = float3(0.0f);
    if (!(len < 9.99999975e-06f)) u = v * (1.0f / max(len, 9.99999975e-06f));
    float3 d = u + float3(-0.577350259f);
    float dist = sqrt(dot(d, d));
    float t = (dist < 1.0f ? 1.0f : 1.0f / dist) * dist;
    float k;
    if (sat < 0.0f) {
        k = (1.0f - clamp(sat * -2.0f, 0.0f, 1.0f) * 0.25f) * (1.0f - t);
    } else {
        k = (1.0f - t) + clamp(pow(t, 1.0f / sat), 0.0f, 1.0f);
    }
    float3 r = k * d + float3(0.577350259f);
    float l = pow(pow(r.x, 2.0f) + pow(r.y, 2.0f) + pow(r.z, 2.0f), 0.5f);
    float s = (l > 9.99999975e-06f ? 1.0f / l : 0.0f) * len;
    return r * s;
}

static float3 shoulderToe(float3 v, constant ShoulderToeParams &p) {
    if (p.enabled == 0) return v;
    float Y = dot(float3(0.212672904f, 0.715152204f, 0.0721750036f), v);
    if (!(Y > 0.0f)) return v;
    float L = logCEnc(Y);
    float o = L;
    if (L > 0.0f && L < 1.0f) {
        float a = 1.0f - L;
        float hi = powr(a, p.highlights);
        float lo = powr(L, 1.0f / p.shadows);
        float loFall = powr(a, p.shadowsFalloff);
        float hiFall = powr(L, p.highlightsFalloff);
        o = (lo - L) * loFall + L + hiFall * (1.0f - (L + hi));
    }
    return v * (logCDec(o) / Y);
}

static float btInverse(float v) {
    if (!(v > 6.60000005e-05f)) return 0.0f;
    if (!(v < 0.953994989f)) return 1.0f;
    int lo = 0, hi = 65;
    for (int n = 0; n < 7; n++) {
        int mid = (hi + lo) / 2;
        if (kBtLogCTable[mid] > v) hi = mid; else lo = mid;
    }
    float a = kBtLogCTable[lo], b = kBtLogCTable[lo + 1];
    return ((b > a ? (v - a) / (b - a) : 0.0f) + float(lo)) * 0.0153846154f;
}
static float btForward(float x) {
    float t = clamp(x, 0.0f, 1.0f) * 65.0f;
    int i = clamp(int(floor(t)), 0, 64);
    return mix(kBtLogCTable[i], kBtLogCTable[i + 1], t - float(i));
}
static float3 grainInBtDomain(float3 c, float g) {
    return float3(btForward(btInverse(c.x) + g), btForward(btInverse(c.y) + g), btForward(btInverse(c.z) + g));
}

static inline uint pcg(uint x) {
    uint v = x * 747796405u + 2891336453u;
    uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (w >> 22u) ^ w;
}
static float grainCurveSample(uint seed, uint2 gid) {
    uint h = pcg(pcg(pcg(seed) ^ gid.y) ^ gid.x);
    float t = clamp(float(h) * 2.32830644e-10f, 0.0f, 1.0f) * 64.0f;
    int i = clamp(int(floor(t)), 0, 63);
    return mix(kGrainCurve[i], kGrainCurve[i + 1], t - float(i));
}

kernel void encodeLogCUnclamped(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    dst.write(float4(logCEnc(c.r), logCEnc(c.g), logCEnc(c.b), c.a), gid);
}
kernel void decodeLogCUnclamped(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    dst.write(float4(logCDec(c.r), logCDec(c.g), logCDec(c.b), c.a), gid);
}

kernel void coneBlurSeparableHorizontal(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant float &radius [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int w = int(src.get_width());
    if (int(gid.x) >= w || int(gid.y) >= int(src.get_height())) return;
    float r = max(radius, 9.99999975e-05f);
    int n = max(1, int(ceil(r)));
    float3 sum = 0.0f; float total = 0.0f;
    for (int i = -n; i <= n; i++) {
        float k = clamp(1.0f - fabs(float(i)) / r, 0.0f, 1.0f);
        if (k > 0.0f) {
            int x = i + int(gid.x);
            float3 c = (x >= 0 && x < w) ? src.read(uint2(x, gid.y)).rgb : float3(0.0f);
            sum += c * k; total += k;
        }
    }
    dst.write(float4(total > 0.0f ? sum / total : float3(0.0f), 1.0f), gid);
}
kernel void coneBlurSeparableVertical(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant float &radius [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int h = int(src.get_height());
    if (int(gid.x) >= int(src.get_width()) || int(gid.y) >= h) return;
    float r = max(radius, 9.99999975e-05f);
    int n = max(1, int(ceil(r)));
    float3 sum = 0.0f; float total = 0.0f;
    for (int i = -n; i <= n; i++) {
        float k = clamp(1.0f - fabs(float(i)) / r, 0.0f, 1.0f);
        if (k > 0.0f) {
            int y = i + int(gid.y);
            float3 c = (y >= 0 && y < h) ? src.read(uint2(gid.x, y)).rgb : float3(0.0f);
            sum += c * k; total += k;
        }
    }
    dst.write(float4(total > 0.0f ? sum / total : float3(0.0f), 1.0f), gid);
}

kernel void lightWrapTintMask(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant LightWrapParams &params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    float avg = (c.r + c.g + c.b) * 0.333333343f;
    float a = atan(6.52670002f - (params.redSens - 0.939999998f + avg) * 9.20330048f);
    float m = clamp(1.0f / (a * 6.259999871e-01f + 1.146999955e+00f) - 0.550000012f, 0.0f, 1.0f);
    dst.write(float4(float3(params.colorR, params.colorG, params.colorB) * (params.redIntens * m), 1.0f), gid);
}
kernel void lightWrapComposite(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> tintedUnblurred [[texture(1)]], texture2d<float, access::read> tintedBlurred [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    float3 diff = max((tintedBlurred.read(gid) - tintedUnblurred.read(gid)).rgb, float3(0.0f));
    float3 m = clamp(float3(4.909999967e-01f) - atan((c.rgb - float3(0.300000012f)) * -5.5f) * 5.070000291e-01f, 0.0f, 1.0f);
    dst.write(float4((1.0f - m) * diff + c.rgb, c.a), gid);
}
kernel void edgeBlurComposite(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> blurredImage [[texture(1)]], texture2d<float, access::write> dst [[texture(2)]], constant EdgeBlurParams &params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int w = int(src.get_width()), h = int(src.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    float4 c = src.read(gid);
    float stride = max(params.gradientStride, 9.99999975e-05f);
    int s = max(1, int(round(stride)));
    float g[3][3];
    for (int row = -1; row <= 1; row++) for (int col = -1; col <= 1; col++) {
        int x = col * s + int(gid.x), y = row * s + int(gid.y);
        float3 v = (x >= 0 && x < w && y >= 0 && y < h) ? src.read(uint2(x, y)).rgb : float3(0.0f);
        g[row + 1][col + 1] = (v.r + v.g + v.b) * 0.333333343f;
    }
    float gx = (g[2][2] + g[0][2]) - (g[0][0] + g[2][0]) + (g[1][2] - g[1][0]) * 2.0f;
    float gy = (g[0][2] + g[0][0]) - (g[2][2] + g[2][0]) + (g[0][1] - g[2][1]) * 2.0f;
    float mag = stride * 0.25f * sqrt(gx * gx + gy * gy) / float(s);
    float a1 = atan(3.200000152e-02f - pow(max(mag, 0.0f), 1.019999981e+00f) * 4.0f);
    float edge = clamp(-2.999999933e-02f - a1 * 6.499999762e-01f, 0.0f, 1.0f) * params.normSens;
    float lum = (c.r + c.g + c.b) * 0.333333343f * params.normSens;
    float a2 = atan(2.400000095e+00f - pow(max(lum, 0.0f), 1.200000048e+00f) * 12.5f);
    float lumMask = clamp(4.440000057e-01f - a2 * 3.759999871e-01f, 0.0f, 1.0f);
    float w8 = clamp(edge * lumMask, 0.0f, 1.0f);
    dst.write(float4(mix(c.rgb, blurredImage.read(gid).rgb, float3(w8)), 1.0f), gid);
}

kernel void generateClassicGrainPlatePixelSize(texture2d<float, access::write> dst [[texture(0)]], constant float &seed [[buffer(0)]], constant float &amplitudeCompensation [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float v = amplitudeCompensation * grainCurveSample(uint(seed), gid);
    dst.write(float4(v, v, v, 1.0f), gid);
}
kernel void generateClassicGrainPlateCoarse(texture2d<float, access::write> dst [[texture(0)]], constant float &seed [[buffer(0)]], constant float &amplitudeCompensation [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float v = grainCurveSample(uint(seed), gid) * 0.924000025f * amplitudeCompensation;
    dst.write(float4(v, v, v, 1.0f), gid);
}

kernel void bakeAtanContrastIntoLUT(texture3d<float, access::read> src [[texture(0)]], texture3d<float, access::write> dst [[texture(1)]], constant AtanContrastParams &params [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height() || gid.z >= src.get_depth()) return;
    float4 c = src.read(gid);
    dst.write(float4(atanContrast(c.r, params.contrast, params.pivot), atanContrast(c.g, params.contrast, params.pivot), atanContrast(c.b, params.contrast, params.pivot), c.a), gid);
}

kernel void preHalationExposureLogC(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant PreExposureParams &params [[buffer(0)]], constant ShoulderToeParams &tone [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    float3 v = logCEncClamped(float3(params.redGain, params.greenGain, params.blueGain) * c.rgb);
    dst.write(float4(shoulderToe(saturationGamma(v, params.saturation), tone), c.a), gid);
}
kernel void postHalationLUTGrainFinal(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], texture2d<float, access::read> grainPlate [[texture(2)]], texture3d<float, access::sample> lut [[texture(3)]], constant PostHalationParams &params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    float3 v = tetrahedralLUTValue(lut, clamp(c.rgb, 0.0f, 1.0f));
    v = clamp(grainInBtDomain(v, grainPlate.read(gid).r * params.grainAmplitude), 0.0f, 1.0f);
    if (params.blackAndWhite != 0) v = float3((v.r + v.g + v.b) * 0.333333343f);
    dst.write(float4(v, c.a), gid);
}
kernel void gradeFusedNoHalation(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], texture2d<float, access::read> grainPlate [[texture(2)]], texture3d<float, access::sample> lut [[texture(3)]], constant FusedGradeParams &params [[buffer(0)]], constant ShoulderToeParams &tone [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    float3 v = logCEncClamped(float3(params.redGain, params.greenGain, params.blueGain) * c.rgb);
    v = clamp(shoulderToe(saturationGamma(v, params.saturation), tone), 0.0f, 1.0f);
    v = tetrahedralLUTValue(lut, v);
    v = clamp(grainInBtDomain(v, grainPlate.read(gid).r * params.grainAmplitude), 0.0f, 1.0f);
    if (params.blackAndWhite != 0) v = float3((v.r + v.g + v.b) * 0.333333343f);
    dst.write(float4(v, c.a), gid);
}

kernel void linearPreview(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant LinearPreviewParams &params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float3 v = clamp(max(src.read(gid).rgb * params.exposure, float3(0.0f)), 0.0f, 1.0f);
    float3 o;
    for (int i = 0; i < 3; i++) o[i] = v[i] > 0.00313080009f ? pow(v[i], 0.416666657f) * 1.05499995f - 0.0549999997f : v[i] * 12.9200001f;
    dst.write(float4(o, 1.0f), gid);
}

static inline float mitchell(float x, float B, float C) {
    float a = fabs(x), a2 = a * a, a3 = a2 * a;
    if (a < 1.0f) return ((12.0f - 9.0f * B - 6.0f * C) * a3 + (12.0f * B - 18.0f + 6.0f * C) * a2 + (6.0f - 2.0f * B)) * 0.166666672f;
    if (a < 2.0f) return ((8.0f * B + 24.0f * C) + (-12.0f * B - 48.0f * C) * a + (6.0f * B + 30.0f * C) * a2 - (B + 6.0f * C) * a3) * 0.166666672f;
    return 0.0f;
}
kernel void unpackRGB16UIntToRGBA16Float(constant ushort *src [[buffer(0)]], constant RawUnpackParams &params [[buffer(1)]], texture2d<float, access::write> dst [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) return;
    uint i = (params.srcWidth * gid.y + gid.x) * 3;
    dst.write(float4(float3(float(src[i]), float(src[i + 1]), float(src[i + 2])) * 1.52590219e-05f, 1.0f), gid);
}
kernel void cubicResizeHorizontalFromRGB16(constant ushort *src [[buffer(0)]], constant RawUnpackParams &params [[buffer(1)]], texture2d<float, access::write> intermediate [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.dstWidth || gid.y >= params.srcHeight) return;
    float scale = float(params.srcWidth) / float(params.dstWidth);
    float center = (float(gid.x) + 0.5f) * scale - 0.5f;
    int lo = max(0, int(ceil(center - scale * 2.0f)));
    int hi = min(int(params.srcWidth) - 1, int(floor(center + scale * 2.0f)));
    float3 sum = 0.0f; float total = 0.0f;
    for (int x = lo; x <= hi; x++) {
        float k = mitchell((float(x) - center) / scale, params.parameterB, params.parameterC);
        uint i = (uint(x) + params.srcWidth * gid.y) * 3;
        sum += float3(float(src[i]), float(src[i + 1]), float(src[i + 2])) * (k * 1.52590219e-05f);
        total += k;
    }
    intermediate.write(float4(sum * (total > 0.0f ? 1.0f / total : 0.0f), 0.0f), gid);
}
kernel void cubicResizeVerticalToRGBA16Float(texture2d<float, access::read> intermediate [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant RawUnpackParams &params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) return;
    float scale = float(params.srcHeight) / float(params.dstHeight);
    float center = (float(gid.y) + 0.5f) * scale - 0.5f;
    int lo = max(0, int(ceil(center - scale * 2.0f)));
    int hi = min(int(params.srcHeight) - 1, int(floor(center + scale * 2.0f)));
    float3 sum = 0.0f; float total = 0.0f;
    for (int y = lo; y <= hi; y++) {
        float k = mitchell((float(y) - center) / scale, params.parameterB, params.parameterC);
        sum += intermediate.read(uint2(gid.x, y)).rgb * k;
        total += k;
    }
    dst.write(float4(sum * (total > 0.0f ? 1.0f / total : 0.0f), 1.0f), gid);
}
// proxies are packed rgb16, unpacked on load
kernel void cubicResizeVerticalToRGB16Packed(texture2d<float, access::read> intermediate [[texture(0)]], device ushort *dst [[buffer(0)]], constant RawUnpackParams &params [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) return;
    float scale = float(params.srcHeight) / float(params.dstHeight);
    float center = (float(gid.y) + 0.5f) * scale - 0.5f;
    int lo = max(0, int(ceil(center - scale * 2.0f)));
    int hi = min(int(params.srcHeight) - 1, int(floor(center + scale * 2.0f)));
    float3 sum = 0.0f; float total = 0.0f;
    for (int y = lo; y <= hi; y++) {
        float k = mitchell((float(y) - center) / scale, params.parameterB, params.parameterC);
        sum += intermediate.read(uint2(gid.x, y)).rgb * k;
        total += k;
    }
    float3 v = clamp(max(sum * (total > 0.0f ? 1.0f / total : 0.0f), 0.0f) * 65535.0f, 0.0f, 65535.0f);
    uint i = (params.dstWidth * gid.y + gid.x) * 3;
    dst[i] = ushort(v.r); dst[i + 1] = ushort(v.g); dst[i + 2] = ushort(v.b);
}

// night clean: dark flat areas take blurred luma/chroma, then a soft toe deepens the blacks.
// src is the display encoded grade output, blurred and localMax are linear.
// the mask reads the local max of a lightly blurred copy, so any light nearby turns it off (no halos)
struct NightCleanParams { float lo, hi, kLuma, kChroma, toe; };

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}
static inline float3 linearToSRGB(float3 c) {
    c = max(c, 0.0f);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

kernel void nightClean(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> blurred [[texture(1)]],
                       texture2d<float, access::read> localMax [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                       constant NightCleanParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float3 w = float3(0.2126f, 0.7152f, 0.0722f);
    float4 s4 = src.read(gid);
    float3 s = srgbToLinear(s4.rgb);
    float3 b = blurred.read(gid).rgb;
    float ys = dot(s, w), yb = dot(b, w);
    float m = 1.0f - smoothstep(p.lo, p.hi, dot(localMax.read(gid).rgb, w));
    float y2 = mix(ys, yb, p.kLuma * m);
    float3 c = max(y2 + mix(s - ys, b - yb, p.kChroma * m), 0.0f);
    float y = max(dot(c, w), 1e-6f);
    c *= (y / (y + p.toe));
    dst.write(float4(linearToSRGB(c), s4.a), gid);
}
