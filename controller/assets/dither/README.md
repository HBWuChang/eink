# Full-frame blue-noise thresholds

`blue_noise_768x552.u16be`: 768 columns × 552 rows, row-major unsigned
16-bit big-endian thresholds, no header (847872 bytes).
Use `(value + 0.5) / 65536` for threshold lookup; do not resize the mask.

Generated locally with Void-and-Cluster, periodic boundaries, Gaussian sigma
1.5 truncated at 6 sigma, 10% initial occupancy, mt19937 seed 20261024.
Full ranks formed a permutation of 0..423935 before normalization to 16 bits.
Measured generation: 201.034 seconds, Apple M4, C++17 clang -O3, one thread.

The image pipeline chooses the closest of the six two-color mixtures in linear
RGB using the app's existing black/white/yellow/red palette, then compares the
mixture fraction with this mask. It does not generate noise at runtime.
This two-color approximation is not a full four-color gamut optimization.

Generation algorithm: https://cv.ulichney.com/papers/1993-void-cluster.pdf

To regenerate from the controller directory (macOS):

```sh
xcrun clang++ -O3 -std=c++17 tool/generate_blue_noise.cpp -o /tmp/eink-blue-noise
/tmp/eink-blue-noise 768 552 /tmp/eink-blue-noise.pgm
python3 -c "from pathlib import Path; Path('assets/dither/blue_noise_768x552.u16be').write_bytes(Path('/tmp/eink-blue-noise.pgm').read_bytes().split(b'\\n', 3)[3])"
```
