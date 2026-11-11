#include <openskp/parser.hpp>
#include <chrono>
#include <iostream>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
        openskp::ParseOptions options;
        options.log = [](openskp::LogLevel, std::string_view text) { std::cerr << text << '\n'; };
        auto start = std::chrono::steady_clock::now();
        auto file = openskp::SkpFile::open(argv[1]);
        auto scene = file.build_instanced_scene(options);
        size_t triangles = 0, vertices = 0, nodes = 0, placements = 0;
        std::map<std::string, size_t> faces;
        for (const auto &mesh : scene.mesh_resources) {
            size_t n = 0;
            for (const auto &p : mesh.primitives) {
                n += p.indices.size() / 3;
                vertices += p.positions.size() / 3;
            }
            faces[mesh.id] = n;
        }
        std::function<void(const openskp::InstancedNode &)> walk = [&](const auto &n) {
            nodes++;
            if (n.mesh_resource_id) { placements++; triangles += faces.at(*n.mesh_resource_id); }
            for (const auto &child : n.children) walk(child);
        };
        walk(scene.scene_hierarchy);
        std::cout << "{\"nodes\":" << nodes << ",\"placements\":" << placements
                  << ",\"resources\":" << scene.mesh_resources.size() << ",\"vertices\":" << vertices
                  << ",\"triangles\":" << triangles << ",\"materials\":" << scene.gltf_materials.size()
                  << ",\"textures\":" << scene.textures.size() << ",\"seconds\":"
                  << std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() << "}\n";
    } catch (const std::exception &e) { std::cerr << "ERROR " << e.what() << '\n'; return 1; }
}
