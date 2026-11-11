#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include "CadTextRenderer.h"
#include "ThirdParty/earcut/earcut.hpp"
#include <array>
#include <vector>
#include <map>
#include <string>
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace {
using P=std::array<double,2>;
struct Stop{int code;std::string message;};
struct Context{void *sink;O3DVCadTextEmit emit;void *owner;O3DVCadTextCheck check;int flags=0;
    void tick(size_t bytes=0){if(int code=check(owner,bytes))throw Stop{code};}
    void send(int kind,const double *p,size_t n){tick();if(int code=emit(sink,kind,p,n))throw Stop{code};}
};
double Area(const std::vector<P>&ring){double a=0;for(size_t i=0;i<ring.size();i++){const auto &p=ring[i],&q=ring[(i+1)%ring.size()];a+=p[0]*q[1]-q[0]*p[1];}return a/2;}
bool Inside(P p,const std::vector<P>&ring){bool in=false;for(size_t i=0,j=ring.size()-1;i<ring.size();j=i++){const auto&a=ring[i],&b=ring[j];if((a[1]>p[1])!=(b[1]>p[1])&&p[0]<(b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0])in=!in;}return in;}
struct Outline{
    Context &c;std::vector<std::vector<P>> rings;P current={},first={};size_t points=0;int error=0;
    void point(P p){if(++points>100000)throw Stop{2};if((points&255)==0)c.tick(points*sizeof(P));if(rings.empty())rings.emplace_back();if(rings.back().empty()||rings.back().back()!=p)rings.back().push_back(p);current=p;}
    void curve(P a,P b,P d,P e,int depth=0){
        double dx=e[0]-a[0],dy=e[1]-a[1],l=std::hypot(dx,dy);
        double distance=std::max(std::abs(dx*(b[1]-a[1])-dy*(b[0]-a[0])),std::abs(dx*(d[1]-a[1])-dy*(d[0]-a[0])))/std::max(l,1e-12);
        if(l<1e-12?std::max(std::hypot(b[0]-a[0],b[1]-a[1]),std::hypot(d[0]-a[0],d[1]-a[1]))<.06:distance<.06){point(e);return;}
        if(depth>=16)throw Stop{2};
        auto mid=[](P x,P y){return P{(x[0]+y[0])/2,(x[1]+y[1])/2};};
        auto ab=mid(a,b),bd=mid(b,d),de=mid(d,e),u=mid(ab,bd),w=mid(bd,de),m=mid(u,w);curve(a,ab,u,m,depth+1);curve(m,w,de,e,depth+1);
    }
};
void PathElement(void *info,const CGPathElement *e){
    auto &o=*static_cast<Outline *>(info);if(o.error)return;
    try{
        auto p=[&](int i){return P{e->points[i].x,e->points[i].y};};
        switch(e->type){
            case kCGPathElementMoveToPoint:o.rings.emplace_back();o.point(p(0));o.first=p(0);break;
            case kCGPathElementAddLineToPoint:o.point(p(0));break;
            case kCGPathElementAddQuadCurveToPoint:{auto a=o.current,b=p(0),d=p(1);o.curve(a,{a[0]+(b[0]-a[0])*2/3,a[1]+(b[1]-a[1])*2/3},{d[0]+(b[0]-d[0])*2/3,d[1]+(b[1]-d[1])*2/3},d);break;}
            case kCGPathElementAddCurveToPoint:o.curve(o.current,p(0),p(1),p(2));break;
            case kCGPathElementCloseSubpath:if(o.rings.back().size()>1&&o.rings.back().front()==o.rings.back().back())o.rings.back().pop_back();o.current=o.first;break;
        }
    }catch(const Stop &s){o.error=s.code;}catch(...){o.error=2;}
}
struct Glyph{std::vector<P> triangles;size_t bytes()const{return triangles.size()*sizeof(P);}};
struct GlyphCache{std::map<std::string,Glyph> values;size_t bytes=0;};
thread_local GlyphCache Cache;
Glyph Tessellate(CTFontRef font,CGGlyph glyph,Context &c){
    CGPathRef path=CTFontCreatePathForGlyph(font,glyph,nullptr);if(!path)return {};
    // Font outlines use non-zero winding. Merge overlapping strokes before
    // classifying contours as outer rings or holes (common in iOS CJK fonts).
    c.tick(1024*1024);
    CGPathRef normalized=CGPathCreateCopyByNormalizing(path,false);CGPathRelease(path);
    if(!normalized)throw Stop{1,"无法规范化文字轮廓。"};path=normalized;
    Outline outline{c};CGPathApply(path,&outline,PathElement);CGPathRelease(path);if(outline.error)throw Stop{outline.error};
    auto &rings=outline.rings;rings.erase(std::remove_if(rings.begin(),rings.end(),[](const auto &r){return r.size()<3||std::abs(Area(r))<1e-10;}),rings.end());
    std::vector<int> parent(rings.size(),-1),depth(rings.size(),0);std::vector<double> areas;for(auto &r:rings)areas.push_back(std::abs(Area(r)));
    for(size_t i=0;i<rings.size();i++)for(size_t j=0;j<rings.size();j++)if(areas[j]>areas[i]&&Inside(rings[i][0],rings[j])&&(parent[i]<0||areas[j]<areas[parent[i]]))parent[i]=int(j);
    for(size_t i=0;i<rings.size();i++)for(int p=parent[i];p>=0;p=parent[p]){if(++depth[i]>int(rings.size()))throw Stop{1};}
    Glyph result;
    for(size_t i=0;i<rings.size();i++)if(depth[i]%2==0){
        c.tick();std::vector<std::vector<P>> polygon{rings[i]};for(size_t j=0;j<rings.size();j++)if(parent[j]==int(i)&&depth[j]%2)polygon.push_back(rings[j]);
        auto indices=mapbox::earcut<uint32_t>(polygon);std::vector<P> points;for(auto &r:polygon)points.insert(points.end(),r.begin(),r.end());
        double expected=areas[i];for(size_t j=1;j<polygon.size();j++)expected-=std::abs(Area(polygon[j]));double actual=0;
        for(size_t t=0;t+2<indices.size();t+=3){auto a=points[indices[t]],b=points[indices[t+1]],d=points[indices[t+2]];actual+=std::abs((b[0]-a[0])*(d[1]-a[1])-(b[1]-a[1])*(d[0]-a[0]))/2;}
        if(std::abs(actual-expected)>std::max(1e-6,expected*1e-5)){
            NSString *name=CFBridgingRelease(CTFontCopyPostScriptName(font));
            throw Stop{1,"文字轮廓三角化校验失败："+std::string(name.UTF8String)+"，glyph="+std::to_string(glyph)+"，area="+std::to_string(expected)+"/"+std::to_string(actual)};
        }
        c.tick(result.bytes()+indices.size()*sizeof(P));for(auto index:indices)result.triangles.push_back(points.at(index));
    }return result;
}
CTFontRef Font(NSString *requested,double factor,double width,double oblique,bool bold,bool italic,Context &c){
    NSString *name=requested.stringByDeletingPathExtension.lastPathComponent;
    bool shx=[requested.pathExtension.lowercaseString isEqual:@"shx"];
    if(!name.length||shx){if(requested.length)c.flags|=1;name=@"Arial";}
    CTFontRef initial=CTFontCreateWithName((__bridge CFStringRef)name,100,nullptr);
    NSString *family=CFBridgingRelease(CTFontCopyFamilyName(initial));NSString *ps=CFBridgingRelease(CTFontCopyPostScriptName(initial));
    if([family rangeOfString:name options:NSCaseInsensitiveSearch].location==NSNotFound&&[ps rangeOfString:name options:NSCaseInsensitiveSearch].location==NSNotFound)c.flags|=1;
    double cap=CTFontGetCapHeight(initial);CTFontRef font=CTFontCreateCopyWithAttributes(initial,100*factor*100/std::max(cap,1.),nullptr,nullptr);CFRelease(initial);
    if(bold||italic){CTFontSymbolicTraits traits=(bold?kCTFontBoldTrait:0)|(italic?kCTFontItalicTrait:0);auto styled=CTFontCreateCopyWithSymbolicTraits(font,0,nullptr,traits,traits);if(styled){CFRelease(font);font=styled;}}
    CGAffineTransform matrix=CGAffineTransformMake(width,0,std::tan(oblique),1,0,0);
    CTFontRef transformed=CTFontCreateCopyWithAttributes(font,0,&matrix,nullptr);CFRelease(font);return transformed;
}
struct Line{CTLineRef line;double y,width;};
struct Ref{CFTypeRef value;~Ref(){if(value)CFRelease(value);}};
}
void O3DVCadClearTextCache(){Cache.values.clear();Cache.bytes=0;}

