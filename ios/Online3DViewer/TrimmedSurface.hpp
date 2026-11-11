#pragma once
#include "ThirdParty/ufbx/ufbx.h"
#include "ThirdParty/earcut/earcut.hpp"
#include <array>
#include <algorithm>
#include <cmath>
#include <functional>
#include <vector>

namespace o3dv {
using UV=std::array<double,2>;
using Ring=std::vector<UV>;
struct TrimPolygon {
    ufbx_nurbs_surface *surface=nullptr;
    std::vector<Ring> rings;
    std::vector<UV> points;
    std::vector<uint32_t> indices;
};
inline double Distance(UV a,UV b) { return std::hypot(a[0]-b[0],a[1]-b[1]); }
inline double Area(const Ring &r) {
    double sum=0;for(size_t i=0,j=r.size()-1;i<r.size();j=i++) sum+=r[j][0]*r[i][1]-r[i][0]*r[j][1];return sum*.5;
}
inline bool Inside(UV p,const Ring &r) {
    bool in=false;for(size_t i=0,j=r.size()-1;i<r.size();j=i++) {
        auto a=r[i],b=r[j];if((a[1]>p[1])!=(b[1]>p[1]) && p[0]<(b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]) in=!in;
    }return in;
}
// Validate the area as well as triangulation: never fill a hole on a failed trim.
inline bool Triangulate(TrimPolygon &out) {
    if(out.rings.empty()) return false;
    std::sort(out.rings.begin(),out.rings.end(),[](const Ring &a,const Ring &b){return std::abs(Area(a))>std::abs(Area(b));});
    double expected=std::abs(Area(out.rings[0]));
    for(size_t i=1;i<out.rings.size();i++) {
        if(!Inside(out.rings[i][0],out.rings[0])) return false;
        expected-=std::abs(Area(out.rings[i]));
    }
    if(expected<=0) return false;
    out.indices=mapbox::earcut<uint32_t>(out.rings);
    for(const auto &r:out.rings) out.points.insert(out.points.end(),r.begin(),r.end());
    double actual=0;
    for(size_t i=0;i<out.indices.size();i+=3) {
        auto a=out.points[out.indices[i]],b=out.points[out.indices[i+1]],c=out.points[out.indices[i+2]];
        actual+=std::abs((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]))*.5;
    }
    return !out.indices.empty() && std::abs(actual-expected)<=std::max(1e-10,expected*1e-7);
}
inline bool ReadTrim(ufbx_element *trim,TrimPolygon &out,const ufbx_allocator_opts *allocator=nullptr) {
    std::vector<ufbx_element *> boundaries;
    for(auto connection:trim->connections_dst) {
        if(auto *s=ufbx_as_nurbs_surface(connection.src)) out.surface=s;
        if(ufbx_as_nurbs_trim_boundary(connection.src)) boundaries.push_back(connection.src);
    }
    if(!out.surface || boundaries.empty()) return false;
    double span=std::max(out.surface->basis_u.t_max-out.surface->basis_u.t_min,out.surface->basis_v.t_max-out.surface->basis_v.t_min);
    double tolerance=std::max(1e-9,span*1e-7);
    for(auto boundary:boundaries) {
        std::vector<Ring> pieces;
        for(auto connection:boundary->connections_dst) {
            auto *c=ufbx_as_nurbs_curve(connection.src);
            if(!c || !c->basis.is_2d) return false;
            ufbx_tessellate_curve_opts opts={};opts.span_subdivision=16;
            if(allocator) opts.temp_allocator=opts.result_allocator=*allocator;
            else opts.temp_allocator.memory_limit=opts.result_allocator.memory_limit=64*1024*1024;
            ufbx_line_curve *line=ufbx_tessellate_nurbs_curve(c,&opts,nullptr);
            if(!line) return false;
            if(line->point_indices.count>1000000) {ufbx_free_line_curve(line);return false;}
            for(auto segment:line->segments) {
                Ring piece;
                for(uint32_t i=0;i<segment.num_indices;i++) {
                    auto p=line->control_points.data[line->point_indices.data[segment.index_begin+i]];
                    UV uv={p.x,p.y};
                    if(piece.empty() || Distance(piece.back(),uv)>tolerance) piece.push_back(uv);
                }
                if(piece.size()>=2) pieces.push_back(std::move(piece));
            }
            ufbx_free_line_curve(line);
        }
        while(!pieces.empty()) {
            Ring ring=std::move(pieces.back());pieces.pop_back();
            while(Distance(ring.front(),ring.back())>tolerance) {
                size_t match=pieces.size();bool reverse=false;double best=tolerance;
                for(size_t i=0;i<pieces.size();i++) {
                    double front=Distance(ring.back(),pieces[i].front()),back=Distance(ring.back(),pieces[i].back());
                    if(front<=best) {best=front;match=i;reverse=false;}
                    if(back<=best) {best=back;match=i;reverse=true;}
                }
                if(match==pieces.size()) return false;
                auto &p=pieces[match];if(reverse) std::reverse(p.begin(),p.end());
                ring.insert(ring.end(),p.begin()+1,p.end());pieces.erase(pieces.begin()+match);
            }
            ring.pop_back();if(ring.size()<3) return false;
            for(auto uv:ring) if(uv[0]<out.surface->basis_u.t_min-tolerance || uv[0]>out.surface->basis_u.t_max+tolerance ||
                uv[1]<out.surface->basis_v.t_min-tolerance || uv[1]>out.surface->basis_v.t_max+tolerance) return false;
            out.rings.push_back(std::move(ring));
        }
    }
    return Triangulate(out);
}
}
