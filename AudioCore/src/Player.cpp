#include "DSP.hpp"
#include "Decoder.hpp"
#include <soxr.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <thread>
#include <string>
#include <utility>
namespace {
constexpr size_t capacity=8192,blockSize=1024;
struct Frame {float l{},r{};double position{};uint64_t track{},revision{};};
struct Ring {
    std::array<Frame,capacity> data{};
    alignas(64) std::atomic<uint64_t> head{0};
    alignas(64) std::atomic<uint64_t> tail{0};
    size_t room()const{return capacity-size_t(head.load(std::memory_order_relaxed)-tail.load(std::memory_order_acquire));}
    void push(const Frame &x){auto h=head.load(std::memory_order_relaxed);data[h%capacity]=x;head.store(h+1,std::memory_order_release);}
    bool pop(Frame &x){auto t=tail.load(std::memory_order_relaxed);if(t==head.load(std::memory_order_acquire))return false;x=data[t%capacity];tail.store(t+1,std::memory_order_release);return true;}
};
}
struct PTPreparedTrack {
    std::unique_ptr<pt::Decoder> decoder;
    std::string path;
    double outputRate{};
    PTPreparedTrack(const char *file,double rate):decoder(pt::Decoder::prepare(file,blockSize)),path(file),outputRate(rate) {}
};
struct PTPlayer {
    Ring ring;
    double rate;
    PTFileInfo original{};
    std::unique_ptr<pt::Reader> reader;
    std::unique_ptr<pt::DSP> current,previous;
    PTEQ requested{};
    double requestedGain{};
    bool pendingEQ{};
    uint64_t requestedRevision{};
    size_t transition{};
    std::unique_ptr<PTPreparedTrack> nextTrack;
    std::mutex control;
    std::atomic<bool> stop{false},paused{true},finished{false};
    std::atomic<int> fault{0},rendering{0};
    std::atomic<double> position{0};
    std::atomic<uint64_t> track{0},underruns{0};
    std::atomic<uint64_t> audibleRevision{0};
    std::thread worker;
    double seekBase{};
    uint64_t produced{},producingTrack{},producingRevision{};
    struct Boundary { uint64_t frame,track; };
    std::vector<Boundary> boundaries;
    std::vector<std::string> trackPaths;
    size_t boundaryCursor{};
    uint64_t decodedTrack{},completedInputFrames{},sourceStart{},outputTrackStart{};
    std::vector<double> history;
    size_t historyFrames{},historyCursor{};
    PTPlayer(const char *path,double fs,const PTEQ &eq,double gain):PTPlayer(std::make_unique<pt::Reader>(path,fs),fs,eq,gain,path){}
    PTPlayer(PTByteSource source,const char *ext,double fs,const PTEQ &eq):PTPlayer(std::make_unique<pt::Reader>(source,ext,fs),fs,eq,0){}
    PTPlayer(std::unique_ptr<pt::Reader> source,double fs,const PTEQ &eq,double gain,std::string path={}):rate(fs),reader(std::move(source)) {
        original=reader->info();requested=eq;requestedGain=gain;
        trackPaths.push_back(std::move(path));
        auto applied=eq;applied.preampDB=gain;current=std::make_unique<pt::DSP>(rate,original.channels,applied);
        history.resize(size_t(rate)*2*original.channels);
        start();
    }
    ~PTPlayer(){stop=true;if(worker.joinable())worker.join();}
    void start(){
        reader->continuation=[this](uint64_t endedFrames)->std::unique_ptr<pt::Decoder> {
            std::unique_ptr<PTPreparedTrack> next;
            {std::lock_guard lock(control);next=std::move(nextTrack);}
            if(!next)return nullptr;
            completedInputFrames+=endedFrames-sourceStart;sourceStart=0;
            decodedTrack++;
            boundaries.push_back({uint64_t(std::llround(double(completedInputFrames)*rate/original.sampleRate)),decodedTrack});
            trackPaths.resize(size_t(decodedTrack)+1);trackPaths[size_t(decodedTrack)]=std::move(next->path);
            return std::move(next->decoder);
        };
        stop=false;finished=false;worker=std::thread([this]{produce();});
    }
    void produce() {
        try {
            std::vector<double> input(blockSize*original.channels),output(input.size()),old(input.size());
            std::array<uint64_t,blockSize> revisions{};
            while(!stop.load()) {
                if(ring.room()<blockSize){std::this_thread::sleep_for(std::chrono::milliseconds(2));continue;}
                {
                    std::lock_guard lock(control);
                    if(pendingEQ&&!transition) {
                        auto eq=requested;eq.preampDB=requestedGain;
                        previous=std::move(current);current=std::make_unique<pt::DSP>(rate,original.channels,eq);
                        // Warm the independent state with recent input before blending.
                        const size_t historyCapacity=history.size()/original.channels;
                        for(size_t i=0;i<historyFrames;i++) {
                            auto offset=(historyCursor+historyCapacity-historyFrames+i)%historyCapacity;
                            if(!current->process(history.data()+offset*original.channels,old.data(),1))throw std::runtime_error("EQ warm-up failed");
                        }
                        transition=size_t(rate*.05);pendingEQ=false;
                        producingRevision=requestedRevision;
                    }
                }
                const size_t n=reader->read(input.data(),blockSize);
                if(!n){finished=true;return;}
                if(!current->process(input.data(),output.data(),n))throw std::runtime_error("Non-finite DSP output");
                revisions.fill(producingRevision);
                if(transition&&previous) {
                    if(!previous->process(input.data(),old.data(),n))throw std::runtime_error("Non-finite transition output");
                    for(size_t i=0;i<n;i++) {
                        const double w=transition?double(transition)/double(size_t(rate*.05)):0;
                        for(int c=0;c<original.channels;c++)output[i*original.channels+c]=(1-w)*output[i*original.channels+c]+w*old[i*original.channels+c];
                        if(transition)transition--;
                        revisions[i]=transition?producingRevision-1:producingRevision;
                    }
                    if(!transition)previous.reset();
                }
                for(size_t i=0;i<n;i++) {
                    const double l=output[i*original.channels],r=output[i*original.channels+original.channels-1];
                    if(!std::isfinite(l)||!std::isfinite(r)||std::abs(l)>1.0000001||std::abs(r)>1.0000001)throw std::runtime_error("PCM overload: playback stopped; reduce gain");
                    while(boundaryCursor<boundaries.size()&&produced+i>=boundaries[boundaryCursor].frame) {
                        const auto &b=boundaries[boundaryCursor++];producingTrack=b.track;outputTrackStart=b.frame;seekBase=0;
                    }
                    ring.push({float(l),float(r),seekBase+double(produced+i-outputTrackStart)/rate,producingTrack,revisions[i]});
                    for(int c=0;c<original.channels;c++)history[historyCursor*original.channels+c]=input[i*original.channels+c];
                    historyCursor=(historyCursor+1)%(history.size()/original.channels);historyFrames=std::min(historyFrames+1,history.size()/original.channels);
                }
                produced+=n;
            }
        } catch(const std::exception &e){pt_set_error(e.what());fault=-1;finished=true;}
    }
};
extern "C" int pt_analyze(const char *path,double fs,const PTEQ *eq,PTAnalysis *out) {
    return pt_analyze_cancelable(path,fs,eq,out,nullptr,nullptr);
}
extern "C" int pt_analyze_cancelable(const char *path,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *)) {
    return pt_analyze_sequence_cancelable(&path,1,fs,eq,out,context,cancelled);
}
extern "C" int pt_analyze_sequence_cancelable(const char *const *paths,size_t count,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *)) {
    if(!eq||!out||!paths||!count)return 0;
    soxr_t up{};
    try {
        for(size_t i=0;i<count;i++)if(!paths[i])throw std::runtime_error("Null analysis path");
        pt::Reader source(paths[0],fs);int ch=source.info().channels;pt::DSP dsp(fs,ch,*eq);size_t next=1;
        source.continuation=[&](uint64_t)->std::unique_ptr<pt::Decoder>{return next<count?pt::Decoder::open(paths[next++]):nullptr;};
        auto io=soxr_io_spec(SOXR_FLOAT64_I,SOXR_FLOAT64_I);auto q=soxr_quality_spec(SOXR_VHQ,SOXR_DOUBLE_PRECISION);
        soxr_error_t err{};auto rt=soxr_runtime_spec(1);up=soxr_create(fs,fs*8,unsigned(ch),&err,&io,&q,&rt);
        if(err||!up)throw std::runtime_error(err?err:"True-peak SRC failed");
        std::vector<double> in(8192*ch),processed(in.size()),hi(8192*8*ch);PTAnalysis a{};
        for(;;) {
            if(cancelled&&cancelled(context))throw std::runtime_error("Analysis cancelled");
            size_t n=source.read(in.data(),8192);
            if(!dsp.process(in.data(),processed.data(),n))throw std::runtime_error("Analysis DSP not finite");
            for(size_t i=0;i<n*ch;i++){a.inputPeak=std::max(a.inputPeak,std::abs(in[i]));a.samplePeak=std::max(a.samplePeak,std::abs(processed[i]));}
            a.frames+=n;size_t used=0;
            do {
                size_t id=0,od=0;
                err=soxr_process(up,n?processed.data()+used*ch:nullptr,n-used,&id,hi.data(),hi.size()/ch,&od);
                if(err)throw std::runtime_error(err);
                for(size_t i=0;i<od*ch;i++)a.truePeak=std::max(a.truePeak,std::abs(hi[i]));
                used+=id;
                if(n==0&&od==0)break;
            }while(used<n||n==0);
            if(!n)break;
        }
        soxr_delete(up);up=nullptr;
        a.truePeak=std::max(a.truePeak,a.samplePeak);
        a.safetyDB=eq->enabled&&a.truePeak>0?std::min(0.,-1.-20*std::log10(a.truePeak)):0;
        a.effectivePreampDB=eq->enabled?eq->preampDB+a.safetyDB:0;*out=a;return 1;
    }catch(const std::exception&e){if(up)soxr_delete(up);pt_set_error(e.what());return 0;}
}
extern "C" PTPlayer *pt_player_create(const char *path,double fs,const PTEQ *eq,double gain) {
    try{if(!eq||!std::isfinite(gain))throw std::runtime_error("Invalid player settings");return new PTPlayer(path,fs,*eq,gain);}catch(const std::exception&e){pt_set_error(e.what());return nullptr;}
}
extern "C" PTPlayer *pt_player_create_source(PTByteSource source,const char *ext,double fs,const PTEQ *eq) {
    try {if(!eq||eq->enabled)throw std::runtime_error("Streaming byte sources require EQ bypass until full analysis");return new PTPlayer(source,ext,fs,*eq);}catch(const std::exception&e){pt_set_error(e.what());return nullptr;}
}
extern "C" void pt_player_destroy(PTPlayer *p){delete p;}
extern "C" void pt_player_pause(PTPlayer *p,int pause){if(p)p->paused=pause!=0;}
extern "C" int pt_player_set_eq(PTPlayer *p,const PTEQ *eq,double gain) {
    return pt_player_set_eq_revision(p,eq,gain)>0;
}
extern "C" uint64_t pt_player_set_eq_revision(PTPlayer *p,const PTEQ *eq,double gain) {
    if(!p||!pt_eq_validate(eq,p->rate)||!std::isfinite(gain))return 0;
    std::lock_guard lock(p->control);p->requested=*eq;p->requestedGain=gain;p->pendingEQ=true;return ++p->requestedRevision;
}
extern "C" int pt_player_seek(PTPlayer *p,double sec) {
    if(!p||!std::isfinite(sec)||sec<0)return 0;
    bool paused=p->paused.exchange(true);
    while(p->rendering.load())std::this_thread::yield();
    p->stop=true;if(p->worker.joinable())p->worker.join();
    try {
        const auto audible=p->track.load();
        if(audible<p->trackPaths.size()&&!p->trackPaths[size_t(audible)].empty())
            p->reader=std::make_unique<pt::Reader>(p->trackPaths[size_t(audible)],p->rate);
        p->reader->seek(sec);p->seekBase=sec;p->produced=0;p->position=sec;
        p->decodedTrack=p->producingTrack=audible;p->boundaries.clear();p->boundaryCursor=0;
        p->completedInputFrames=p->outputTrackStart=0;p->sourceStart=uint64_t(sec*p->original.sampleRate);
        p->trackPaths.resize(size_t(audible)+1);p->nextTrack.reset();
        p->ring.head=0;p->ring.tail=0;p->current->reset();p->previous.reset();p->transition=0;p->fault=0;p->historyFrames=p->historyCursor=0;
        p->start();p->paused=paused;return 1;
    }catch(const std::exception&e){pt_set_error(e.what());p->fault=-1;return 0;}
}
extern "C" int pt_player_enqueue(PTPlayer *p,const char *path) {
    auto *prepared=pt_prepare_track(path,p?p->rate:0);
    if(!prepared)return 0;
    if(pt_player_enqueue_prepared(p,prepared))return 1;
    delete prepared;return 0;
}
extern "C" PTPreparedTrack *pt_prepare_track(const char *path,double rate) {
    try{return new PTPreparedTrack(path,rate);}catch(const std::exception&e){pt_set_error(e.what());return nullptr;}
}
extern "C" void pt_prepared_track_destroy(PTPreparedTrack *p){delete p;}
extern "C" void pt_player_clear_next(PTPlayer *p){if(p){std::lock_guard lock(p->control);p->nextTrack.reset();}}
extern "C" int pt_player_enqueue_prepared(PTPlayer *p,PTPreparedTrack *prepared) {
    try {
        if(!p||!prepared||prepared->outputRate!=p->rate)return 0;
        auto info=prepared->decoder->info;if(info.sampleRate!=p->original.sampleRate||info.channels!=p->original.channels)return 0;
        std::lock_guard lock(p->control);p->nextTrack.reset(prepared);return 1;
    }catch(const std::exception&e){pt_set_error(e.what());return 0;}
}
extern "C" size_t pt_player_render(PTPlayer *p,float *out,size_t n) {
    if(!p||!out)return 0;
    p->rendering.fetch_add(1);
    if(p->paused.load()||p->fault.load()) {std::fill_n(out,n*2,0.f);p->rendering.fetch_sub(1);return 0;}
    size_t done=0;Frame f;
    while(done<n&&p->ring.pop(f)){out[done*2]=f.l;out[done*2+1]=f.r;p->position=f.position;p->track=f.track;p->audibleRevision=f.revision;done++;}
    if(done<n){std::fill(out+done*2,out+n*2,0.f);if(!p->finished)p->underruns++;}
    p->rendering.fetch_sub(1);return done;
}
extern "C" double pt_player_position(PTPlayer*p){return p?p->position.load():0;}
extern "C" uint64_t pt_player_track_index(PTPlayer*p){return p?p->track.load():0;}
extern "C" int pt_player_state(PTPlayer*p){if(!p)return -1;if(p->fault)return -1;if(p->finished&&p->ring.room()==capacity)return 2;return p->ring.room()<capacity?1:0;}
extern "C" uint64_t pt_player_underruns(PTPlayer*p){return p?p->underruns.load():0;}
extern "C" uint64_t pt_player_eq_revision(PTPlayer*p){return p?p->audibleRevision.load():0;}
