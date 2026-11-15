import math

FLT_MAX = 3.4028234663852886e38

def hermite(y0, y1, y2, y3, t):
    """_lf_interpolate (auxfun.cpp). FLT_MAX sentinels mark a missing sample."""
    t2 = t * t; t3 = t2 * t
    g2 = (y2 - y1) if y0 == FLT_MAX else (y2 - y0) * 0.5
    g3 = (y2 - y1) if y3 == FLT_MAX else (y3 - y1) * 0.5
    return (2 * t3 - 3 * t2 + 1) * y1 + (t3 - 2 * t2 + t) * g2 + (-2 * t3 + 3 * t2) * y2 + (t3 - t2) * g3

# Distortion interpolation at 50mm from the test XML (24mm and 70mm ptlens samples).
t = (50.0 - 24.0) / (70.0 - 24.0)
def term(a1, a2, s1=24.0, s2=70.0):
    return hermite(FLT_MAX, a1 * s1, a2 * s2, FLT_MAX, t) / 50.0
a_i = term(0.01, 0.02)
b_i = term(-0.02, -0.01)
c_i = term(0.005, 0.0)
rf_i = hermite(FLT_MAX, 24.2, 70.4, FLT_MAX, t)
print("interpolated ptlens at 50: a=%.12f b=%.12f c=%.12f realFocal=%.12f" % (a_i, b_i, c_i, rf_i))

# Rescale at crop 1.0 (rescale_polynomial_coefficients).
crop = 1.0
hugin_scale = math.hypot(36, 24) / crop / 2
h = rf_i / hugin_scale
d = 1 - a_i - b_i - c_i
A = a_i * h**3 / d**4
B = b_i * h**2 / d**3
C = c_i * h / d**2
print("rescaled: a'=%.12f b'=%.12f c'=%.12f" % (A, B, C))

# NormScale for the 64x64 test image.
W = H = 63.0
ns = math.hypot(36, 24) / crop / math.hypot(W + 1, H + 1) / rf_i
print("normScale 64x64: %.15e" % ns)
center = 31.5 * ns

# Destination pixel (62, 32) mapped through the model (reference: pixel indices, no half shift).
x = 62 * ns - center
y = 32 * ns - center
r = math.hypot(x, y)
p = A * r**3 + B * r**2 + C * r + 1
gx, gy = x * p, y * p
sx = (gx + center) / ns
sy = (gy + center) / ns
print("dest (62,32) -> source: sx=%.9f sy=%.9f" % (sx, sy))

# Vignetting multiplier at that source position, from the 24mm pa sample rescaled.
k1, k2, k3 = -0.3, 0.1, 0.0
h_v = rf_i / hugin_scale
r2 = gx * gx + gy * gy
c = 1 + k1 * h_v**2 * r2 + k2 * h_v**4 * r2**2 + k3 * h_v**6 * r2**3
print("vignetting multiplier at that position: 1/c = %.9f" % (1 / c))
