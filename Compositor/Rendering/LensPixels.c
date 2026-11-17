#include "LensPixels.h"
#include <math.h>
#include <string.h>

static double compute_anamorphosis(double a, double b) {
    if (b <= 0) return a;
    double t = b * sqrt(4 * a * a + b * b) - b * b;
    if (t < 0) return a;
    double r = sqrt(t * 0.5);
    return a < 0 ? -r : r;
}

static void sample_bilinear(const uint8_t *source, size_t width, size_t height, size_t stride,
                            double sx, double sy, uint8_t *out) {
    // Premultiplied samples. Missing neighbors contribute nothing, so the edge fades to transparent
    // instead of picking up a straight-alpha color halo.
    double fx0 = floor(sx), fy0 = floor(sy);
    double fx = sx - fx0, fy = sy - fy0;
    long x0 = (long)fx0, y0 = (long)fy0;
    double sums[4] = {0, 0, 0, 0};
    for (int j = 0; j < 2; ++j) {
        long row = y0 + j;
        if (row < 0 || row >= (long)height) continue;
        double wy = j ? fy : 1 - fy;
        if (wy == 0) continue;
        const uint8_t *line = source + (size_t)row * stride;
        for (int i = 0; i < 2; ++i) {
            long column = x0 + i;
            if (column < 0 || column >= (long)width) continue;
            double weight = wy * (i ? fx : 1 - fx);
            if (weight == 0) continue;
            const uint8_t *p = line + (size_t)column * 4;
            for (int c = 0; c < 4; ++c) sums[c] += weight * p[c];
        }
    }
    for (int c = 0; c < 4; ++c) out[c] = (uint8_t)lround(sums[c]);
}

void lens_distort(const uint8_t *source, uint8_t *destination, size_t width, size_t height, size_t stride, double k) {
    double cx = width * 0.5, cy = height * 0.5;
    double halfDiagonal2 = cx * cx + cy * cy;
    for (size_t y = 0; y < height; ++y) {
        double dy = y + 0.5 - cy;
        uint8_t *out = destination + y * stride;
        for (size_t x = 0; x < width; ++x) {
            double dx = x + 0.5 - cx;
            double scale = 1.0 - k * (dx * dx + dy * dy) / halfDiagonal2;
            // Source position in pixel-center coordinates.
            double sx = cx + dx * scale - 0.5, sy = cy + dy * scale - 0.5;
            sample_bilinear(source, width, height, stride, sx, sy, out + x * 4);
        }
    }
}

void volume_deform(const uint8_t *source, uint8_t *destination, size_t width, size_t height, size_t stride,
                   double strengthH, double strengthV, double strengthR, int mode) {
    if (width == 0 || height == 0) return;
    if ((mode == 0 && strengthR <= 0) || (mode == 1 && strengthH <= 0) || (mode == 2 && strengthV <= 0)
        || (mode == 3 && strengthH <= 0 && strengthV <= 0)) {
        for (size_t y = 0; y < height; ++y) {
            const uint8_t *src = source + y * stride;
            uint8_t *dst = destination + y * stride;
            for (size_t x = 0; x < width * 4; ++x) dst[x] = src[x];
        }
        return;
    }
    double halfW = width * 0.5, halfH = height * 0.5;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *out = destination + y * stride;
        double ny = ((y + 0.5) / halfH) - 1.0;
        for (size_t x = 0; x < width; ++x) {
            double nx = ((x + 0.5) / halfW) - 1.0;
            double sx = nx, sy = ny;
            if (mode == 0) {
                double r = sqrt(sx * sx + sy * sy);
                if (r > 1e-9 && strengthR > 0) {
                    double rp = compute_anamorphosis(r, strengthR);
                    double scale = rp / r;
                    sx *= scale;
                    sy *= scale;
                }
            } else if (mode == 1) {
                if (strengthH > 0) sx = compute_anamorphosis(sx, strengthH);
            } else if (mode == 2) {
                if (strengthV > 0) sy = compute_anamorphosis(sy, strengthV);
            } else {
                if (strengthH > 0) sx = compute_anamorphosis(sx, strengthH);
                if (strengthV > 0) sy = compute_anamorphosis(sy, strengthV);
            }
            double srcX = (sx + 1.0) * halfW - 0.5;
            double srcY = (sy + 1.0) * halfH - 0.5;
            sample_bilinear(source, width, height, stride, srcX, srcY, out + x * 4);
        }
    }
}

// The distortion polynomial's scale factor at radius r, in the calibration's own form. The terms are
// the rescaled coefficients: poly3 k1, poly5 k1 k2, ptlens a b c. These are the reference's forward
// maps (ModifyCoord_Dist_*): the correction direction applies them to destination coordinates.
static double distortion_poly(int model, const LensfunCorrectionParams *params, double r) {
    double r2 = r * r;
    switch (model) {
        case 1: return 1.0 + params->distortionTerm1 * r2;                                     // poly3
        case 2: return 1.0 + params->distortionTerm1 * r2 + params->distortionTerm2 * r2 * r2; // poly5
        case 3: return params->distortionTerm1 * r2 * r + params->distortionTerm2 * r2
                     + params->distortionTerm3 * r + 1.0;                                      // ptlens
        default: return 1.0;
    }
}

