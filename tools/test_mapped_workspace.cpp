#include "MappedWorkspace.hpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <filesystem>
#include <vector>
static size_t descriptors(){size_t n=0;DIR *d=opendir("/dev/fd");while(readdir(d))n++;closedir(d);return n;}
int main(){
 char pattern[]="/tmp/o3dv-workspace-XXXXXX";char *root=mkdtemp(pattern);assert(root);const auto before=descriptors();
 {
  bool cancelled=false;o3dv::MappedWorkspace memory(root,[&]{return cancelled;});
  constexpr size_t size=96*o3dv::MemoryMiB;auto *p=(unsigned char *)memory.reallocate(nullptr,0,size);assert(p);
  for(size_t i=0;i<size;i++)p[i]=(i*13+i/997)%251;
  assert(memory.checkpoint(true));o3dv::MemoryPressure().store(1);assert(memory.checkpoint(true));o3dv::MemoryPressure().store(0);
  auto *larger=(unsigned char *)memory.reallocate(p,size,160*o3dv::MemoryMiB);assert(larger);
  for(size_t i=0;i<size;i++)assert(larger[i]==(i*13+i/997)%251);
  auto *small=(unsigned char *)memory.reallocate(larger,160*o3dv::MemoryMiB,16384);assert(small);
  for(size_t i=0;i<16384;i++)assert(small[i]==(i*13+i/997)%251);
  memory.reallocate(small,16384,0);assert(memory.allocated==0);
  // Reused file regions must remain disjoint while live allocations preserve their bytes.
  std::vector<unsigned char *> blocks;for(int i=0;i<32;i++){auto *b=(unsigned char *)memory.reallocate(nullptr,0,65536+i*4096);assert(b);memset(b,i,65536+i*4096);blocks.push_back(b);}
  for(int i=0;i<32;i++){for(size_t j=0;j<65536+i*4096;j++)assert(blocks[i][j]==i);memory.reallocate(blocks[i],65536+i*4096,0);}
  cancelled=true;assert(!memory.reallocate(nullptr,0,1048576));assert(memory.failure==o3dv::MappedWorkspace::Failure::cancelled);
  assert(std::filesystem::is_empty(root));
 }
 assert(descriptors()==before);
 {o3dv::MappedWorkspace invalid(std::string(root)+"/missing",[]{return false;});assert(!invalid.reallocate(nullptr,0,1048576));assert(invalid.failure==o3dv::MappedWorkspace::Failure::disk);}
 assert(descriptors()==before);std::filesystem::remove(root);puts("PASS disk-backed resize, synchronized eviction, region reuse, cancellation, storage errors and descriptor cleanup");
}
