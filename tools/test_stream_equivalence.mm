// Compare per-object/material geometry counts and area moments without retaining the entire model.
#import <Foundation/Foundation.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <stdexcept>
#include <vector>
struct Stats {uint64_t triangles=0,lines=0;std::array<long double,10> values={};};
using Groups=std::map<std::string,Stats>;
Groups inspect(NSString *root){
 auto d=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]] options:0 error:nil];
 if(![d[@"complete"] boolValue] || [d[@"unsupported"] count])throw std::runtime_error("incomplete");Groups result;NSMutableDictionary *mats=[NSMutableDictionary dictionary];for(NSDictionary *m in d[@"materials"])mats[m[@"index"]]=[NSString stringWithFormat:@"%@|%@|%@",m[@"name"],m[@"color"],m[@"opacity"]];
 for(NSDictionary *o in d[@"objects"]){@autoreleasepool{
  NSData *data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:o[@"url"]]];auto *head=(const uint32_t *)data.bytes;size_t n=head[2],ni=head[3];if(head[0]!=0x3144334f || head[1]!=2)throw std::runtime_error("header");
  auto *p=(const float *)(head+8),*normal=p+n*3;auto *indices=(const uint32_t *)(normal+n*3);double origin[3];for(int k=0;k<3;k++)origin[k]=[o[@"origin"][k] doubleValue];
  for(NSDictionary *part in o[@"parts"]){NSString *key=[NSString stringWithFormat:@"%@|%@|%@",part[@"name"],mats[o[@"materialIndex"]]?:@"-",o[@"visible"]];auto &s=result[key.UTF8String];size_t first=[part[@"start"] unsignedLongLongValue],end=[part[@"end"] unsignedLongLongValue];if(end>ni)throw std::runtime_error("indices");s.triangles+=(end-first)/3;s.lines+=([part[@"lineEnd"] unsignedLongLongValue]-[part[@"lineStart"] unsignedLongLongValue])/2;
   for(size_t i=first;i<end;i+=3){double v[3][3],a[3],b[3];for(int j=0;j<3;j++){auto vi=indices[i+j];if(vi>=n)throw std::runtime_error("index");for(int k=0;k<3;k++){v[j][k]=double(p[vi*3+k])+origin[k];s.values[4+k]+=normal[vi*3+k];}}for(int k=0;k<3;k++){a[k]=v[1][k]-v[0][k];b[k]=v[2][k]-v[0][k];}double cross[3]={a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]};double area=std::hypot(std::hypot(cross[0],cross[1]),cross[2])*.5;s.values[0]+=area;for(int k=0;k<3;k++){s.values[1+k]+=area*(v[0][k]+v[1][k]+v[2][k])/3;s.values[7+k]+=cross[k];}
   }
  }
 }}return result;
}
int main(int argc,char **argv){if(argc!=3){fprintf(stderr,"usage: compare-cache cache-a cache-b\n");return 2;}@autoreleasepool{try{auto a=inspect([NSString stringWithUTF8String:argv[1]]),b=inspect([NSString stringWithUTF8String:argv[2]]);if(a.size()!=b.size())throw std::runtime_error("group count differs");double peak=0;uint64_t triangles=0,lines=0;for(auto &p:a){auto f=b.find(p.first);if(f==b.end() || p.second.triangles!=f->second.triangles || p.second.lines!=f->second.lines)throw std::runtime_error("per-object/material counts differ");for(int k=0;k<10;k++){double denominator=std::max<long double>(1,std::max(std::abs(p.second.values[k]),std::abs(f->second.values[k])));if(k>=4 && k<7)denominator=std::max(denominator,double(p.second.triangles*3));if(k>=7)denominator=std::max(denominator,double(p.second.values[0]*2));double diff=double(std::abs(p.second.values[k]-f->second.values[k]))/denominator;peak=std::max(peak,diff);if(diff>1e-4){fprintf(stderr,"%s channel=%d diff=%g\n",p.first.c_str(),k,diff);throw std::runtime_error("geometry moments differ");}}triangles+=p.second.triangles;lines+=p.second.lines;}NSDictionary *report=@{@"passed":@YES,@"groups":@(a.size()),@"triangles":@(triangles),@"lineSegments":@(lines),@"maximumRelativeMomentError":@(peak)};NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return 0;}catch(std::exception &e){fprintf(stderr,"%s\n",e.what());return 1;}}}