// The chromatic-aberration scale at radius r for one channel: the reference's forward maps
// (ModifyCoord_TCA_Linear / _Poly3), applied to the already-distorted position.
static double tca_poly(int model, double v, double c, double b, double r) {
    switch (model) {
        case 1: return v;                                          // linear: a plain scale
        case 2: return b * r * r + c * r + v;                      // poly3: b·r² + c·r + v
        default: return 1.0;
    }
}

// One bilinear sample of one channel, in premultiplied RGBA. Missing neighbors contribute nothing,
// so the edge fades to transparent instead of picking up a color halo.
static double sample_channel(const uint8_t *source, size_t width, size_t height, size_t stride,
                             double sx, double sy, int channel) {
    double fx0 = floor(sx), fy0 = floor(sy);
    double fx = sx - fx0, fy = sy - fy0;
    long x0 = (long)fx0, y0 = (long)fy0;
    double sum = 0;
    for (int j = 0; j < 2; ++j) {
        long row = y0 + j;
        if (row < 0 || row >= (long)height) continue;
        double wy = j ? fy : 1 - fy;
        if (wy == 0) continue;
        const uint8_t *line = source + (size_t)row * stride;
        for (int i = 0; i < 2; ++i) {
            long column = x0 + i;
            if (column < 0 || column >= (long)width) continue;
            double weight = wy * (i ? fx : 1 - fx);
            if (weight == 0) continue;
            sum += line[(size_t)column * 4 + channel] * weight;
        }
    }
    return sum;
}

void lensfun_correct(const uint8_t *source, uint8_t *destination, size_t width, size_t height,
                     size_t stride, const LensfunCorrectionParams *params) {
    if (width == 0 || height == 0) return;
    if (params->normScale == 0.0 || !isfinite(params->normScale)) {
        for (size_t y = 0; y < height; ++y) memcpy(destination + y * stride, source + y * stride, width * 4);
        return;
    }
    const double normUnScale = 1.0 / params->normScale;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *out = destination + y * stride;
        // The destination row in the calibration's coordinate system, relative to the center: the
        // reference maps pixel indices directly, without a half-pixel shift (ApplyColorModification).
        double dy = (double)y * params->normScale - params->centerY;
        for (size_t x = 0; x < width; ++x) {
            double dx = (double)x * params->normScale - params->centerX;

            // The source position: the distortion model maps the destination radius to the source
            // radius (the reference's correction direction), then each channel takes its own
            // chromatic-aberration scale about the image center from that distorted position.
            double r = sqrt(dx * dx + dy * dy);
            double scale = distortion_poly(params->distortionModel, params, r);
            double gx = dx * scale, gy = dy * scale;
            double rDistorted = sqrt(gx * gx + gy * gy);
            double redScale = tca_poly(params->tcaModel, params->tcaRedV, params->tcaRedC, params->tcaRedB, rDistorted);
            double blueScale = tca_poly(params->tcaModel, params->tcaBlueV, params->tcaBlueC, params->tcaBlueB, rDistorted);

            // Back to pixel coordinates for sampling. The chromatic-aberration scales act about the
            // image center, where the calibration's radius origin sits, so each channel's position is
            // scaled in normalized coordinates and only then converted back to pixels.
            double sxG = (gx + params->centerX) * normUnScale;
            double syG = (gy + params->centerY) * normUnScale;
            double sxR = (gx * redScale + params->centerX) * normUnScale;
            double syR = (gy * redScale + params->centerY) * normUnScale;
            double sxB = (gx * blueScale + params->centerX) * normUnScale;
            double syB = (gy * blueScale + params->centerY) * normUnScale;

            // Vignetting multiplier at the source position's radius, as the reference's color pass
            // sees the source. The guard keeps a divisor near zero from blowing a channel up.
            double multiplier = 1.0;
            if (params->vignetting) {
                double r2 = gx * gx + gy * gy;
                double r4 = r2 * r2, r6 = r4 * r2;
                double c = 1.0 + params->vignettingTerm1 * r2 + params->vignettingTerm2 * r4
                               + params->vignettingTerm3 * r6;
                if (isfinite(c) && c >= 0.05) multiplier = 1.0 / c;
                else if (isfinite(c) && c > 0) multiplier = 20.0;
            }

            double red = sample_channel(source, width, height, stride, sxR, syR, 0);
            double green = sample_channel(source, width, height, stride, sxG, syG, 1);
            double blue = sample_channel(source, width, height, stride, sxB, syB, 2);
            double alpha = sample_channel(source, width, height, stride, sxG, syG, 3);

            uint8_t *pixel = out + x * 4;
            double values[4] = {red * multiplier, green * multiplier, blue * multiplier, alpha};
            // The multiplier can only brighten, so the premultiplied channels stay within their
            // shared alpha; 16-bit sources are corrected through this 8-bit pass at reduced
            // precision, which the camera raw pipeline records.
            double alphaLimit = values[3] > 255 ? 255 : values[3];
            for (int channel = 0; channel < 4; ++channel) {
                double value = values[channel];
                if (channel < 3 && value > alphaLimit) value = alphaLimit;
                if (!isfinite(value) || value <= 0) { pixel[channel] = 0; continue; }
                pixel[channel] = value >= 254.5 ? 255 : (uint8_t)lround(value);
            }
        }
    }
}
