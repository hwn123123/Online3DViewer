#pragma once
#import <Foundation/Foundation.h>
#include "opennurbs.h"
#include "NativeMemory.hpp"
#include <algorithm>
#include <chrono>
#include <functional>
#include <stdexcept>

namespace o3dv {
inline NSString *RhinoID(ON_UUID id) { char text[40]={};ON_UuidToString(id,text);return [NSString stringWithUTF8String:text]; }
inline NSString *RhinoText(const ON_wString &s) { ON_String utf8(s);return [NSString stringWithUTF8String:static_cast<const char *>(utf8)]?:@""; }
inline NSArray *RhinoMatrix(const ON_Xform &matrix) {
    NSMutableArray *values=[NSMutableArray arrayWithCapacity:16];
    for(int column=0;column<4;column++)for(int row=0;row<4;row++)[values addObject:@(matrix.m_xform[row][column])];
    return values;
}
inline ON_Xform RhinoMatrix(NSArray *values) {
    ON_Xform result=ON_Xform::IdentityTransformation;
    if(values.count==16)for(int column=0;column<4;column++)for(int row=0;row<4;row++)result.m_xform[row][column]=[values[column*4+row] doubleValue];
    return result;
}

// Resolve references from compact cache metadata after the incremental reader releases
// source geometry. Every placed leaf shares its definition's binary file on disk.
class RhinoInstances {
public:
    explicit RhinoInstances(const ONX_Model &model) {
        definitions_=[NSMutableDictionary dictionary];
        ONX_ModelComponentIterator iterator(model,ON_ModelComponent::Type::InstanceDefinition);
        for(auto *component=iterator.FirstComponent();component;component=iterator.NextComponent()) {
            if(auto *definition=ON_InstanceDefinition::Cast(component)) {
                NSMutableArray *members=[NSMutableArray array];const auto &ids=definition->InstanceGeometryIdList();
                for(int i=0;i<ids.Count();i++)[members addObject:RhinoID(ids[i])];
                definitions_[RhinoID(definition->Id())]=@{@"name":RhinoText(definition->Name()),@"members":members};
            }
        }
    }
    NSUInteger referenceCount=0,leafCount=0;
    void resolve(NSMutableArray *objects,NSMutableArray *unsupported,NSArray *materials,std::function<bool()> cancelled) {
        bool hasReferences=false;for(NSDictionary *item in objects)if(item[@"instanceDefinitionId"]){hasReferences=true;break;}
        if(!hasReferences)return;
        cancelled_=std::move(cancelled);sources_=[NSMutableDictionary dictionary];materials_=[NSMutableDictionary dictionary];
        for(NSDictionary *item in objects)sources_[item[@"id"]]=item;
        for(NSDictionary *material in materials)materials_[material[@"index"]]=material;
        NSMutableSet *reported=[NSMutableSet set];for(NSDictionary *item in unsupported)[reported addObject:item[@"id"]];
        NSArray *sourceList=[objects copy];
        for(NSMutableDictionary *item in sourceList)if(item[@"instanceDefinitionId"]) {
            checkpoint();referenceCount++;
            NSString *reason=validate(item,[NSMutableSet set],0);
            item[@"referenceResolved"]=@(!reason);
            if(reason && ![reported containsObject:item[@"id"]]) {
                [unsupported addObject:@{@"id":item[@"id"],@"name":item[@"name"],@"type":@"InstanceReference",@"reason":reason}];
                [reported addObject:item[@"id"]];
            }
        }
        for(NSDictionary *item in sourceList)if(item[@"instanceDefinitionId"] && ![item[@"definitionMember"] boolValue]) {
            checkpoint();
            expand(item,ON_Xform::IdentityTransformation,nil,@[],@[],@[],item[@"id"],objects,[NSMutableSet set],0);
        }
        sources_=nil;materials_=nil;
    }
private:
    __strong NSMutableDictionary *definitions_,*sources_,*materials_;
    std::function<bool()> cancelled_;
    std::chrono::steady_clock::time_point lastCheck_;
    void checkpoint() {
        if(cancelled_())throw std::runtime_error("读取已取消。");
        auto now=std::chrono::steady_clock::now();if(now-lastCheck_<std::chrono::milliseconds(100))return;lastCheck_=now;
        auto memory=SampleMemory();if(memory.footprint>512*MemoryMiB || (memory.availableKnown && memory.available<32*MemoryMiB))
            throw std::runtime_error("块实例展开超出当前设备的资源预算，已停止读取。");
    }
    NSString *validate(NSDictionary *item,NSMutableSet *visiting,NSUInteger depth) {
        checkpoint();if(depth>=256)return @"instance_depth_limit";
        NSString *id=item[@"instanceDefinitionId"];if(!id)return [item[@"available"] boolValue]?nil:@"unsupported_definition_geometry";
        auto transform=RhinoMatrix(item[@"instanceTransform"]);
        if(!transform.IsValid() || !transform.IsAffine() || transform.Determinant()==0)return @"invalid_instance_transform";
        NSDictionary *definition=definitions_[id];if(!definition)return @"missing_instance_definition";
        if([visiting containsObject:id])return @"recursive_instance_definition";
        [visiting addObject:id];NSString *failure=nil;
        for(NSString *memberId in definition[@"members"]) {
            NSDictionary *member=sources_[memberId];
            failure=member?validate(member,visiting,depth+1):@"missing_definition_geometry";
            if(failure)break;
        }
        [visiting removeObject:id];return failure;
    }
    NSMutableDictionary *style(NSDictionary *item,NSDictionary *parent) {
        NSMutableDictionary *result=[item mutableCopy];
        if(parent && [item[@"colorSource"] integerValue]==ON::color_from_parent)result[@"lineColor"]=parent[@"lineColor"];
        if(parent && [item[@"materialSource"] integerValue]==ON::material_from_parent)result[@"materialIndex"]=parent[@"materialIndex"];
        NSDictionary *material=materials_[result[@"materialIndex"]];
        if([item[@"colorSource"] integerValue]==ON::color_from_material && material)result[@"lineColor"]=material[@"color"];
        result[@"color"]=material[@"color"]?:result[@"lineColor"];
        result[@"opacity"]=material[@"opacity"]?:@1;
        result[@"visible"]=@([item[@"visible"] boolValue] && (!parent || [parent[@"visible"] boolValue]));
        return result;
    }
    void expand(NSDictionary *item,const ON_Xform &parentTransform,NSDictionary *parentStyle,NSArray *path,NSArray *names,NSArray *layers,
                NSString *root,NSMutableArray *objects,NSMutableSet *visiting,NSUInteger depth) {
        checkpoint();if(depth>=256)return;
        NSMutableDictionary *value=style(item,parentStyle);
        NSMutableArray *nextLayers=[layers mutableCopy];if(![nextLayers containsObject:item[@"layerIndex"]])[nextLayers addObject:item[@"layerIndex"]];
        NSString *definitionId=item[@"instanceDefinitionId"];
        if(definitionId) {
            if([visiting containsObject:definitionId])return;
            NSDictionary *definition=definitions_[definitionId];if(!definition)return;
            auto local=RhinoMatrix(item[@"instanceTransform"]);if(!local.IsValid() || !local.IsAffine() || local.Determinant()==0)return;
            auto transform=parentTransform*local;
            NSMutableArray *nextPath=[path mutableCopy];[nextPath addObject:item[@"id"]];
            NSString *name=[item[@"name"] length]?item[@"name"]:definition[@"name"];
            NSMutableArray *nextNames=[names mutableCopy];if(name.length)[nextNames addObject:name];
            [visiting addObject:definitionId];
            for(NSString *id in definition[@"members"])if(NSDictionary *member=sources_[id])
                expand(member,transform,value,nextPath,nextNames,nextLayers,root,objects,visiting,depth+1);
            [visiting removeObject:definitionId];
            return;
        }
        if(![item[@"available"] boolValue])return;
        NSArray *bounds=item[@"bounds"];
        ON_BoundingBox box(ON_3dPoint([bounds[0] doubleValue],[bounds[1] doubleValue],[bounds[2] doubleValue]),ON_3dPoint([bounds[3] doubleValue],[bounds[4] doubleValue],[bounds[5] doubleValue]));
        if(!box.IsValid() || !box.Transform(parentTransform))throw std::runtime_error("块实例包含无效的几何边界。");
        NSMutableArray *fullPath=[path mutableCopy];[fullPath addObject:item[@"id"]];
        NSMutableArray *fullNames=[names mutableCopy];if([item[@"name"] length])[fullNames addObject:item[@"name"]];
        value[@"id"]=[fullPath componentsJoinedByString:@"/"];value[@"index"]=@(objects.count);
        value[@"name"]=fullNames.count?[fullNames componentsJoinedByString:@" / "]:item[@"type"];
        value[@"definitionMember"]=@NO;value[@"transform"]=RhinoMatrix(parentTransform);
        value[@"bounds"]=@[@(box.m_min.x),@(box.m_min.y),@(box.m_min.z),@(box.m_max.x),@(box.m_max.y),@(box.m_max.z)];
        value[@"visibilityLayers"]=nextLayers;value[@"instanceId"]=root;value[@"instancePath"]=path;value[@"sourceObjectId"]=item[@"id"];
        [objects addObject:value];leafCount++;
    }
};
}
