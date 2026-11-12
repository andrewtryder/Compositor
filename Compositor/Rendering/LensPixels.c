#include "LensPixels.h"
#include <math.h>

static double compute_anamorphosis(double a, double b) {
    if (b <= 0) return a;
    double t = b * sqrt(4 * a * a + b * b) - b * b;
    if (t < 0) return a;
    double r = sqrt(t * 0.5);
    return a < 0 ? -r : r;
}

static void sample_bilinear(const uint8_t *source, size_t width, size_t height, size_t stride,
                            double sx, double sy, uint8_t *out) {
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
