# Draco native decoder

Source: https://github.com/google/draco/tree/1.5.7
Version: 1.5.7; Apache-2.0 (see LICENSE).
Archive SHA256: bf6b105b79223eab2b86795363dfe5e5356050006a96521477973aba8f036fe1

`tools/build_draco.py` downloads and verifies the pinned source, applies budgeted container aliases / cooperative checkpoints / conservative small-object accounting, and builds a static library. Generated sources are in build/ios/draco-bounded-src and the patch description is O3DV_PATCHES.txt. The allocator is ios/Online3DViewer/DracoMemory.hpp. No global allocation functions are overridden.
