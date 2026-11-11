#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace o3dv {
// Index the container without expanding geometry arrays. Each page retains the original
// hierarchy, settings, materials and deformers, and a bounded batch of independent geometry.
class FbxMeshPages {
public:
    struct Node {uint64_t start=0,end=0,count=0,bytes=0,properties=0;std::string name;};
    struct Object {Node node;bool mesh=false;uint64_t decoded=0;};
    using File=std::unique_ptr<FILE,decltype(&fclose)>;
    explicit FbxMeshPages(const char *path,std::function<bool()> cancelled) : input_(fopen(path,"rb"),&fclose),cancelled_(std::move(cancelled)) {
        if(!input_)return;
        fseeko(input_.get(),0,SEEK_END);size_=ftello(input_.get());fseeko(input_.get(),0,SEEK_SET);
        uint8_t header[27]={};if(fread(header,1,27,input_.get())!=27 || memcmp(header,"Kaydara FBX Binary  \0\x1a\0",23)!=0)return;
        memcpy(&version_,header+23,4);if(version_<7000)return;
        wide_=version_>=7500;headerSize_=wide_?25:13;
        uint64_t position=27;bool incompatible=false;
        while(position+headerSize_<=size_) {
            Node root=read(position,size_);
            if(!root.end){footer_=position+headerSize_;break;}
            roots_.push_back(root);
            if(root.name=="Objects") {
                for(uint64_t at=root.properties+root.bytes;at+headerSize_<=root.end;) {
                    Node item=read(at,root.end);if(!item.end)break;
                    Object object;object.node=item;
                    if(item.name=="Geometry") {
                        std::string type=geometryType(item);
                        object.mesh=type=="Mesh" || type=="Line" || type=="NurbsCurve";
                        if(!object.mesh && type!="Shape")incompatible=true;
                        object.decoded=estimate(item,0);
                    }
                    objects_.push_back(object);at=item.end;
                }
            }
            position=root.end;
        }
        size_t meshes=0;for(auto &o:objects_)meshes+=o.mesh;
        supported=!incompatible && meshes>1 && footer_>0;
    }
    bool supported=false;
    size_t pageCount(uint64_t decodedBudget) const {return pages(decodedBudget).size();}
    std::vector<std::vector<size_t>> pages(uint64_t decodedBudget) const {
        std::vector<std::vector<size_t>> result;uint64_t bytes=0;
        for(size_t i=0;i<objects_.size();i++)if(objects_[i].mesh) {
            if(result.empty() || (!result.back().empty() && bytes+objects_[i].decoded>decodedBudget)){result.push_back({});bytes=0;}
            result.back().push_back(i);bytes+=objects_[i].decoded;
        }
        return result;
    }
    void writePage(const std::vector<size_t> &selection,const char *path) {
        File output(fopen(path,"wb"),&fclose);if(!output)throw std::runtime_error("无法建立 FBX 分批工作文件。");
        std::vector<bool> selected(objects_.size(),false);for(size_t i:selection)selected.at(i)=true;
        copy(output.get(),0,27);
        for(const auto &root:roots_) {
            if(root.name!="Objects") {writeNode(root,output.get(),0);continue;}
            uint64_t start=ftello(output.get());writeHeader(output.get(),0,root.count,root.bytes,root.name);copy(output.get(),root.properties,root.bytes);
            for(size_t i=0;i<objects_.size();i++) {
                auto &o=objects_[i];
                if(o.mesh && !selected[i])continue;
                // Static viewing uses the saved default pose, as in the single-scene reader.
                if(o.node.name.rfind("Animation",0)==0)continue;
                writeNode(o.node,output.get(),0);
            }
            zeros(output.get());uint64_t end=ftello(output.get());fseeko(output.get(),start,SEEK_SET);writeHeader(output.get(),end,root.count,root.bytes,root.name);fseeko(output.get(),end,SEEK_SET);
        }
        zeros(output.get());if(footer_<size_)copy(output.get(),footer_,size_-footer_);
        if(fflush(output.get())!=0)throw std::runtime_error("FBX 工作区写入失败。");
    }
private:
    File input_;std::function<bool()> cancelled_;std::vector<Node> roots_;std::vector<Object> objects_;std::vector<uint8_t> copyBuffer_;
    uint64_t size_=0,footer_=0;uint32_t version_=0;size_t headerSize_=13;bool wide_=false;
    template<class T>T scalar(){T value={};if(fread(&value,sizeof(T),1,input_.get())!=1)throw std::runtime_error("FBX 容器数据不完整。");return value;}
    void check(){if(cancelled_())throw std::runtime_error("读取已取消。");}
    Node read(uint64_t position,uint64_t limit) {
        check();if(position>limit || limit-position<headerSize_)throw std::runtime_error("FBX 容器边界不正确。");
        fseeko(input_.get(),position,SEEK_SET);Node n;n.start=position;
        n.end=wide_?scalar<uint64_t>():scalar<uint32_t>();n.count=wide_?scalar<uint64_t>():scalar<uint32_t>();n.bytes=wide_?scalar<uint64_t>():scalar<uint32_t>();
        uint8_t length=scalar<uint8_t>();if(!n.end)return n;
        if(n.end>limit || n.end<position+headerSize_+length || n.bytes>n.end-position-headerSize_-length)throw std::runtime_error("FBX 节点长度不正确。");
        n.name.resize(length);if(length && fread(n.name.data(),1,length,input_.get())!=length)throw std::runtime_error("FBX 节点名称不完整。");
        n.properties=position+headerSize_+length;return n;
    }
    uint64_t property(bool keepString,std::string *text=nullptr) {
        uint8_t type=scalar<uint8_t>();uint64_t length=0,decoded=0;
        switch(type) {
            case 'Y':length=2;break;case 'C':length=1;break;case 'I':case 'F':length=4;break;case 'D':case 'L':length=8;break;
            case 'S':case 'R': {
                length=scalar<uint32_t>();if(length>size_ || uint64_t(ftello(input_.get()))>size_-length)throw std::runtime_error("FBX 属性超出文件边界。");
                if(type=='S' && keepString && text && length<4096){text->resize(size_t(length));if(length && fread(text->data(),1,length,input_.get())!=length)throw std::runtime_error("FBX 字符串不完整。");return length;}
                break;
            }
            case 'f':case 'd':case 'i':case 'l':case 'b':case 'c': {
                uint64_t count=scalar<uint32_t>();scalar<uint32_t>();length=scalar<uint32_t>();decoded=count*((type=='d'||type=='l')?8:(type=='f'||type=='i')?4:1);break;
            }
            default:throw std::runtime_error("FBX 属性类型无法识别。");
        }
        if(length>size_ || uint64_t(ftello(input_.get()))>size_-length)throw std::runtime_error("FBX 属性数据不完整。");
        fseeko(input_.get(),off_t(length),SEEK_CUR);return decoded;
    }
    std::string geometryType(const Node &n) {
        fseeko(input_.get(),n.properties,SEEK_SET);std::string result;
        for(uint64_t i=0;i<n.count;i++)property(i==2,&result);return result;
    }
    uint64_t estimate(const Node &n,int depth) {
        if(depth>128)throw std::runtime_error("FBX 节点嵌套过深。");
        uint64_t result=0;fseeko(input_.get(),n.properties,SEEK_SET);
        for(uint64_t i=0;i<n.count;i++)result+=property(false);
        for(uint64_t at=n.properties+n.bytes;at+headerSize_<=n.end;) {
            Node child=read(at,n.end);if(!child.end)break;result+=estimate(child,depth+1);at=child.end;
        }
        return result;
    }
    void copy(FILE *out,uint64_t offset,uint64_t count) {
        if(!count)return;
        if(copyBuffer_.empty())copyBuffer_.resize(1024*1024);
        fseeko(input_.get(),off_t(offset),SEEK_SET);
        while(count){check();size_t n=size_t(std::min<uint64_t>(count,copyBuffer_.size()));if(fread(copyBuffer_.data(),1,n,input_.get())!=n || fwrite(copyBuffer_.data(),1,n,out)!=n)throw std::runtime_error("FBX 工作区读写失败。");count-=n;}
    }
    void zeros(FILE *out){uint8_t bytes[25]={};if(fwrite(bytes,1,headerSize_,out)!=headerSize_)throw std::runtime_error("FBX 工作区写入失败。");}
    void writeHeader(FILE *out,uint64_t end,uint64_t count,uint64_t bytes,const std::string &name) {
        if(!wide_ && (end>UINT32_MAX || count>UINT32_MAX || bytes>UINT32_MAX))throw std::runtime_error("FBX 分批文件超出该版本的容器范围。");
        uint8_t data[25]={};if(wide_){memcpy(data,&end,8);memcpy(data+8,&count,8);memcpy(data+16,&bytes,8);data[24]=uint8_t(name.size());}
        else {uint32_t a=uint32_t(end),b=uint32_t(count),c=uint32_t(bytes);memcpy(data,&a,4);memcpy(data+4,&b,4);memcpy(data+8,&c,4);data[12]=uint8_t(name.size());}
        if(fwrite(data,1,headerSize_,out)!=headerSize_ || fwrite(name.data(),1,name.size(),out)!=name.size())throw std::runtime_error("FBX 工作区写入失败。");
    }
    void writeNode(const Node &n,FILE *out,int depth) {
        if(depth>128)throw std::runtime_error("FBX 节点嵌套过深。");
        uint64_t start=ftello(out);writeHeader(out,0,n.count,n.bytes,n.name);copy(out,n.properties,n.bytes);
        for(uint64_t at=n.properties+n.bytes;at+headerSize_<=n.end;) {Node child=read(at,n.end);if(!child.end)break;writeNode(child,out,depth+1);at=child.end;}
        if(n.end>=n.properties+n.bytes+headerSize_)zeros(out);
        uint64_t end=ftello(out);fseeko(out,off_t(start),SEEK_SET);writeHeader(out,end,n.count,n.bytes,n.name);fseeko(out,off_t(end),SEEK_SET);
    }
};
}
