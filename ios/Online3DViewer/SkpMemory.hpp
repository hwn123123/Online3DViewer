#pragma once
#include "MappedWorkspace.hpp"
#include <array>
#include <deque>
#include <memory>
#include <new>
#include <set>
#include <unordered_set>

namespace o3dv {
// Used only by our pinned OpenSKP source copy. Small parser nodes share mapped
// slabs instead of consuming one mmap/page per node; no global new override.
struct SkpBudget {
    size_t limit=4ull*1024*MemoryMiB, live=0, peak=0, allocations=0;
    bool limited=false;
    std::shared_ptr<MappedWorkspace> workspace;
    std::function<void()> checkpoint;
    struct Free { Free *next; };
    std::array<Free *,257> free{};
    std::vector<void *> slabs;
    unsigned char *cursor=nullptr;
    size_t remaining=0;
    static constexpr size_t slabBytes=4*MemoryMiB;
    ~SkpBudget(){if(workspace)for(void *p:slabs)workspace->reallocate(p,slabBytes,0);}
    void check(){if(limited)throw std::bad_alloc();if(checkpoint)checkpoint();}
    void *allocate(size_t bytes) {
        check();
        if(bytes>limit || live>limit-bytes){limited=true;throw std::bad_alloc();}
        void *p=nullptr;
#if defined(__has_feature) && __has_feature(address_sanitizer)
        p=malloc(bytes?bytes:1);
#else
        size_t rounded=(std::max(bytes,sizeof(Free))+15)&~size_t(15);
        if(workspace && rounded<=4096){
            size_t bucket=rounded/16;
            if(free[bucket]){p=free[bucket];free[bucket]=free[bucket]->next;}
            else {
                if(remaining<rounded){
                    if(workspace->allocated>limit || slabBytes>limit-workspace->allocated){limited=true;throw std::bad_alloc();}
                    p=workspace->reallocate(nullptr,0,slabBytes);
                    if(!p){limited=true;throw std::bad_alloc();}
                    try{slabs.push_back(p);}catch(...){workspace->reallocate(p,slabBytes,0);throw;}
                    cursor=static_cast<unsigned char *>(p);remaining=slabBytes;
                }
                p=cursor;cursor+=rounded;remaining-=rounded;
            }
        } else p=workspace?workspace->reallocate(nullptr,0,bytes?bytes:1):malloc(bytes?bytes:1);
#endif
        if(!p){limited=true;throw std::bad_alloc();}
        live+=bytes;peak=std::max(peak,live);allocations++;return p;
    }
    void deallocate(void *p,size_t bytes)noexcept {
#if defined(__has_feature) && __has_feature(address_sanitizer)
        ::free(p);
#else
        size_t rounded=(std::max(bytes,sizeof(Free))+15)&~size_t(15);
        if(workspace && rounded<=4096){auto *item=static_cast<Free *>(p);item->next=free[rounded/16];free[rounded/16]=item;}
        else if(workspace)workspace->reallocate(p,bytes,0);else ::free(p);
#endif
        live-=bytes;
    }
};
inline std::shared_ptr<SkpBudget> &ActiveSkpBudget(){static thread_local std::shared_ptr<SkpBudget> value;return value;}
struct SkpBudgetScope {
    std::shared_ptr<SkpBudget> previous;
    explicit SkpBudgetScope(std::shared_ptr<SkpBudget> b):previous(ActiveSkpBudget()){ActiveSkpBudget()=std::move(b);}
    ~SkpBudgetScope(){ActiveSkpBudget()=previous;}
};
inline void SkpCheck(){if(auto b=ActiveSkpBudget())b->check();}
inline void SkpTick(){static thread_local size_t calls=0;if((++calls&1023)==0)SkpCheck();}
template<class T> class SkpAllocator {
public:
    using value_type=T;
    using propagate_on_container_move_assignment=std::true_type;
    using propagate_on_container_swap=std::true_type;
    std::shared_ptr<SkpBudget> budget;
    SkpAllocator()noexcept:budget(ActiveSkpBudget()){}
    template<class U>SkpAllocator(const SkpAllocator<U> &a)noexcept:budget(a.budget){}
    T *allocate(size_t n){if(n>SIZE_MAX/sizeof(T))throw std::bad_alloc();if(budget)return static_cast<T *>(budget->allocate(n*sizeof(T)));auto p=malloc(std::max(size_t(1),n*sizeof(T)));if(!p)throw std::bad_alloc();return static_cast<T *>(p);}
    void deallocate(T *p,size_t n)noexcept{if(budget)budget->deallocate(p,n*sizeof(T));else free(p);}
    template<class U>bool operator==(const SkpAllocator<U>&a)const noexcept{return budget==a.budget;}
    template<class U>bool operator!=(const SkpAllocator<U>&a)const noexcept{return !(*this==a);}
};
template<class T,class A=SkpAllocator<T>>using SkpVector=std::vector<T,A>;
template<class T,class A=SkpAllocator<T>>using SkpDeque=std::deque<T,A>;
template<class K,class V,class C=std::less<K>,class A=SkpAllocator<std::pair<const K,V>>>using SkpMap=std::map<K,V,C,A>;
template<class K,class C=std::less<K>,class A=SkpAllocator<K>>using SkpSet=std::set<K,C,A>;
template<class K,class V,class H=std::hash<K>,class E=std::equal_to<K>,class A=SkpAllocator<std::pair<const K,V>>>using SkpUnorderedMap=std::unordered_map<K,V,H,E,A>;
template<class K,class H=std::hash<K>,class E=std::equal_to<K>,class A=SkpAllocator<K>>using SkpUnorderedSet=std::unordered_set<K,H,E,A>;
template<class T,class... A>std::shared_ptr<T> SkpMakeShared(A&&...a){return std::allocate_shared<T>(SkpAllocator<T>{},std::forward<A>(a)...);}
}
