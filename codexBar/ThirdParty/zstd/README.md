# Zstandard decoder

The bundled decompressor is generated from [facebook/zstd v1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7).
It is compiled into Codexbar so DSH transcript reading does not require a separately installed zstd executable or library.

To reproduce zstddeclib.c from the upstream release:

    python3 build/single_file_libs/combine.py \
      -r lib -x legacy/zstd_legacy.h \
      -o zstddeclib.c build/single_file_libs/zstddeclib-in.c

The upstream zstd.h and LICENSE are included for API reference and license attribution.
