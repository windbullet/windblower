#pragma once
#include "PureToneCore.h"
#include <array>
#include <complex>
#include <vector>
namespace pt {
struct Section {
    double g{}, k{}, d{}, m0{1}, m1{}, m2{};
    bool bypass{true};
    static Section design(const PTBand &, double rate);
    double tick(double x, double &s1, double &s2) const noexcept;
    std::complex<double> response(double radians) const;
    double l1Bound() const;
};
class DSP {
public:
    DSP(double rate, int channels, const PTEQ &eq);
    bool process(const double *, double *, size_t) noexcept;
    void reset() noexcept;
    int channels;
private:
    std::array<Section, PT_MAX_BANDS> filters{};
    std::array<std::array<double, 2>, PT_MAX_BANDS * 2> states{};
    int count{};
    double gain{1};
};
}
