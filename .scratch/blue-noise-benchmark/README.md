# Local blue-noise generation benchmark

C++17, single thread, clang++ -O3, Apple M4. Seed: 20261024.
Void-and-Cluster ranked threshold mask, periodic boundaries, Gaussian sigma 1.5,
truncated at radius 9 (6 sigma), initial occupancy 10%. All phases generate a
complete permutation of pixel ranks, checked before export. This implementation
scans all pixels when selecting extrema; it is not a performance upper bound.

Reproduce from repository root:

```sh
xcrun clang++ -O3 -std=c++17 .scratch/blue-noise-benchmark/benchmark.cpp -o .scratch/blue-noise-benchmark/benchmark
.scratch/blue-noise-benchmark/benchmark 768 552 .scratch/blue-noise-benchmark/blue-noise-768x552.pgm
python3 .scratch/blue-noise-benchmark/preview.py
```

Outputs:
- PGM: 16-bit big-endian normalized threshold mask.
- PNG: 8-bit grayscale preview, suitable for simple threshold lookup with reduced precision.
- rank-u32: full unique ranks, native little-endian uint32 on this Mac; threshold = (rank + 0.5) / (768 * 552).
- threshold-slices.png: white fractions 25%, 50%, 75% from left to right.

The mask is independent of the four-color palette. It is not a ready-to-display
black/white/red/yellow image. Numerical checks and visual inspection do not prove
optimal spectral quality or real-panel appearance. Timing includes initialization,
rank validation and (when requested) file export; excludes compilation.
