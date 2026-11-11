#import "RhinoStreamReader.h"
#include "opennurbs.h"
#include "NativeReadLock.hpp"
#include "NativeMemory.hpp"
#include "RhinoInstances.hpp"
#include <mach/mach.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

@implementation RhinoReadCancellation
@end

namespace {
NSString *Text(const ON_wString &value) {
    ON_String utf8(value);
    return [NSString stringWithUTF8String:static_cast<const char *>(utf8)] ?: @"";
}

NSString *UUIDText(ON_UUID value) {
    char buffer[40] = {};
    ON_UuidToString(value, buffer);
    return [NSString stringWithUTF8String:buffer];
}

NSArray *Color(ON_Color c) { return @[@(c.Red() / 255.0), @(c.Green() / 255.0), @(c.Blue() / 255.0)]; }

NSArray *Bounds(const ON_BoundingBox &box) {
    if (!box.IsValid()) return @[@0, @0, @0, @0, @0, @0];
    return @[@(box.m_min.x), @(box.m_min.y), @(box.m_min.z), @(box.m_max.x), @(box.m_max.y), @(box.m_max.z)];
}

uint64_t ResidentBytes() {
    mach_task_basic_info_data_t info = {};
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&info), &size) == KERN_SUCCESS ? info.resident_size : 0;
}

struct GeometryBuffer {
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;
    std::vector<float> lines;
    std::vector<float> colors;
    bool hasColors = false;
    ON_3dPoint origin = ON_3dPoint::Origin;

    void appendMesh(const ON_Mesh &mesh) {
        uint32_t offset = static_cast<uint32_t>(positions.size() / 3);
        int count = mesh.VertexCount();
        bool colored = mesh.m_C.Count() == count;
        hasColors |= colored;
        bool hasNormals = mesh.HasVertexNormals();
        if (!hasNormals) hasNormals = const_cast<ON_Mesh &>(mesh).ComputeVertexNormals();
        for (int i = 0; i < count; ++i) {
            ON_3dPoint v = mesh.Vertex(i);
            positions.insert(positions.end(), {float(v.x - origin.x), float(v.y - origin.y), float(v.z - origin.z)});
            ON_3fVector n = hasNormals ? mesh.m_N[i] : ON_3fVector(0, 0, 1);
            normals.insert(normals.end(), {n.x, n.y, n.z});
            ON_Color c = colored ? mesh.m_C[i] : ON_Color::White;
            colors.insert(colors.end(), {float(c.Red() / 255.0), float(c.Green() / 255.0), float(c.Blue() / 255.0)});
        }
        for (int i = 0; i < mesh.m_F.Count(); ++i) {
            const ON_MeshFace &f = mesh.m_F[i];
            bool valid = true;
            for (int v : f.vi) if (v < 0 || v >= count) valid = false;
            if (!valid) continue;
            indices.insert(indices.end(), {offset + uint32_t(f.vi[0]), offset + uint32_t(f.vi[1]), offset + uint32_t(f.vi[2])});
            if (!f.IsTriangle()) indices.insert(indices.end(), {offset + uint32_t(f.vi[0]), offset + uint32_t(f.vi[2]), offset + uint32_t(f.vi[3])});
        }
    }

    void segment(const ON_3dPoint &a, const ON_3dPoint &b) {
        lines.insert(lines.end(), {float(a.x - origin.x), float(a.y - origin.y), float(a.z - origin.z),
                                   float(b.x - origin.x), float(b.y - origin.y), float(b.z - origin.z)});
    }

    void appendCurve(const ON_Curve &curve, double tolerance) {
        ON_SimpleArray<ON_3dPoint> polyline;
        if (curve.IsPolyline(&polyline, nullptr) > 0) {
            for (int i = 1; i < polyline.Count(); ++i) segment(polyline[i - 1], polyline[i]);
            return;
        }
        std::function<void(double, double, ON_3dPoint, ON_3dPoint, int)> subdivide;
        subdivide = [&](double a, double b, ON_3dPoint pa, ON_3dPoint pb, int depth) {
            double mid = (a + b) * 0.5;
            ON_3dPoint pm = curve.PointAt(mid);
            ON_3dPoint chord = (pa + pb) * 0.5;
            if (depth < 12 && pm.DistanceTo(chord) > tolerance) {
                subdivide(a, mid, pa, pm, depth + 1);
                subdivide(mid, b, pm, pb, depth + 1);
            } else segment(pa, pb);
        };
        int count = std::max(1, curve.SpanCount());
        std::vector<double> spans(count + 1);
        if (!curve.GetSpanVector(spans.data())) {
            count = 1;
            spans = {curve.Domain().Min(), curve.Domain().Max()};
        }
        for (int i = 0; i < count; ++i) {
            // Seed each span to retain closed arcs whose midpoint lies on the chord.
            for (int s = 0; s < 4; ++s) {
                double a = spans[i] + (spans[i + 1] - spans[i]) * s / 4.0;
                double b = spans[i] + (spans[i + 1] - spans[i]) * (s + 1) / 4.0;
                subdivide(a, b, curve.PointAt(a), curve.PointAt(b), 0);
            }
        }
    }

