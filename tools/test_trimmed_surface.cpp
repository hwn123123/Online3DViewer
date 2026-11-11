#include "TrimmedSurface.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>

int main() {
    o3dv::TrimPolygon p;
    p.rings={{{0,0},{4,0},{4,4},{0,4}},{{1,1},{1,3},{3,3},{3,1}}};
    assert(o3dv::Triangulate(p));
    double area=0;
    for(size_t i=0;i<p.indices.size();i+=3) {
        auto a=p.points[p.indices[i]],b=p.points[p.indices[i+1]],c=p.points[p.indices[i+2]];
        area+=std::abs((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]))*.5;
        // No triangle centroid may fill the square hole.
        double x=(a[0]+b[0]+c[0])/3,y=(a[1]+b[1]+c[1])/3;
        assert(!(x>1 && x<3 && y>1 && y<3));
    }
    assert(std::abs(area-12)<1e-10);
    o3dv::TrimPolygon bad;
    bad.rings={{{0,0},{4,0},{4,4},{0,4}},{{8,8},{9,8},{9,9},{8,9}}};
    assert(!o3dv::Triangulate(bad));
    puts("PASS trim hole area, hole preservation and invalid boundary rejection");
}
