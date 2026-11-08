#include "PureToneCore.h"
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>
static void check(bool x,const char *name){if(!x){std::cerr<<"FAIL: "<<name<<'\n';std::exit(1);}}
int main(){
    auto eq=pt_eq_default();check(pt_eq_validate(&eq,48000),"defaults");
    std::vector<double> input(10000),out(input.size());for(size_t i=0;i<input.size();i++)input[i]=std::sin(double(i))*.99;
    auto d=pt_dsp_create(48000,2,&eq);check(d,"allocate");check(pt_dsp_process(d,input.data(),out.data(),5000),"process");
    check(input==out,"bypass is sample-identical");pt_dsp_destroy(d);
    eq.enabled=1;eq.count=1;eq.bands[0]={PT_BELL,1,1000,1,6};
    check(std::abs(pt_eq_response_db(&eq,48000,1000)-6)<1e-8,"bell center");
    check(pt_eq_l1_bound(&eq,48000)>=std::pow(10.,6./20),"L1 bounds peak gain");
    for(int type=0;type<=6;type++)for(double fs:{44100.,48000.,96000.,192000.})for(double f:{10.,1000.,20000.})for(double q:{.1,.7071067811865476,30.}){
        eq.bands[0]={type,1,f,q,24};check(pt_eq_validate(&eq,fs),"valid boundary");d=pt_dsp_create(fs,1,&eq);check(d,"boundary DSP");
        check(pt_dsp_process(d,input.data(),out.data(),input.size()),"finite boundary output");pt_dsp_destroy(d);
        check(std::isfinite(pt_eq_response_db(&eq,fs,1234)),"finite frequency response");
        check(std::isfinite(pt_eq_l1_bound(&eq,fs)),"finite L1 tail bound");
    }
    eq.bands[0].q=std::numeric_limits<double>::quiet_NaN();check(!pt_eq_validate(&eq,48000),"reject NaN");
    eq=pt_eq_default();eq.enabled=1;eq.count=32;for(int i=0;i<32;i++)eq.bands[i]={PT_BELL,1,1000,1,0};
    d=pt_dsp_create(48000,1,&eq);check(pt_dsp_process(d,input.data(),out.data(),input.size()),"32 bands");check(input==out,"zero-gain sections exact bypass");pt_dsp_destroy(d);
    std::cout<<"PASS: bypass, parameter boundaries, all types, L1 stability, 32 bands\n";
}