    uint64_t write(NSString *path) const {
        std::unique_ptr<FILE, decltype(&fclose)> file(fopen(path.fileSystemRepresentation, "wb"), &fclose);
        if (!file) return 0;
        uint32_t header[8] = {0x3144334f, 1, uint32_t(positions.size() / 3), uint32_t(indices.size()),
                              uint32_t(lines.size() / 3), uint32_t(hasColors), 0, 0};
        uint64_t bytes = sizeof(header);
        if (fwrite(header, 1, sizeof(header), file.get()) != sizeof(header)) return 0;
        auto append = [&](const auto &values) {
            size_t size = values.size() * sizeof(typename std::decay_t<decltype(values)>::value_type);
            if (size && fwrite(values.data(), 1, size, file.get()) != size) return false;
            bytes += size;
            return true;
        };
        if (!append(positions) || !append(normals) || !append(indices) || !append(lines) || (hasColors && !append(colors))) return 0;
        return bytes;
    }
};
}

@implementation RhinoStreamReader
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory
          progress:(void (^)(NSDictionary<NSString *, id> *))progress
      cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    static std::once_flag initialized;
    std::call_once(initialized, [] { ON::Begin(); });
    NSString *failureMessage=nil;
    auto fail = [&](NSString *message) {
        failureMessage=message;
        return NO;
    };
    auto read = [&]() -> BOOL {
    @try {
        std::unique_lock<std::mutex> readLock(o3dv::NativeReadMutex());
        if (cancellation.cancelled) return fail(@"读取已取消。");
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error];
        std::unique_ptr<FILE, decltype(&fclose)> file(ON::OpenFile(source.fileSystemRepresentation, "rb"), &fclose);
        if (!file) return fail(@"无法读取 3DM 文件。");
        ON_BinaryFile archive(ON::archive_mode::read3dm, file.get());
        ONX_Model model;
        if (!model.IncrementalReadBegin(archive, true, 0, nullptr)) return fail(@"无法读取 3DM 的图层和材质信息。");
        NSMutableArray *layers = [NSMutableArray array], *materials = [NSMutableArray array], *objects = [NSMutableArray array];
        NSMutableArray *unsupported = [NSMutableArray array];
        o3dv::RhinoInstances instanceResolver(model);
        uint64_t sourceObjectCount=0;
        ONX_ModelComponentIterator layerIterator(model, ON_ModelComponent::Type::Layer);
        for (const ON_ModelComponent *c = layerIterator.FirstComponent(); c; c = layerIterator.NextComponent()) {
            const ON_Layer *layer = ON_Layer::Cast(c);
            if (layer) [layers addObject:@{@"id": UUIDText(layer->Id()), @"index": @(layer->Index()), @"name": Text(layer->Name()),
                @"parentId": UUIDText(layer->ParentLayerId()), @"color": Color(layer->Color()), @"visible": @(layer->IsVisible())}];
        }
        ONX_ModelComponentIterator materialIterator(model, ON_ModelComponent::Type::RenderMaterial);
        for (const ON_ModelComponent *c = materialIterator.FirstComponent(); c; c = materialIterator.NextComponent()) {
            const ON_Material *material = ON_Material::Cast(c);
            if (material) [materials addObject:@{@"id": UUIDText(material->Id()), @"index": @(material->Index()),
                @"name": Text(material->Name()), @"color": Color(material->Diffuse()), @"opacity": @(1.0 - material->Transparency())}];
        }
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:source error:nil];
        NSMutableDictionary *manifest = [@{@"format": @"o3dv-stream-1", @"reader":@"opennurbs-instances-1", @"name": source.lastPathComponent,
            @"sourceBytes": attributes[NSFileSize] ?: @0, @"layers": layers, @"materials": materials,
            @"objects": objects, @"unsupported": unsupported, @"complete": @NO, @"objectCount": @0,
            @"geometryBytes": @0, @"nativePeakMemoryBytes": @0} mutableCopy];
        NSString *manifestPath = [directory stringByAppendingPathComponent:@"manifest.json"];
        uint64_t peak = 0, geometryBytes = 0, triangles = 0, vertices = 0, lineSegments = 0;
        ON_BoundingBox allBounds;
        auto lastPublish = std::chrono::steady_clock::now();
        auto publish = [&](NSString *phase) {
            @autoreleasepool {
            peak = std::max(peak, ResidentBytes());
            manifest[@"objectCount"] = @(objects.count);
            manifest[@"sourceObjectCount"] = @(sourceObjectCount);
            manifest[@"instanceReferenceCount"] = @(instanceResolver.referenceCount);
            manifest[@"instanceLeafCount"] = @(instanceResolver.leafCount);
            manifest[@"geometryBytes"] = @(geometryBytes);
            manifest[@"nativePeakMemoryBytes"] = @(peak);
            manifest[@"triangles"] = @(triangles);
            manifest[@"vertices"] = @(vertices);
            manifest[@"lineSegments"] = @(lineSegments);
            manifest[@"bounds"] = Bounds(allBounds);
            NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
            [data writeToFile:manifestPath options:NSDataWritingAtomic error:nil];
            progress(@{@"phase": phase, @"objects": @(sourceObjectCount), @"layers": layers, @"geometryBytes": @(geometryBytes),
                @"bytesRead": @(archive.CurrentPosition()), @"sourceBytes": manifest[@"sourceBytes"],
                @"nativePeakMemoryBytes": @(peak), @"unsupportedCount": @(unsupported.count)});
            }
            lastPublish = std::chrono::steady_clock::now();
        };
        publish(@"ready");
        for (;;) {
            if (cancellation.cancelled) return fail(@"读取已取消。");
            auto memory=o3dv::SampleMemory();
            if(memory.footprint>512*o3dv::MemoryMiB || (memory.availableKnown && memory.available<32*o3dv::MemoryMiB))
                return fail(@"设备当前内存不足，已停止读取模型。");
            @autoreleasepool {
                ON_ModelComponentReference reference;
                if (!model.IncrementalReadModelGeometry(archive, true, true, true, 0, reference)) return fail(@"读取 3DM 对象时发生错误。");
                if (reference.IsEmpty()) break;
                memory=o3dv::SampleMemory();
                if(memory.footprint>512*o3dv::MemoryMiB || (memory.availableKnown && memory.available<32*o3dv::MemoryMiB))
                    return fail(@"单个 3DM 对象超出当前解析内存预算，已停止读取。");
                const ON_ModelGeometryComponent *component = ON_ModelGeometryComponent::FromModelComponentRef(reference, nullptr);
                const ON_Geometry *geometry = component ? component->Geometry(nullptr) : nullptr;
                const ON_3dmObjectAttributes *attr = component ? component->Attributes(nullptr) : nullptr;
                if (!geometry || !attr) return fail(@"3DM 对象缺少几何或属性。");
                sourceObjectCount++;
                ON_BoundingBox box = geometry->BoundingBox();
                GeometryBuffer buffer;
                if (box.IsValid()) buffer.origin = box.Center();
                NSString *type = [NSString stringWithUTF8String:geometry->ClassId()->ClassName()];
                const ON_InstanceRef *instance=ON_InstanceRef::Cast(geometry);
                if(instance)type=@"InstanceReference";
                if (const ON_Mesh *mesh = ON_Mesh::Cast(geometry)) {
                    type = @"Mesh";
                    buffer.appendMesh(*mesh);
                } else if (const ON_Brep *brep = ON_Brep::Cast(geometry)) {
                    type = @"Brep";
                    for (int i = 0; i < brep->m_F.Count(); ++i) {
                        const ON_Mesh *mesh = brep->m_F[i].Mesh(ON::render_mesh);
                        if (!mesh) mesh = brep->m_F[i].Mesh(ON::any_mesh);
                        if (mesh) buffer.appendMesh(*mesh);
                    }
                } else if (const ON_Extrusion *extrusion = ON_Extrusion::Cast(geometry)) {
                    type = @"Extrusion";
                    const ON_Mesh *mesh = extrusion->Mesh(ON::render_mesh);
                    if (!mesh) mesh = extrusion->Mesh(ON::any_mesh);
                    if (mesh) buffer.appendMesh(*mesh);
                } else if (const ON_Curve *curve = ON_Curve::Cast(geometry)) {
                    type = @"Curve";
                    buffer.appendCurve(*curve, std::max(0.0001, model.m_settings.m_ModelUnitsAndTolerances.m_absolute_tolerance * 0.5));
                }
                const ON_Layer *layer = ON_Layer::FromModelComponentRef(model.LayerFromIndex(attr->m_layer_index), nullptr);
                int materialIndex = attr->MaterialSource() != ON::material_from_object && layer ? layer->RenderMaterialIndex() : attr->m_material_index;
                const ON_Material *material = ON_Material::FromModelComponentRef(model.MaterialFromIndex(materialIndex), nullptr);
                ON_Color display = attr->ColorSource() == ON::color_from_object ? attr->m_color : (layer ? layer->Color() : ON_Color(180, 185, 190));
                if(attr->ColorSource()==ON::color_from_material && material)display=material->Diffuse();
                ON_Color diffuse = material ? material->Diffuse() : display;
                NSString *filename = [NSString stringWithFormat:@"object-%06lu.bin", (unsigned long)objects.count];
                uint64_t bytes = buffer.write([directory stringByAppendingPathComponent:filename]);
                if (!bytes) return fail(@"无法写入模型的本地几何缓存。");
                bool available = !buffer.positions.empty() || !buffer.lines.empty();
                NSString *identifier = UUIDText(component->Id());
                if (!available && !instance) [unsupported addObject:@{@"id": identifier, @"type": type, @"name": Text(attr->Name())}];
                NSMutableDictionary *item=[@{@"id": identifier, @"index": @(objects.count), @"name": Text(attr->Name()), @"type": type,
                    @"layerIndex": @(attr->m_layer_index), @"materialIndex": @(materialIndex), @"color": Color(diffuse),
                    @"lineColor": Color(display), @"opacity": @(material ? 1.0 - material->Transparency() : 1.0),
                    @"visible": @(attr->IsVisible()), @"definitionMember": @(attr->IsInstanceDefinitionObject()),
                    @"bounds": Bounds(box), @"origin": @[@(buffer.origin.x), @(buffer.origin.y), @(buffer.origin.z)],
                    @"url": filename, @"bytes": @(bytes), @"vertices": @(buffer.positions.size() / 3),
                    @"triangles": @(buffer.indices.size() / 3), @"lineSegments": @(buffer.lines.size() / 6), @"available": @(available),
                    @"colorSource":@(attr->ColorSource()),@"materialSource":@(attr->MaterialSource())} mutableCopy];
                if(instance){item[@"instanceDefinitionId"]=o3dv::RhinoID(instance->m_instance_definition_uuid);item[@"instanceTransform"]=o3dv::RhinoMatrix(instance->m_xform);}
                [objects addObject:item];
                geometryBytes += bytes;
                triangles += buffer.indices.size() / 3;
                vertices += buffer.positions.size() / 3;
                lineSegments += buffer.lines.size() / 6;
                if (box.IsValid()) {
                    if (allBounds.IsValid()) allBounds.Union(box); else allBounds = box;
                }
                peak = std::max(peak, ResidentBytes());
                // Release each B-rep / extrusion before reading the next one.
                model.RemoveModelComponent(ON_ModelComponent::Type::ModelGeometry, component->Id());
                reference = ON_ModelComponentReference::Empty;
            }
            if (objects.count == 1 || (objects.count % 8 == 0 &&
                std::chrono::steady_clock::now() - lastPublish >= std::chrono::milliseconds(250))) publish(@"progress");
        }
        if (!model.IncrementalReadFinish(archive, true, 0, nullptr)) return fail(@"3DM 尾部数据校验失败。");
        progress(@{@"phase":@"instances",@"objects":@(sourceObjectCount)});
        instanceResolver.resolve(objects,unsupported,materials,[cancellation]{return bool(cancellation.cancelled);});
        manifest[@"sourceTriangles"]=@(triangles);
        triangles=0;vertices=0;lineSegments=0;allBounds.Destroy();
        for(NSDictionary *item in objects)if([item[@"available"] boolValue] && ![item[@"definitionMember"] boolValue]) {
            triangles+=[item[@"triangles"] unsignedLongLongValue];vertices+=[item[@"vertices"] unsignedLongLongValue];lineSegments+=[item[@"lineSegments"] unsignedLongLongValue];
            NSArray *b=item[@"bounds"];ON_BoundingBox box(ON_3dPoint([b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue]),ON_3dPoint([b[3] doubleValue],[b[4] doubleValue],[b[5] doubleValue]));
            if(box.IsValid()){if(allBounds.IsValid())allBounds.Union(box);else allBounds=box;}
        }
        manifest[@"complete"] = @YES;
        publish(@"complete");
        return YES;
    } @catch (NSException *exception) {
        return fail(exception.reason ?: @"3DM 解析异常。");
    }
    };
    BOOL success=NO;
    try { success=read(); }
    catch(const std::bad_alloc &) {failureMessage=@"3DM 解析所需内存不足，已停止读取。";}
    catch(const std::exception &exception) {failureMessage=[NSString stringWithUTF8String:exception.what()];}
    // Construct the NSError after all inner autorelease pools have drained.
    if(!success && error) *error=[NSError errorWithDomain:@"RhinoStreamReader" code:1 userInfo:@{NSLocalizedDescriptionKey:failureMessage?:@"3DM 读取失败。"}];
    return success;
}
@end
