#pragma once
#include "PureToneCore.h"
#include <memory>
#include <functional>
#include <string>
#include <vector>
namespace pt {
class Decoder {
public:
    PTFileInfo info{};
    virtual ~Decoder()=default;
    virtual size_t read(double *out,size_t frames)=0;
    virtual void seek(uint64_t frame)=0;
    static std::unique_ptr<Decoder> open(const std::string &path, bool indexWholeFile=false);
    static std::unique_ptr<Decoder> open(PTByteSource source,const std::string &extension);
    static std::unique_ptr<Decoder> prepare(const std::string &path, size_t frames);
};
class Reader {
public:
    Reader(const std::string &path,double rate);
    Reader(PTByteSource source,const std::string &extension,double rate);
    ~Reader();
    size_t read(double *out,size_t frames);
    void seek(double seconds);
    PTFileInfo info() const {return decoder->info;}
    // Supplies an already opened raw decoder before draining SRC. Called only by the decode worker.
    std::function<std::unique_ptr<Decoder>(uint64_t)> continuation;
private:
    std::unique_ptr<Decoder> decoder;
    void *resampler{};
    double rate;
    std::vector<double> input;
    size_t used{},available{};
    bool eof{};
    uint64_t trackInputFrames{};
    size_t readSource(double *output, size_t frames);
    void configure();
};
}
