#ifndef LensPixels_h
#define LensPixels_h
#include <stdint.h>
#include <stddef.h>
// Radial lens distortion over premultiplied RGBA (4 bytes per pixel, `stride` bytes per row, same
// layout for source and destination). Each destination pixel samples the source bilinearly at
// its offset from the image center scaled by (1 - k * r²), where r is that offset relative to the
// half-diagonal: k > 0 pulls samples inward (straightens barrel distortion, corners crop), k < 0
// pushes them outward (straightens pincushion distortion, corners turn transparent). Pixels
// outside the source are transparent. k = 0 copies the source exactly.
void lens_distort(const uint8_t *source, uint8_t *destination, size_t width, size_t height, size_t stride, double k);

// ViewPoint-style volume (anamorphosis) warp. `strengthH`, `strengthV`, and `strengthR` are the
// ComputeAnamorphosis `b` values (0 leaves that axis unchanged). `mode` is 0 radial, 1 horizontal,
// 2 vertical, 3 horizontal then vertical. Destination samples the source bilinearly.
void volume_deform(const uint8_t *source, uint8_t *destination, size_t width, size_t height, size_t stride,
                   double strengthH, double strengthV, double strengthR, int mode);

// Parameters for the calibrated lens correction, in the coordinate system the Lensfun calibration models
// use: pixel offsets scaled by normScale so r = 1 is half the long edge, measured from the image center.
// `distortionModel` is 0 none, 1 poly3 (1 + k1·r²), 2 poly5 (1 + k1·r² + k2·r⁴), 3 ptlens
// (1 + c·r + b·r² + a·r³); the terms are the model's rescaled coefficients. `tcaModel` is 0 none,
// 1 linear (red and blue positions scaled by their term), 2 poly3 (per channel v + c·r + b·r²).
// `vignetting` enables the pa multiplier 1 / (1 + k1·r² + k2·r⁴ + k3·r⁶) taken at each sample's source
// position, which is how the reference applies vignetting before its resample.
typedef struct {
    double normScale, centerX, centerY;
    int distortionModel;
    double distortionTerm1, distortionTerm2, distortionTerm3;
    int tcaModel;
    double tcaRedV, tcaRedC, tcaRedB, tcaBlueV, tcaBlueC, tcaBlueB;
    int vignetting;
    double vignettingTerm1, vignettingTerm2, vignettingTerm3;
} LensfunCorrectionParams;

// The calibrated lens correction over premultiplied RGBA, as one resample: each destination pixel maps
// through the distortion model, then through the per-channel chromatic-aberration model, and the sampled
// color is scaled by the vignetting multiplier at its source position. Alpha follows the green channel's
// position. Samples past the source edge are transparent; a multiplier that would blow a channel up is
// clamped, so no non-finite or overbright value can come out. `normScale` of 0 copies the source.
void lensfun_correct(const uint8_t *source, uint8_t *destination, size_t width, size_t height,
                     size_t stride, const LensfunCorrectionParams *params);
#endif