int O3DVCadLayoutText(const unsigned char *bytes,size_t length,void *sink,O3DVCadTextEmit emit,void *owner,O3DVCadTextCheck check){
    @autoreleasepool{Context c{sink,emit,owner,check};std::vector<Line> lines;
        try{
            c.tick(length*8);NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil];if(![request isKindOfClass:NSDictionary.class])throw Stop{1};
            NSMutableAttributedString *text=[[NSMutableAttributedString alloc]initWithString:@""];
            NSArray *runs=request[@"runs"];size_t count=0;
            for(NSDictionary *run in runs){NSString *value=run[@"text"]?:@"";count+=value.length;if(count>262144)throw Stop{2};c.tick(count*64);
                double height=[run[@"height"]doubleValue];if(!std::isfinite(height)||height<=0||height>10000)throw Stop{1};
                double horizontal=run[@"width"]?[run[@"width"]doubleValue]:1.;double oblique=[run[@"oblique"]doubleValue];
                if(!std::isfinite(horizontal)||horizontal<=0||horizontal>10000||!std::isfinite(oblique))throw Stop{1};
                CTFontRef font=Font(run[@"font"]?:@"",height,horizontal,oblique,[run[@"bold"]boolValue],[run[@"italic"]boolValue],c);
                NSString *baseFontName=CFBridgingRelease(CTFontCopyPostScriptName(font));
                NSMutableDictionary *attributes=[@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font,@"cadRun":run[@"index"]?:@0,@"cadFont":baseFontName}mutableCopy];
                double tracking=[run[@"tracking"]doubleValue];if(tracking!=0)attributes[(__bridge NSString *)kCTKernAttributeName]=@(tracking*100);
                for(NSString *key in @[@"underline",@"overline",@"strike",@"width",@"oblique"])attributes[key]=run[key]?:@0;
                NSAttributedString *fragment=[[NSAttributedString alloc]initWithString:value attributes:attributes];[text appendAttributedString:fragment];CFRelease(font);
            }
            if(!text.length)return c.flags;
            CTTypesetterRef setter=CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)text);Ref ownedSetter{setter};
            double width=[request[@"width"]doubleValue]*100;if(!std::isfinite(width)||width<0)throw Stop{1};
            CFIndex offset=0;double y=0,maxWidth=0,top=0,bottom=0;
            double pitch=std::max(.1,[request[@"lineSpacing"]doubleValue])*100;
            while(offset<text.length){c.tick();if(lines.size()>16384)throw Stop{2};
                NSRange rest=NSMakeRange(offset,text.length-offset);NSRange newline=[text.string rangeOfString:@"\n" options:0 range:rest];
                CFIndex available=newline.location==NSNotFound?rest.length:newline.location-offset;
                CFIndex n=available;if(width>0&&available>0)n=std::min(available,CTTypesetterSuggestLineBreak(setter,offset,width));
                if(available>0&&n<=0)n=1;
                CTLineRef line=CTTypesetterCreateLine(setter,CFRangeMake(offset,n));double ascent=0,descent=0,leading=0;double advance=CTLineGetTypographicBounds(line,&ascent,&descent,&leading);
                CGRect ink=CTLineGetBoundsWithOptions(line,kCTLineBoundsUseGlyphPathBounds);
                lines.push_back({line,y,advance});maxWidth=std::max(maxWidth,advance);top=std::max(top,y+CGRectGetMaxY(ink));bottom=std::min(bottom,y+CGRectGetMinY(ink));
                offset+=n;if(n==available&&newline.location!=NSNotFound)offset++;
                if(n==0&&newline.location==NSNotFound)offset=text.length;
                y-=[request[@"exactSpacing"]boolValue]?pitch:std::max(pitch,(ascent+descent)*[request[@"lineSpacing"]doubleValue]*.6);
            }
            double metrics[8]={maxWidth/100,0,bottom/100,maxWidth/100,top/100,(width>0?width:maxWidth)/100,(top-bottom)/100,double(c.flags)};c.send(0,metrics,8);
            for(const auto &line:lines){c.tick();CFArrayRef glyphRuns=CTLineGetGlyphRuns(line.line);
                for(CFIndex r=0;r<CFArrayGetCount(glyphRuns);r++){
                    CTRunRef run=(CTRunRef)CFArrayGetValueAtIndex(glyphRuns,r);NSDictionary *a=(__bridge NSDictionary *)CTRunGetAttributes(run);CTFontRef font=(__bridge CTFontRef)a[(__bridge NSString *)kCTFontAttributeName];
                    double style=[a[@"cadRun"]doubleValue];c.send(3,&style,1);
                    CFIndex n=CTRunGetGlyphCount(run);c.tick(size_t(n)*(sizeof(CGGlyph)+sizeof(CGPoint)));std::vector<CGGlyph> glyphs(n);std::vector<CGPoint> positions(n);CTRunGetGlyphs(run,CFRangeMake(0,0),glyphs.data());CTRunGetPositions(run,CFRangeMake(0,0),positions.data());
                    NSString *fontName=CFBridgingRelease(CTFontCopyPostScriptName(font));double size=CTFontGetSize(font);CGAffineTransform matrix=CTRunGetTextMatrix(run);
                    if(![fontName isEqual:a[@"cadFont"]])c.flags|=1;
                    for(CFIndex g=0;g<n;g++){c.tick();if(glyphs[g]==0)c.flags|=2;
                        std::string key=std::string(fontName.UTF8String)+":"+std::to_string(size)+":"+std::to_string(matrix.a)+":"+std::to_string(matrix.c)+":"+std::to_string(glyphs[g]);auto found=Cache.values.find(key);
                        if(found==Cache.values.end()){auto geometry=Tessellate(font,glyphs[g],c);if(Cache.bytes+geometry.bytes()>8*1024*1024){Cache.values.clear();Cache.bytes=0;}Cache.bytes+=geometry.bytes();found=Cache.values.emplace(key,std::move(geometry)).first;}
                        const auto &geometry=found->second.triangles;
                        CGPoint origin=CGPointApplyAffineTransform(positions[g],matrix);
                        for(size_t t=0;t+2<geometry.size();t+=3){double triangle[6];for(int k=0;k<3;k++){auto p=geometry[t+k];triangle[k*2]=(origin.x+p[0])/100;triangle[k*2+1]=(line.y+origin.y+p[1])/100;}c.send(1,triangle,6);}
                    }
                    if(n&&([a[@"underline"]boolValue]||[a[@"overline"]boolValue]||[a[@"strike"]boolValue])){CGSize advance;CTRunGetAdvances(run,CFRangeMake(n-1,1),&advance);for(NSString *key in @[@"underline",@"overline",@"strike"])if([a[key]boolValue]){double dy=([key isEqual:@"underline"]?-.12:[key isEqual:@"overline"]?1.08:.45)*CTFontGetCapHeight(font);CGPoint start=CGPointApplyAffineTransform(CGPointMake(positions[0].x,positions[0].y+dy),matrix),end=CGPointApplyAffineTransform(CGPointMake(positions[n-1].x+advance.width,positions[n-1].y+dy),matrix);double segment[4]={start.x/100,(line.y+start.y)/100,end.x/100,(line.y+end.y)/100};c.send(2,segment,4);}}
                }
            }
            for(auto &line:lines)CFRelease(line.line);return c.flags;
        }catch(const Stop &s){for(auto &line:lines)CFRelease(line.line);if(!s.message.empty())emit(sink,4,s.message.data(),s.message.size());return -s.code;}catch(...){for(auto &line:lines)CFRelease(line.line);return -2;}
    }
}
