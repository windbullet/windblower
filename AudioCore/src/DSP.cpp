#include "DSP.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numbers>
#include <stdexcept>
namespace pt {
Section Section::design(const PTBand &b, double fs) {
    Section s;
    if (!b.enabled || ((b.type <= PT_HIGH_SHELF) && b.gainDB == 0)) return s;
    s.bypass = false;
    const double A = std::pow(10., b.gainDB / 40.);
    s.g = std::tan(std::numbers::pi * b.frequency / fs);
    s.k = 1. / b.q;
    switch (b.type) {
    case PT_BELL: s.k /= A; s.m1 = s.k * (A*A - 1); break;
    case PT_LOW_SHELF:
        s.g /= std::sqrt(A); s.m1 = s.k*(A-1); s.m2 = A*A-1; break;
    case PT_HIGH_SHELF:
        s.g *= std::sqrt(A); s.m0 = A*A; s.m1 = s.k*(1-A)*A; s.m2 = 1-A*A; break;
    case PT_LOW_PASS: s.m0 = 0; s.m2 = 1; break;
    case PT_HIGH_PASS: s.m1 = -s.k; s.m2 = -1; break;
    case PT_BAND_PASS: s.m0 = 0; s.m1 = s.k; break;
    case PT_NOTCH: s.m1 = -s.k; break;
    default: throw std::invalid_argument("Unknown filter type");
    }
    s.d = 1. / (1 + s.g*(s.g+s.k));
    return s;
}
double Section::tick(double x, double &s1, double &s2) const noexcept {
    if (bypass) return x;
    const double hp = (x-(g+k)*s1-s2)*d;
    const double bp = std::fma(g, hp, s1);
    const double lp = std::fma(g, bp, s2);
    s1 = std::fma(g, hp, bp);
    s2 = std::fma(g, bp, lp);
    return std::fma(m2, lp, std::fma(m1, bp, m0*x));
}
std::complex<double> Section::response(double w) const {
    if (bypass) return 1.;
    // State-space transfer, avoiding subtraction of rounded z-domain coefficients.
    using C = std::complex<double>;
    const C z = std::polar(1., w);
    const double a = 1-2*g*(g+k)*d, b = -2*g*d;
    const double c = 2*g-2*g*g*(g+k)*d, e = 1-2*g*g*d;
    const double u = 2*g*d, v = 2*g*g*d;
    const double cp = m1*(1-g*(g+k)*d)+m2*(g-g*g*(g+k)*d);
    const double cq = -m1*g*d+m2*(1-g*g*d);
    const double direct = m0+m1*g*d+m2*g*g*d;
    const C det = (z-a)*(z-e)-b*c;
    return direct+(cp*((z-e)*u+b*v)+cq*(c*u+(z-a)*v))/det;
}
double Section::l1Bound() const {
    if (bypass) return 1.;
    // Sum a finite impulse and bound the infinite tail by eigenmodes.
    // This is an L-infinity input/output bound, not just the frequency-response peak.
    using C = std::complex<long double>;
    const long double G=g,K=k,D=d;
    const long double a=1-2*G*(G+K)*D,b=-2*G*D,c=2*G-2*G*G*(G+K)*D,e=1-2*G*G*D;
    const long double cp=m1*(1-G*(G+K)*D)+m2*(G-G*G*(G+K)*D);
    const long double cq=-m1*G*D+m2*(1-G*G*D);
    const long double direct=m0+m1*G*D+m2*G*G*D;
    const C disc=std::sqrt(C((a-e)*(a-e)+4*b*c,0));
    const C l1=(a+e+disc)/2.L,l2=(a+e-disc)/2.L;
    if (std::abs(l1)>=1 || std::abs(l2)>=1) return std::numeric_limits<double>::infinity();
    long double s1=2*G*D,s2=2*G*G*D,sum=std::abs(direct);
    constexpr size_t N=4096;
    for(size_t i=0;i<N;i++) {
        sum+=std::abs(cp*s1+cq*s2);
        const auto n1=a*s1+b*s2; s2=c*s1+e*s2; s1=n1;
    }
    const long double h0=cp*s1+cq*s2;
    const long double h1=cp*(a*s1+b*s2)+cq*(c*s1+e*s2);
    long double tail;
    if(std::abs(l1-l2)>1e-10L) {
        const C t1=(h1-l2*h0)/(l1-l2),t2=h0-t1;
        tail=std::abs(t1)/(1-std::abs(l1))+std::abs(t2)/(1-std::abs(l2));
    } else {
        // Repeated-pole envelope: h[n]=(h0+n*(h1/lambda-h0))*lambda^n.
        const long double r=std::max(std::abs(l1),std::abs(l2));
        tail=std::abs(h0)/(1-r)+std::abs(h1-l1*h0)/((1-r)*(1-r));
    }
    return double((sum+tail)*(1+1e-9L)+1e-12L);
}
DSP::DSP(double fs,int ch,const PTEQ &eq):channels(ch) {
    if(ch<1 || ch>2 || !pt_eq_validate(&eq,fs)) throw std::invalid_argument("Invalid DSP configuration");
    if(!eq.enabled) return;
    count=eq.count; gain=std::pow(10.,eq.preampDB/20.);
    for(int i=0;i<count;i++) filters[i]=Section::design(eq.bands[i],fs);
}
void DSP::reset() noexcept { for(auto &s:states) s={0,0}; }
bool DSP::process(const double *in,double *out,size_t frames) noexcept {
    for(size_t n=0;n<frames;n++) for(int ch=0;ch<channels;ch++) {
        double x=in[n*channels+ch]*gain;
        for(int i=0;i<count;i++) {
            auto &s=states[i*2+ch]; x=filters[i].tick(x,s[0],s[1]);
        }
        if(!std::isfinite(x)) return false;
        out[n*channels+ch]=x;
    }
    return true;
}
}
