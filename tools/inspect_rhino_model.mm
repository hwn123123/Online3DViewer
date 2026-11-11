#import <Foundation/Foundation.h>
#include "opennurbs.h"
#include <cstdio>
#include <memory>

static NSString *ID(ON_UUID id){char text[40]={};ON_UuidToString(id,text);return [NSString stringWithUTF8String:text];}
static NSString *Text(const ON_wString &s){ON_String text(s);return [NSString stringWithUTF8String:static_cast<const char *>(text)]?:@"";}
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2){fprintf(stderr,"usage: inspect-rhino input.3dm\n");return 2;}ON::Begin();
 std::unique_ptr<FILE,decltype(&fclose)> file(ON::OpenFile(argv[1],"rb"),&fclose);if(!file)return 1;
 ON_BinaryFile archive(ON::archive_mode::read3dm,file.get());ONX_Model model;
 if(!model.IncrementalReadBegin(archive,true,0,nullptr))return 1;
 NSMutableArray *definitions=[NSMutableArray array],*objects=[NSMutableArray array];NSMutableDictionary *classes=[NSMutableDictionary dictionary];
 ONX_ModelComponentIterator defs(model,ON_ModelComponent::Type::InstanceDefinition);
 for(auto *c=defs.FirstComponent();c;c=defs.NextComponent())if(auto *d=ON_InstanceDefinition::Cast(c)){
  NSMutableArray *members=[NSMutableArray array];const auto &ids=d->InstanceGeometryIdList();for(int i=0;i<ids.Count();i++)[members addObject:ID(ids[i])];
  [definitions addObject:@{@"id":ID(d->Id()),@"name":Text(d->Name()),@"members":members}];
 }
 for(;;){@autoreleasepool{
  ON_ModelComponentReference ref;if(!model.IncrementalReadModelGeometry(archive,true,true,true,0,ref))return 1;if(ref.IsEmpty())break;
  auto *component=ON_ModelGeometryComponent::FromModelComponentRef(ref,nullptr);auto *g=component?component->Geometry(nullptr):nullptr;auto *a=component?component->Attributes(nullptr):nullptr;if(!g || !a)return 1;
  NSString *cls=[NSString stringWithUTF8String:g->ClassId()->ClassName()];classes[cls]=@([classes[cls] unsignedLongLongValue]+1);
  auto b=g->BoundingBox();NSMutableDictionary *o=[@{@"id":ID(component->Id()),@"class":cls,@"name":Text(a->Name()),@"layer":@(a->m_layer_index),@"definitionMember":@(a->IsInstanceDefinitionObject()),@"visible":@(a->IsVisible()),@"bounds":@[@(b.m_min.x),@(b.m_min.y),@(b.m_min.z),@(b.m_max.x),@(b.m_max.y),@(b.m_max.z)]} mutableCopy];
  if(auto *instance=ON_InstanceRef::Cast(g)){o[@"definitionId"]=ID(instance->m_instance_definition_uuid);NSMutableArray *matrix=[NSMutableArray array];for(int row=0;row<4;row++)for(int col=0;col<4;col++)[matrix addObject:@(instance->m_xform.m_xform[row][col])];o[@"transform"]=matrix;}
  [objects addObject:o];model.RemoveModelComponent(ON_ModelComponent::Type::ModelGeometry,component->Id());ref=ON_ModelComponentReference::Empty;
 }}
 if(!model.IncrementalReadFinish(archive,true,0,nullptr))return 1;
 NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"classes":classes,@"definitions":definitions,@"objects":objects,@"tolerance":@(model.m_settings.m_ModelUnitsAndTolerances.m_absolute_tolerance)} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if(!data)return 1;fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
}}
