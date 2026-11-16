#include <jni.h>
#include "opennurbs.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <locale>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
std::string quote(const std::string &s) {
    static const char hex[]="0123456789abcdef";
    std::string out="\"";
    for (unsigned char c:s) {
        if(c=='"'||c=='\\') {out+='\\';out+=char(c);}
        else if(c<32) {out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}
        else out+=char(c);
    }
    return out+'"';
}
std::string str(const ON_wString &s) { ON_String utf8(s);return static_cast<const char *>(utf8); }
std::string uuid(ON_UUID id) {char value[40]={};ON_UuidToString(id,value);return value;}
std::string num(double value) { if(!std::isfinite(value))return "0";std::ostringstream out;out.imbue(std::locale::classic());out.precision(17);out<<value;return out.str(); }
std::string color(ON_Color c) {return "["+num(c.Red()/255.0)+","+num(c.Green()/255.0)+","+num(c.Blue()/255.0)+"]";}
std::string bounds(const ON_BoundingBox &b) {if(!b.IsValid())return "[0,0,0,0,0,0]";return "["+num(b.m_min.x)+","+num(b.m_min.y)+","+num(b.m_min.z)+","+num(b.m_max.x)+","+num(b.m_max.y)+","+num(b.m_max.z)+"]";}
struct Cancelled : std::runtime_error { Cancelled():std::runtime_error("读取已取消或设备资源不足。"){} };
struct Callback {
    JNIEnv *env; jobject target; jmethodID check,header,object;
    explicit Callback(JNIEnv *env,jobject target):env(env),target(target) {
        jclass cls=env->GetObjectClass(target);
        check=env->GetMethodID(cls,"checkpoint","()V");
        header=env->GetMethodID(cls,"header","(Ljava/lang/String;)V");
        object=env->GetMethodID(cls,"object","(Ljava/lang/String;)V");
        env->DeleteLocalRef(cls);
        if(!check||!header||!object)throw std::runtime_error("无法初始化 3DM 读取器。");
    }
    void checkpoint() {env->CallVoidMethod(target,check);if(env->ExceptionCheck())throw Cancelled();}
    void send(jmethodID method,const std::string &json) {
        // NewStringUTF accepts modified UTF-8; ordinary UTF-8 non-BMP text needs conversion.
        jclass stringClass=env->FindClass("java/lang/String");
        jmethodID constructor=env->GetMethodID(stringClass,"<init>","([BLjava/lang/String;)V");
        jbyteArray bytes=env->NewByteArray(jsize(json.size()));
        if(!bytes)throw std::bad_alloc();
        env->SetByteArrayRegion(bytes,0,jsize(json.size()),reinterpret_cast<const jbyte *>(json.data()));
        jstring charset=env->NewStringUTF("UTF-8");
        auto value=static_cast<jstring>(env->NewObject(stringClass,constructor,bytes,charset));
        env->DeleteLocalRef(bytes);env->DeleteLocalRef(charset);env->DeleteLocalRef(stringClass);
        if(!value||env->ExceptionCheck())throw Cancelled();
        env->CallVoidMethod(target,method,value);env->DeleteLocalRef(value);
        if(env->ExceptionCheck())throw Cancelled();
    }
};
struct Geometry {
    std::vector<float> positions,normals,lines,colors;
    std::vector<uint32_t> indices;
    bool hasColors=false;
    size_t invalidFaces=0;
    ON_3dPoint origin=ON_3dPoint::Origin;
    void appendMesh(const ON_Mesh &mesh,Callback &callback) {
        size_t old=positions.size()/3; int count=mesh.VertexCount();
        if(count<0 || old+size_t(count)>UINT32_MAX)throw std::runtime_error("3DM 对象顶点数量超过支持范围。");
        bool colored=mesh.m_C.Count()==count,normal=mesh.HasVertexNormals();
        if(!normal)normal=const_cast<ON_Mesh&>(mesh).ComputeVertexNormals();
        hasColors|=colored;
        for(int i=0;i<count;i++) {
            if((i&16383)==0)callback.checkpoint();
            ON_3dPoint p=mesh.Vertex(i); ON_3fVector n=normal?mesh.m_N[i]:ON_3fVector(0,0,1);
            positions.insert(positions.end(),{float(p.x-origin.x),float(p.y-origin.y),float(p.z-origin.z)});
            normals.insert(normals.end(),{n.x,n.y,n.z});
            ON_Color c=colored?mesh.m_C[i]:ON_Color::White;
            colors.insert(colors.end(),{float(c.Red()/255.0),float(c.Green()/255.0),float(c.Blue()/255.0)});
        }
        for(int i=0;i<mesh.m_F.Count();i++) {
            if((i&16383)==0)callback.checkpoint();
            const auto &f=mesh.m_F[i];bool valid=true;for(int index:f.vi)if(index<0||index>=count)valid=false;
            if(!valid){++invalidFaces;continue;}
            indices.insert(indices.end(),{uint32_t(old+f.vi[0]),uint32_t(old+f.vi[1]),uint32_t(old+f.vi[2])});
            if(!f.IsTriangle())indices.insert(indices.end(),{uint32_t(old+f.vi[0]),uint32_t(old+f.vi[2]),uint32_t(old+f.vi[3])});
        }
    }
    void segment(ON_3dPoint a,ON_3dPoint b) {lines.insert(lines.end(),{float(a.x-origin.x),float(a.y-origin.y),float(a.z-origin.z),float(b.x-origin.x),float(b.y-origin.y),float(b.z-origin.z)});}
    void curve(const ON_Curve &curve,double tolerance,Callback &callback) {
        ON_SimpleArray<ON_3dPoint> points;
        if(curve.IsPolyline(&points,nullptr)>0) {for(int i=1;i<points.Count();i++){if((i&8191)==0)callback.checkpoint();segment(points[i-1],points[i]);}return;}
        std::function<void(double,double,ON_3dPoint,ON_3dPoint,int)> subdivide;
        subdivide=[&](double a,double b,ON_3dPoint pa,ON_3dPoint pb,int depth) {
            if((lines.size()&8191)==0)callback.checkpoint();
            double mid=(a+b)*.5;ON_3dPoint pm=curve.PointAt(mid),chord=(pa+pb)*.5;
            if(depth<12&&pm.DistanceTo(chord)>tolerance){subdivide(a,mid,pa,pm,depth+1);subdivide(mid,b,pm,pb,depth+1);}else segment(pa,pb);
        };
        int count=std::max(1,curve.SpanCount());std::vector<double> spans(count+1);
        if(!curve.GetSpanVector(spans.data())){count=1;spans={curve.Domain().Min(),curve.Domain().Max()};}
        for(int i=0;i<count;i++)for(int j=0;j<4;j++) {
            double a=spans[i]+(spans[i+1]-spans[i])*j/4.0,b=spans[i]+(spans[i+1]-spans[i])*(j+1)/4.0;
            subdivide(a,b,curve.PointAt(a),curve.PointAt(b),0);
        }
    }
    uint64_t write(const std::string &path) const {
        std::unique_ptr<FILE,decltype(&fclose)> file(fopen(path.c_str(),"wb"),&fclose);
        if(!file)throw std::runtime_error("无法创建模型几何缓存。");
        uint32_t head[8]={0x3144334f,1,uint32_t(positions.size()/3),uint32_t(indices.size()),uint32_t(lines.size()/3),uint32_t(hasColors),0,0};
        uint64_t bytes=sizeof(head);if(fwrite(head,1,sizeof(head),file.get())!=sizeof(head))throw std::runtime_error("模型缓存写入失败。");
        auto append=[&](const auto &v){size_t n=v.size()*sizeof(typename std::decay_t<decltype(v)>::value_type);if(n&&fwrite(v.data(),1,n,file.get())!=n)throw std::runtime_error("模型缓存写入失败。");bytes+=n;};
        append(positions);append(normals);append(indices);append(lines);if(hasColors)append(colors);
        if(fflush(file.get()))throw std::runtime_error("模型缓存写入失败。");return bytes;
    }
};
std::string matrix(const ON_Xform &x) {std::string s="[";for(int col=0;col<4;col++)for(int row=0;row<4;row++){if(col||row)s+=",";s+=num(x.m_xform[row][col]);}return s+"]";}
std::string read(JNIEnv *env,jobject self,const std::string &path,const std::string &dir) {
    static std::once_flag once;std::call_once(once,[]{ON::Begin();});
    Callback cb(env,self);cb.checkpoint();
    std::unique_ptr<FILE,decltype(&fclose)> file(ON::OpenFile(path.c_str(),"rb"),&fclose);
    if(!file)throw std::runtime_error("无法打开 3DM 文件。");
    ON_BinaryFile archive(ON::archive_mode::read3dm,file.get());ONX_Model model;
    if(!model.IncrementalReadBegin(archive,true,0,nullptr))throw std::runtime_error("无法读取 3DM 图层及材质信息。");
    std::string layers="[",materials="[",definitions="[";
    ONX_ModelComponentIterator layerIt(model,ON_ModelComponent::Type::Layer);
    bool first=true;
    for(auto *c=layerIt.FirstComponent();c;c=layerIt.NextComponent())if(auto *v=ON_Layer::Cast(c)) {
        if(!first)layers+=",";first=false;
        layers+="{\"id\":"+quote(uuid(v->Id()))+",\"index\":"+std::to_string(v->Index())+",\"name\":"+quote(str(v->Name()))+",\"parentId\":"+quote(uuid(v->ParentLayerId()))+",\"color\":"+color(v->Color())+",\"visible\":"+(v->IsVisible()?"true":"false")+"}";
    }
    layers+="]";first=true;
    ONX_ModelComponentIterator materialIt(model,ON_ModelComponent::Type::RenderMaterial);
    for(auto *c=materialIt.FirstComponent();c;c=materialIt.NextComponent())if(auto *v=ON_Material::Cast(c)) {
        if(!first)materials+=",";first=false;
        materials+="{\"id\":"+quote(uuid(v->Id()))+",\"index\":"+std::to_string(v->Index())+",\"name\":"+quote(str(v->Name()))+",\"color\":"+color(v->Diffuse())+",\"opacity\":"+num(1-v->Transparency())+"}";
    }
    materials+="]";first=true;
    ONX_ModelComponentIterator defIt(model,ON_ModelComponent::Type::InstanceDefinition);
    for(auto *c=defIt.FirstComponent();c;c=defIt.NextComponent())if(auto *v=ON_InstanceDefinition::Cast(c)) {
        if(!first)definitions+=",";first=false;definitions+="{\"id\":"+quote(uuid(v->Id()))+",\"name\":"+quote(str(v->Name()))+",\"members\":[";
        const auto &ids=v->InstanceGeometryIdList();for(int i=0;i<ids.Count();i++){if(i)definitions+=",";definitions+=quote(uuid(ids[i]));}definitions+="]}";
    }
    definitions+="]";cb.send(cb.header,"{\"layers\":"+layers+",\"materials\":"+materials+",\"definitions\":"+definitions+"}");
    size_t index=0;
    for(;;) {
        cb.checkpoint();ON_ModelComponentReference reference;
        if(!model.IncrementalReadModelGeometry(archive,true,true,true,0,reference))throw std::runtime_error("读取 3DM 对象失败，文件可能损坏。");
        if(reference.IsEmpty())break;cb.checkpoint();
        const auto *component=ON_ModelGeometryComponent::FromModelComponentRef(reference,nullptr);
        const ON_Geometry *g=component?component->Geometry(nullptr):nullptr;
        const ON_3dmObjectAttributes *a=component?component->Attributes(nullptr):nullptr;
        if(!g||!a)throw std::runtime_error("3DM 对象缺少几何或属性。");
        ON_BoundingBox box=g->BoundingBox();Geometry buffer;if(box.IsValid())buffer.origin=box.Center();
        std::string type=g->ClassId()->ClassName();const ON_InstanceRef *instance=ON_InstanceRef::Cast(g);bool missingMesh=false;
        if(instance)type="InstanceReference";
        if(const auto *mesh=ON_Mesh::Cast(g)){type="Mesh";buffer.appendMesh(*mesh,cb);}
        else if(const auto *brep=ON_Brep::Cast(g)){type="Brep";for(int i=0;i<brep->m_F.Count();i++){auto *mesh=brep->m_F[i].Mesh(ON::render_mesh);if(!mesh)mesh=brep->m_F[i].Mesh(ON::any_mesh);if(mesh)buffer.appendMesh(*mesh,cb);else missingMesh=true;}}
        else if(const auto *extr=ON_Extrusion::Cast(g)){type="Extrusion";auto *mesh=extr->Mesh(ON::render_mesh);if(!mesh)mesh=extr->Mesh(ON::any_mesh);if(mesh)buffer.appendMesh(*mesh,cb);else missingMesh=true;}
        else if(const auto *curve=ON_Curve::Cast(g)){type="Curve";buffer.curve(*curve,std::max(.0001,model.m_settings.m_ModelUnitsAndTolerances.m_absolute_tolerance*.5),cb);}
        cb.checkpoint();
        const ON_Layer *layer=ON_Layer::FromModelComponentRef(model.LayerFromIndex(a->m_layer_index),nullptr);
        int mat=a->MaterialSource()!=ON::material_from_object&&layer?layer->RenderMaterialIndex():a->m_material_index;
        const ON_Material *material=ON_Material::FromModelComponentRef(model.MaterialFromIndex(mat),nullptr);
        ON_Color display=a->ColorSource()==ON::color_from_object?a->m_color:(layer?layer->Color():ON_Color(180,185,190));
        if(a->ColorSource()==ON::color_from_material&&material)display=material->Diffuse();
        char filename[48];snprintf(filename,sizeof(filename),"object-%06zu.bin",index);
        uint64_t bytes=buffer.write(dir+"/"+filename);bool available=!buffer.positions.empty()||!buffer.lines.empty();
        std::string json="{\"id\":"+quote(uuid(component->Id()))+",\"index\":"+std::to_string(index)+",\"name\":"+quote(str(a->Name()))+",\"type\":"+quote(type)+",\"layerIndex\":"+std::to_string(a->m_layer_index)+",\"materialIndex\":"+std::to_string(mat)+",\"color\":"+color(material?material->Diffuse():display)+",\"lineColor\":"+color(display)+",\"opacity\":"+num(material?1-material->Transparency():1)+",\"visible\":"+(a->IsVisible()?"true":"false")+",\"definitionMember\":"+(a->IsInstanceDefinitionObject()?"true":"false")+",\"bounds\":"+bounds(box)+",\"origin\":["+num(buffer.origin.x)+","+num(buffer.origin.y)+","+num(buffer.origin.z)+"],\"url\":"+quote(filename)+",\"bytes\":"+std::to_string(bytes)+",\"vertices\":"+std::to_string(buffer.positions.size()/3)+",\"triangles\":"+std::to_string(buffer.indices.size()/3)+",\"lineSegments\":"+std::to_string(buffer.lines.size()/6)+",\"available\":"+(available?"true":"false")+",\"colorSource\":"+std::to_string(a->ColorSource())+",\"materialSource\":"+std::to_string(a->MaterialSource());
        if(instance)json+=",\"instanceDefinitionId\":"+quote(uuid(instance->m_instance_definition_uuid))+",\"instanceTransform\":"+matrix(instance->m_xform);
        if(missingMesh && available)json+=",\"partialReason\":\"部分曲面未保存可用的显示网格\"";
        else if(buffer.invalidFaces)json+=",\"partialReason\":\"模型包含无效网格面，无法显示这些面\"";
        json+="}";cb.send(cb.object,json);++index;
        model.RemoveModelComponent(ON_ModelComponent::Type::ModelGeometry,component->Id());reference=ON_ModelComponentReference::Empty;
    }
    cb.checkpoint();if(!model.IncrementalReadFinish(archive,true,0,nullptr))throw std::runtime_error("3DM 尾部数据校验失败。");
    return "";
}
}
extern "C" JNIEXPORT jstring JNICALL Java_com_hwn_modelviewer_RhinoNativeReader_convertBytes(JNIEnv *env,jobject self,jbyteArray source,jbyteArray directory) {
    std::string path(env->GetArrayLength(source),'\0'),dir(env->GetArrayLength(directory),'\0');
    env->GetByteArrayRegion(source,0,jsize(path.size()),reinterpret_cast<jbyte *>(path.data()));
    env->GetByteArrayRegion(directory,0,jsize(dir.size()),reinterpret_cast<jbyte *>(dir.data()));
    if(env->ExceptionCheck())return nullptr;
    try {auto result=read(env,self,path,dir);return env->NewStringUTF(result.c_str());}
    catch(const std::exception &e){if(env->ExceptionCheck())return nullptr;return env->NewStringUTF(e.what());}
}
