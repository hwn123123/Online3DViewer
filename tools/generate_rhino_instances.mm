// Independent source scenes for nested instances, affine placement and failure paths.
#import <Foundation/Foundation.h>
#include "opennurbs.h"
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
static ON_UUID uuid(){ON_UUID value;ON_CreateUuid(value);return value;}
static ON_3dmObjectAttributes *attributes(ON_UUID id,const wchar_t *name,int layer,bool member){auto *a=new ON_3dmObjectAttributes();a->m_uuid=id;a->SetName(name,true);a->m_layer_index=layer;if(member)a->SetMode(ON::idef_object);return a;}
static void addGeometry(ONX_Model &m,ON_Geometry *g,ON_3dmObjectAttributes *a){auto ref=m.AddManagedModelGeometryComponent(g,a);assert(!ref.IsEmpty());}
static void addDefinition(ONX_Model &m,ON_UUID id,const wchar_t *name,std::vector<ON_UUID> members){ON_InstanceDefinition d;d.SetId(id);d.SetName(name);ON_SimpleArray<ON_UUID> list;for(auto v:members)list.Append(v);d.SetInstanceGeometryIdList(list);d.SetBoundingBox(ON_BoundingBox(ON_3dPoint(-2,-2,-2),ON_3dPoint(2,2,2)));assert(!m.AddModelComponent(d).IsEmpty());}
static void addReference(ONX_Model &m,ON_UUID id,ON_UUID definition,const wchar_t *name,const ON_Xform &x,int layer,bool member,int material=-1,bool hidden=false){auto *r=new ON_InstanceRef();r->m_instance_definition_uuid=definition;r->m_xform=x;r->m_bbox=ON_BoundingBox(ON_3dPoint(-2,-2,-2),ON_3dPoint(2,2,2));r->m_bbox.Transform(x);auto *a=attributes(id,name,layer,member);a->SetMaterialSource(member?ON::material_from_parent:ON::material_from_object);a->m_material_index=material;a->SetColorSource(member?ON::color_from_parent:ON::color_from_object);a->m_color=ON_Color(230,40,20);if(hidden)a->SetMode(ON::hidden_object);addGeometry(m,r,a);}
static void save(ONX_Model &m,const std::string &directory,const char *name){ON_TextLog errors;std::string path=directory+"/"+name;assert(m.Write(path.c_str(),80,&errors));}
int main(int argc,char **argv){if(argc!=2)return 2;ON::Begin();std::string out=argv[1];
 {
  ONX_Model model;model.AddDefaultLayer(L"Prototype",ON_Color(20,180,40));int placements=model.AddLayer(L"Placements",ON_Color(220,50,20));
  ON_Layer hidden;hidden.SetId(uuid());hidden.SetName(L"Hidden parent");hidden.SetVisible(false);auto hiddenRef=model.AddModelComponent(hidden);assert(!hiddenRef.IsEmpty());
  ON_Layer child;child.SetId(uuid());child.SetName(L"Child of hidden");child.SetParentLayerId(hiddenRef.ModelComponent()->Id());child.SetVisible(true);auto childRef=model.AddModelComponent(child);assert(!childRef.IsEmpty());
  int hiddenChild=childRef.ModelComponent()->Index();
  ON_Material red;red.SetName(L"Red material");red.SetDiffuse(ON_Color(220,20,30));auto redRef=model.AddModelComponent(red);assert(!redRef.IsEmpty());
  ON_Material blue;blue.SetName(L"Blue material");blue.SetDiffuse(ON_Color(20,40,220));blue.SetTransparency(.35);auto blueRef=model.AddModelComponent(blue);assert(!blueRef.IsEmpty());
  ON_UUID meshId=uuid(),curveId=uuid(),definitionA=uuid(),definitionB=uuid(),empty=uuid(),nestedA=uuid(),nestedB=uuid();
  auto *mesh=new ON_Mesh();const int n=64;for(int y=0;y<n;y++)for(int x=0;x<n;x++){double px=-1+2.*x/(n-1),py=-1+2.*y/(n-1);mesh->SetVertex(y*n+x,ON_3dPoint(px+1,py+2,.3*px+.2*py+3));mesh->SetVertexNormal(y*n+x,ON_3dVector(-.3,-.2,1));}
  int face=0;for(int y=0;y<n-1;y++)for(int x=0;x<n-1;x++){int a=y*n+x;mesh->SetTriangle(face++,a,a+1,a+n);mesh->SetTriangle(face++,a+1,a+n+1,a+n);}
  auto *ma=attributes(meshId,L"Sloped mesh",0,true);ma->SetMaterialSource(ON::material_from_parent);addGeometry(model,mesh,ma);
  auto *curve=new ON_PolylineCurve();ON_3dPointArray points;points.Append(ON_3dPoint(-1,-1,-.5));points.Append(ON_3dPoint(0,0,-.5));points.Append(ON_3dPoint(1,1,-.5));*curve=ON_PolylineCurve(points);auto *ca=attributes(curveId,L"Diagonal curve",0,true);ca->SetColorSource(ON::color_from_parent);ca->SetMaterialSource(ON::material_from_parent);addGeometry(model,curve,ca);
  addDefinition(model,definitionA,L"Definition A",{meshId,curveId});
  ON_Xform local1=ON_Xform::TranslationTransformation(-1,-2,-3),local2=ON_Xform::IdentityTransformation;local2.m_xform[0][0]=-1;local2.m_xform[1][1]=1.3;local2.m_xform[2][2]=.7;local2.m_xform[0][3]=3;local2.m_xform[1][3]=-2.6;local2.m_xform[2][3]=-2.1;
  addReference(model,nestedA,definitionA,L"Nested identity",local1,0,true);addReference(model,nestedB,definitionA,L"Nested mirror",local2,0,true);
  addDefinition(model,definitionB,L"Definition B",{nestedA,nestedB});addDefinition(model,empty,L"Empty definition",{});
  ON_Xform root1=ON_Xform::IdentityTransformation;root1.m_xform[0][0]=1.2;root1.m_xform[1][1]=.8;root1.m_xform[2][2]=1.1;root1.m_xform[0][3]=-4;root1.m_xform[1][3]=-4;root1.m_xform[2][3]=1;
  ON_Xform root2=ON_Xform::IdentityTransformation;root2.m_xform[0][1]=.3;root2.m_xform[2][1]=.1;root2.m_xform[0][3]=4;root2.m_xform[1][3]=3;
  ON_Xform rotate;rotate.Rotation(ON_PI/6,ON_3dVector::XAxis,ON_3dPoint::Origin);root2=root2*rotate;
  addReference(model,uuid(),definitionB,L"Root red",root1,placements,false,redRef.ModelComponent()->Index());
  addReference(model,uuid(),definitionB,L"Root blue shear",root2,placements,false,blueRef.ModelComponent()->Index());
  addReference(model,uuid(),definitionB,L"Hidden object",ON_Xform::TranslationTransformation(4,-4,0),placements,false,redRef.ModelComponent()->Index(),true);
  addReference(model,uuid(),definitionB,L"Hidden parent layer",ON_Xform::TranslationTransformation(-4,4,0),hiddenChild,false,redRef.ModelComponent()->Index());
  addReference(model,uuid(),empty,L"Empty block",ON_Xform::IdentityTransformation,placements,false);
  save(model,out,"nested-affine.3dm");
 }
 for(const auto &kind:std::vector<std::string>{"missing-definition","missing-member","cycle","unsupported-member"}){
  ONX_Model model;model.AddDefaultLayer(L"Layer",ON_Color::Black);ON_UUID def=uuid(),member=uuid();
  if(kind=="missing-member")addDefinition(model,def,L"Missing member",{member});
  if(kind=="cycle"){addReference(model,member,def,L"Recursive",ON_Xform::IdentityTransformation,0,true);addDefinition(model,def,L"Cycle",{member});}
  if(kind=="unsupported-member"){addGeometry(model,new ON_Point(ON_3dPoint::Origin),attributes(member,L"Point",0,true));addDefinition(model,def,L"Unsupported point",{member});}
  addReference(model,uuid(),def,L"Root",ON_Xform::IdentityTransformation,0,false);save(model,out,(kind+".3dm").c_str());
 }
 puts("Generated nested affine, empty, missing and recursive block fixtures");return 0;
}
