#include "DSP.hpp"
#include <cmath>
#include <limits>
#include <numbers>
#include <string>
static thread_local std::string lastError;
extern "C" void pt_set_error(const char *s) { lastError=s?s:"Unknown error"; }
extern "C" const char *pt_last_error() { return lastError.c_str(); }
extern "C" PTEQ pt_eq_default() {
    PTEQ eq{}; eq.count=10;
    const double f[]={31,62,125,250,500,1000,2000,4000,8000,16000};
    for(int i=0;i<10;i++) eq.bands[i]={PT_BELL,1,f[i],0.7071067811865476,0};
    return eq;
}
extern "C" int pt_eq_validate(const PTEQ *eq,double fs) {
    if(!eq || !std::isfinite(fs)||fs<8000||fs>768000 || eq->count<1||eq->count>32 ||
       !std::isfinite(eq->preampDB)||eq->preampDB < -1000||eq->preampDB>24) return 0;
    for(int i=0;i<eq->count;i++) {
        const auto &b=eq->bands[i];
        if(b.type<PT_BELL||b.type>PT_NOTCH||!std::isfinite(b.frequency)||b.frequency<10||b.frequency>20000||
           b.frequency>=fs*.499||!std::isfinite(b.q)||b.q<.1||b.q>30||
           !std::isfinite(b.gainDB)||b.gainDB < -24||b.gainDB>24) return 0;
    }
    return 1;
}
struct PTDSP { pt::DSP value; PTDSP(double fs,int ch,const PTEQ &eq):value(fs,ch,eq){} };
extern "C" PTDSP *pt_dsp_create(double fs,int ch,const PTEQ *eq) {
    if(!eq){pt_set_error("Null EQ configuration");return nullptr;}
    try { return new PTDSP(fs,ch,*eq); } catch(const std::exception &e){pt_set_error(e.what());return nullptr;}
}
extern "C" void pt_dsp_destroy(PTDSP *p){delete p;}
extern "C" void pt_dsp_reset(PTDSP *p){if(p)p->value.reset();}
extern "C" int pt_dsp_process(PTDSP *p,const double *i,double *o,size_t n){return p&&i&&o&&p->value.process(i,o,n);}
extern "C" double pt_eq_response_db(const PTEQ *eq,double fs,double f) {
    if(!pt_eq_validate(eq,fs)||!std::isfinite(f)||f<0||f>fs/2) return NAN;
    if(!eq->enabled) return 0;
    double result=eq->preampDB;
    for(int i=0;i<eq->count;i++) result+=20*std::log10(std::abs(pt::Section::design(eq->bands[i],fs).response(2*std::numbers::pi*f/fs)));
    return result;
}
extern "C" double pt_eq_l1_bound(const PTEQ *eq,double fs) {
    if(!pt_eq_validate(eq,fs)) return INFINITY;
    if(!eq->enabled) return 1;
    double result=std::pow(10.,eq->preampDB/20.);
    for(int i=0;i<eq->count;i++) result*=pt::Section::design(eq->bands[i],fs).l1Bound();
    return result;
}
