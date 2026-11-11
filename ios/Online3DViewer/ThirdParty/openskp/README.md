# OpenSKP native reader

Upstream: https://github.com/iamahsanmehmood/openskp

Pinned commit: `c98561147ea502c6d4d53a257fa4581d0c6cde1d` (MIT). This is distinct from other projects using the OpenSKP name.

ZIP dependency: richgel999/miniz `77d0dce8627735138c51770d1799a1ef48f2117d` (MIT).

`tools/build_openskp.py` checksum-verifies both source archives and builds only the reader, topology and triangulation code. Exporters, TinyGLTF, FlatBuffers and writer scaffolds are excluded. The generated source is in `build/ios/openskp-bounded-src`; `O3DV_PATCHES.txt` records its recipe fingerprint. Container/shared-node allocation uses `SkpMemory.hpp`, without replacing global new/delete. Patches also propagate resource errors through optional-record recovery, add cooperative checkpoints, preserve face layers/visibility, and resolve inherited and separate front/back textures.

`SkpStreamReader.mm` converts the parsed geometry directly into existing App geometry caches, retaining definition instances and independent edges. It does not create an intermediate whole-scene GLB.
