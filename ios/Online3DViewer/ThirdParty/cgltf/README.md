# cgltf

Source: https://github.com/jkuhlmann/cgltf
Commit: `85cd62382dfea638278962690cf515023f33ed00`
License: MIT (see LICENSE).

Used only for bounded glTF JSON metadata and accessor descriptions. Buffers are read from device-local mapped files; cgltf_load_buffers is not used.

Local patch: `cgltf_attribute.draco_id` retains the unsigned 32-bit Draco unique attribute ID; Draco extension attributes are not resolved as glTF accessor indices. The source accessor mapping remains in the primitive's normal attributes array. IDs outside unsigned 32-bit are rejected explicitly.
