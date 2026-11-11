#pragma once
#include "MappedWorkspace.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <set>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace o3dv {
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
inline constexpr bool DracoMappedAllocations=false; // Let ASan instrument each decoder allocation during dedicated checks.
#else
inline constexpr bool DracoMappedAllocations=true;
#endif
#else
inline constexpr bool DracoMappedAllocations=true;
#endif
// Only the pinned Draco build uses these container aliases. No global new/delete override.
struct DracoBudget {
    size_t limit=1024*1024*1024,live=0,external=0,peak=0,allocations=0;
    bool limited=false;
    std::shared_ptr<MappedWorkspace> workspace;
    std::function<void()> checkpoint;
    void check() {if(checkpoint)checkpoint();}
    void reserve(size_t n) {
        check();
        if(live>limit || external>limit-live || n>limit-live-external){limited=true;throw std::bad_alloc();}
        live+=n;peak=std::max(peak,live+external);allocations++;
    }
    void chargeExternal(size_t n) {if(n>16*1024*1024 || external>16*1024*1024-n){limited=true;throw std::bad_alloc();}reserve(n);live-=n;external+=n;}
};
inline std::shared_ptr<DracoBudget> &ActiveDracoBudget(){static thread_local std::shared_ptr<DracoBudget> value;return value;}
struct DracoBudgetScope {
    std::shared_ptr<DracoBudget> previous;
    explicit DracoBudgetScope(std::shared_ptr<DracoBudget> budget):previous(ActiveDracoBudget()){ActiveDracoBudget()=std::move(budget);}
    ~DracoBudgetScope(){ActiveDracoBudget()=previous;}
};
inline void DracoCheckpoint(){static thread_local size_t calls=0;if((++calls&1023)==0)if(auto b=ActiveDracoBudget())b->check();}
inline void DracoExternalBytes(size_t bytes){if(auto b=ActiveDracoBudget())b->chargeExternal(bytes);}
template<class T> class DracoAllocator {
public:
    using value_type=T;
    using propagate_on_container_move_assignment=std::true_type;
    using propagate_on_container_swap=std::true_type;
    std::shared_ptr<DracoBudget> budget;
    DracoAllocator()noexcept:budget(ActiveDracoBudget()){}
    template<class U>DracoAllocator(const DracoAllocator<U> &other)noexcept:budget(other.budget){}
    T *allocate(size_t n){
        if(n>std::numeric_limits<size_t>::max()/sizeof(T)){if(budget)budget->limited=true;throw std::bad_alloc();}
        size_t bytes=n*sizeof(T);if(budget)budget->reserve(bytes);
        void *p=DracoMappedAllocations&&budget&&budget->workspace?budget->workspace->reallocate(nullptr,0,bytes?bytes:1):malloc(bytes?bytes:1);
        if(!p){if(budget){budget->live-=bytes;budget->limited=true;}throw std::bad_alloc();}return static_cast<T *>(p);
    }
    void deallocate(T *p,size_t n)noexcept{if(DracoMappedAllocations&&budget&&budget->workspace)budget->workspace->reallocate(p,n*sizeof(T),0);else free(p);if(budget)budget->live-=n*sizeof(T);}
    template<class U>bool operator==(const DracoAllocator<U> &b)const noexcept{return budget==b.budget;}
    template<class U>bool operator!=(const DracoAllocator<U> &b)const noexcept{return !(*this==b);}
};
template<class T,class A=DracoAllocator<T>>using DracoVector=std::vector<T,A>;
template<class K,class V,class C=std::less<K>,class A=DracoAllocator<std::pair<const K,V>>>using DracoMap=std::map<K,V,C,A>;
template<class K,class C=std::less<K>,class A=DracoAllocator<K>>using DracoSet=std::set<K,C,A>;
template<class K,class V,class H=std::hash<K>,class E=std::equal_to<K>,class A=DracoAllocator<std::pair<const K,V>>>using DracoUnorderedMap=std::unordered_map<K,V,H,E,A>;
template<class K,class H=std::hash<K>,class E=std::equal_to<K>,class A=DracoAllocator<K>>using DracoUnorderedSet=std::unordered_set<K,H,E,A>;
}
