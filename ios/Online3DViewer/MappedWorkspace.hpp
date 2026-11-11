#pragma once
#include "NativeMemory.hpp"
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace o3dv {
// Large parser allocations have a private, file-backed working store. Source files are never mapped writable.
// Shared file pages retain every byte; pressure checkpoints synchronize writeback before requesting eviction.
class MappedWorkspace {
public:
    enum class Failure { none,cancelled,disk,addressSpace,pressure,allocation,io };
    using Clock=std::chrono::steady_clock;
    explicit MappedWorkspace(const std::string &directory,std::function<bool()> cancelled)
        : cancelled_(std::move(cancelled)) {
        std::string pattern=directory+"/.parse-memory-XXXXXX";std::vector<char> name(pattern.begin(),pattern.end());name.push_back(0);
        fd_=mkstemp(name.data());
        if(fd_>=0) { fcntl(fd_,F_SETFD,FD_CLOEXEC);unlink(name.data()); } // Also cleaned automatically after a terminated process.
        else failure=Failure::disk;
        struct statvfs storage={};if(fd_>=0 && fstatvfs(fd_,&storage)==0) freeAtStart=lastFree=uint64_t(storage.f_bavail)*storage.f_frsize;
        page_=size_t(getpagesize());lastFlush_=Clock::now();
    }
    ~MappedWorkspace() {
        for(auto &p:blocks_) {if(p.second.mapped)munmap(p.first,p.second.length);else free(p.first);}
        if(fd_>=0)close(fd_);
    }
    MappedWorkspace(const MappedWorkspace &)=delete;
    MappedWorkspace &operator=(const MappedWorkspace &)=delete;
    void *reallocate(void *old,size_t oldSize,size_t size) noexcept {
        try {
            if(!size) { if(old)release(old);return nullptr; }
            if(cancelled_()) {failure=Failure::cancelled;return nullptr;}
            if(failure!=Failure::none)return nullptr;
            void *next=allocate(size);if(!next)return nullptr;
            if(old) {
                size_t total=std::min(oldSize,size);
                for(size_t offset=0;offset<total;offset+=MemoryMiB) {
                    if(cancelled_()) {release(next);failure=Failure::cancelled;return nullptr;}
                    memcpy((char *)next+offset,(char *)old+offset,std::min(MemoryMiB,total-offset));
                }
                release(old);
            }
            return next;
        } catch(...) {failure=Failure::allocation;return nullptr;}
    }
    bool checkpoint(bool force=false) noexcept {
        if(cancelled_()) {failure=Failure::cancelled;return false;}
        auto now=Clock::now();
        if(!force && MemoryPressure().load(std::memory_order_relaxed)==0 && now-lastCheck_<std::chrono::milliseconds(100))return failure==Failure::none;
        lastCheck_=now;
        auto sample=SampleMemory();peakFootprint=std::max(peakFootprint,sample.footprint);peakResident=std::max(peakResident,sample.resident);
        if(force || dirtyEstimate_>=64*MemoryMiB || Clock::now()-lastFlush_>std::chrono::milliseconds(400) || sample.pressure) {
            if(!flush(force || sample.pressure>0))return false;
            sample=SampleMemory();
        }
        if(sample.availableKnown && sample.available<32*MemoryMiB) {failure=Failure::pressure;return false;}
        if(sample.footprint>512*MemoryMiB) {failure=Failure::pressure;return false;}
        if(sample.pressure>=2 && sample.footprint>512*MemoryMiB) {failure=Failure::pressure;return false;}
        return failure==Failure::none;
    }
    size_t allocated=0,peakAllocated=0,peakFootprint=0,peakResident=0,diskBytes=0,flushCount=0;
    uint64_t freeAtStart=0,lastFree=0;
    int systemError=0;
    Failure failure=Failure::none;
private:
    struct Block {size_t size,length,offset;bool mapped;};
    int fd_=-1;size_t page_=4096,heap_=0,dirtyEstimate_=0;
    std::unordered_map<void *,Block> blocks_;
    std::map<size_t,size_t> freeRegions_;
    std::function<bool()> cancelled_;
    Clock::time_point lastFlush_,lastCheck_;
    bool flush(bool synchronous=false) noexcept {
        for(auto &p:blocks_)if(p.second.mapped) {
            if(msync(p.first,p.second.length,synchronous?MS_SYNC:MS_ASYNC)!=0) {failure=Failure::io;return false;}
            madvise(p.first,p.second.length,MADV_DONTNEED);
        }
        dirtyEstimate_=0;lastFlush_=Clock::now();flushCount++;return true;
    }
    void addFree(size_t offset,size_t length) {
        auto next=freeRegions_.lower_bound(offset);
        if(next!=freeRegions_.begin()) {auto prev=std::prev(next);if(prev->first+prev->second==offset){offset=prev->first;length+=prev->second;freeRegions_.erase(prev);}}
        next=freeRegions_.lower_bound(offset);
        if(next!=freeRegions_.end() && offset+length==next->first){length+=next->second;freeRegions_.erase(next);}
        freeRegions_[offset]=length;
    }
    void release(void *p) noexcept {
        auto found=blocks_.find(p);if(found==blocks_.end())return;
        auto block=found->second;
        allocated-=block.size;blocks_.erase(found);
        if(block.mapped) {
            munmap(p,block.length);
            try {addFree(block.offset,block.length);} catch(...) {failure=Failure::allocation;}
        } else {free(p);heap_-=block.size;}
    }
    void *allocate(size_t size) {
        if(!checkpoint())return nullptr;
        bool mapped=size>=64*1024 || heap_+size>24*MemoryMiB;
        void *pointer=nullptr;size_t length=size,offset=0;
        if(mapped) {
            if(fd_<0 || size>SIZE_MAX-page_){failure=Failure::disk;return nullptr;}
            if(dirtyEstimate_+size>64*MemoryMiB && !flush())return nullptr;
            length=(size+page_-1)/page_*page_;
            auto region=std::find_if(freeRegions_.begin(),freeRegions_.end(),[&](const auto &r){return r.second>=length;});
            if(region!=freeRegions_.end()) {
                offset=region->first;size_t remaining=region->second-length;freeRegions_.erase(region);
                if(remaining)freeRegions_[offset+length]=remaining;
            } else {
                struct statvfs storage={};
                if(fstatvfs(fd_,&storage)!=0) {systemError=errno;failure=Failure::disk;return nullptr;}
                lastFree=uint64_t(storage.f_bavail)*storage.f_frsize;
                if(lastFree<uint64_t(length)+512*MemoryMiB) {systemError=ENOSPC;failure=Failure::disk;return nullptr;}
                if(diskBytes>size_t(INT64_MAX)-length){failure=Failure::addressSpace;return nullptr;}
                offset=diskBytes;
                fstore_t store={};store.fst_flags=F_ALLOCATEALL;store.fst_posmode=F_PEOFPOSMODE;store.fst_length=off_t(length);
                if(fcntl(fd_,F_PREALLOCATE,&store)<0 || ftruncate(fd_,off_t(offset+length))<0) {systemError=errno;failure=Failure::disk;return nullptr;}
                diskBytes+=length;
            }
            pointer=mmap(nullptr,length,PROT_READ|PROT_WRITE,MAP_SHARED,fd_,off_t(offset));
            if(pointer==MAP_FAILED){addFree(offset,length);failure=Failure::addressSpace;return nullptr;}
            dirtyEstimate_+=size;
        } else {
            pointer=malloc(size);if(!pointer){failure=Failure::allocation;return nullptr;}heap_+=size;
        }
        try {blocks_.emplace(pointer,Block{size,length,offset,mapped});}
        catch(...) {if(mapped){munmap(pointer,length);addFree(offset,length);}else {free(pointer);heap_-=size;}throw;}
        allocated+=size;peakAllocated=std::max(peakAllocated,allocated);return pointer;
    }
};
}
