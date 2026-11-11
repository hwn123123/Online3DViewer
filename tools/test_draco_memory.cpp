#include "DracoMemory.hpp"
#include <cassert>
#include <filesystem>
#include <iostream>
#include <stdexcept>

int main(){
    char pattern[]="/tmp/o3dv-draco-memory-XXXXXX";char *directory=mkdtemp(pattern);assert(directory);
    auto budget=std::make_shared<o3dv::DracoBudget>();budget->limit=16*1024*1024;
    bool cancelled=false;budget->workspace=std::make_shared<o3dv::MappedWorkspace>(directory,[&]{return cancelled;});
    {
        o3dv::DracoBudgetScope scope(budget);
        o3dv::DracoVector<uint32_t> values(1048576);
        for(size_t i=0;i<values.size();i++)values[i]=uint32_t(i)^0x55aa55aa;
        auto copy=values;auto moved=std::move(copy);
        assert(budget->live==values.size()*8 && budget->workspace->diskBytes>=values.size()*8);
        assert(budget->workspace->checkpoint(true));
        for(size_t i=0;i<moved.size();i++)assert(moved[i]==(uint32_t(i)^0x55aa55aa));
        budget->limit=budget->live;
        bool rejected=false;try{values.reserve(values.size()*3);}catch(const std::bad_alloc &){rejected=true;}
        assert(rejected && values.size()==1048576 && values.back()==(1048575u^0x55aa55aa));
        o3dv::DracoMap<int,int> map;rejected=false;try{map[1]=2;}catch(const std::bad_alloc &){rejected=true;}assert(rejected);
        budget->limit=16*1024*1024;
        map[1]=2;assert(map[1]==2);
    }
    assert(budget->live==0 && budget->workspace->allocated==0 && !o3dv::ActiveDracoBudget());
    {
        o3dv::DracoBudgetScope scope(budget);o3dv::DracoVector<int> values(32);
        cancelled=true;bool rejected=false;try{values.resize(10000);}catch(const std::bad_alloc &){rejected=true;}
        assert(rejected && values.size()==32);
    }
    assert(budget->live==0 && budget->workspace->allocated==0);
    budget->workspace.reset();std::filesystem::remove(directory);
    std::cout<<"PASS budgeted allocations, mapped data, copy/move lifetime, failed growth, maps, cancellation and complete release\n";
}
