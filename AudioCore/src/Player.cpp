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
struct Frame {float l{},r{};double position{};uint64_t track{},revision{},modeRevision{};};
struct Ring {
    std::array<Frame,capacity> data{};
    alignas(64) std::atomic<uint64_t> head{0};
    alignas(64) std::atomic<uint64_t> tail{0};
    size_t room()const{return capacity-size_t(head.load(std::memory_order_relaxed)-tail.load(std::memory_order_acquire));}
    void push(const Frame &x){auto h=head.load(std::memory_order_relaxed);data[h%capacity]=x;head.store(h+1,std::memory_order_release);}
    bool pop(Frame &x){auto t=tail.load(std::memory_order_relaxed);if(t==head.load(std::memory_order_acquire))return false;x=data[t%capacity];tail.store(t+1,std::memory_order_release);return true;}
};

// Keep the filtered path running while auditioning dry. A/B must not reset an IIR,
// rerun an offline scan, or replace the calibrated gain with a pessimistic bound.
class PlaybackDSP {
    pt::DSP wet;
    bool hasEQ{};
    double gain{1},dryGain{1},dryTarget{1},mix{1},mixTarget{1};
    size_t remaining{},fadeFrames;
public:
    PlaybackDSP(double rate,int channels,const PTEQ &eq):wet(rate,channels,eq),hasEQ(eq.enabled),
        gain(eq.enabled?std::pow(10.,eq.preampDB/20.):1),dryGain(gain),dryTarget(gain),fadeFrames(size_t(rate*.05)) {}
    bool sameShape(const PTEQ &eq)const noexcept{return wet.sameShape(eq);}
    void setGain(double db)noexcept {
        wet.setGain(db);gain=hasEQ?std::pow(10.,db/20.):1;
        dryGain=dryTarget=gain;
    }
    void setBypass(bool bypassed,bool preserveGain,bool immediate=false)noexcept {
        const double nextMix=hasEQ&&!bypassed?1.:0.;
        const double nextDry=preserveGain?gain:1.;
        if(nextMix==mixTarget&&nextDry==dryTarget&&!immediate)return;
        mixTarget=nextMix;dryTarget=nextDry;
        remaining=immediate?0:fadeFrames;
        if(immediate){mix=mixTarget;dryGain=dryTarget;}
    }
    bool changingMode()const noexcept{return remaining!=0;}
    bool process(const double *in,double *out,size_t frames)noexcept {
        if(!wet.process(in,out,frames))return false;
        for(size_t n=0;n<frames;n++) {
            if(remaining){mix+=(mixTarget-mix)/double(remaining);dryGain+=(dryTarget-dryGain)/double(remaining);--remaining;}
            for(int c=0;c<wet.channels;c++) {
                const size_t i=n*wet.channels+c;
                // Exact endpoints avoid unnecessary mixing roundoff in steady-state paths.
                if(mix==0)out[i]=in[i]*dryGain;
                else if(mix!=1)out[i]=mix*out[i]+(1-mix)*in[i]*dryGain;
            }
        }
        return true;
    }
};
}
struct PTPreparedTrack {
    std::unique_ptr<pt::Decoder> decoder;
    std::string path;
    double outputRate{};
    PTPreparedTrack(const char *file,double rate):decoder(pt::Decoder::prepare(file,blockSize)),path(file),outputRate(rate) {}
};
struct PTPlayer {
    struct Verified {std::unique_ptr<PlaybackDSP> dsp;uint64_t frame{},revision{};};
    Ring ring;
    double rate;
    PTFileInfo original{};
    std::unique_ptr<pt::Reader> reader;
    std::unique_ptr<PlaybackDSP> current,previous;
    PTEQ requested{};
    double requestedGain{};
    bool pendingEQ{};
    bool requestedBypass{},preserveBypassGain{true},pendingBypass{};
    uint64_t requestedModeRevision{},producingModeRevision{},settledModeRevision{};
    std::string errorText;
    uint64_t requestedRevision{};
    std::atomic<uint64_t> latestRevision{0},processedFrame{0};
    std::unique_ptr<Verified> verified;
    std::thread verificationWorker;
    size_t transition{};
    uint64_t previousRevision{};
    std::unique_ptr<PTPreparedTrack> nextTrack;
    std::mutex control;
    std::atomic<bool> stop{false},paused{true},finished{false};
    std::atomic<int> fault{0},rendering{0};
    std::atomic<double> position{0};
    std::atomic<uint64_t> track{0},underruns{0};
    std::atomic<uint64_t> audibleRevision{0};
    std::atomic<uint64_t> audibleModeRevision{0};
    std::thread worker;
    double seekBase{};
    uint64_t produced{},producingTrack{},producingRevision{};
    struct Boundary { uint64_t frame,track; };
    std::vector<Boundary> boundaries;
    std::vector<std::string> trackPaths;
    size_t boundaryCursor{};
    uint64_t decodedTrack{},outputTrackStart{},stateBaseFrame{};
    std::vector<uint64_t> trackInputStarts{0};
    std::vector<double> history;
    size_t historyFrames{},historyCursor{};
    PTPlayer(const char *path,double fs,const PTEQ &eq,double gain):PTPlayer(std::make_unique<pt::Reader>(path,fs),fs,eq,gain,path){}
    PTPlayer(PTByteSource source,const char *ext,double fs,const PTEQ &eq):PTPlayer(std::make_unique<pt::Reader>(source,ext,fs),fs,eq,0){}
    PTPlayer(std::unique_ptr<pt::Reader> source,double fs,const PTEQ &eq,double gain,std::string path={}):rate(fs),reader(std::move(source)) {
        original=reader->info();requested=eq;requestedGain=gain;
        trackPaths.push_back(std::move(path));
        auto applied=eq;applied.preampDB=gain;current=std::make_unique<PlaybackDSP>(rate,original.channels,applied);
        history.resize(size_t(rate)*2*original.channels);
        start();
    }
    ~PTPlayer(){stop=true;latestRevision++;if(worker.joinable())worker.join();if(verificationWorker.joinable())verificationWorker.join();}
    void fail(const std::exception &error) {
        {std::lock_guard lock(control);errorText=error.what();}
        fault=-1;finished=true;
    }
    std::unique_ptr<pt::Reader> replay(const std::vector<std::string> &paths) const {
        if(paths.empty()||paths[0].empty())throw std::runtime_error("Exact state reconstruction requires complete local originals");
        auto source=std::make_unique<pt::Reader>(paths[0],rate);
        source->continuation=[paths,next=size_t(1)](uint64_t)mutable->std::unique_ptr<pt::Decoder>{
            return next<paths.size()?pt::Decoder::open(paths[next++]):nullptr;
        };
        return source;
    }
    void start(){
        reader->continuation=[this](uint64_t endedFrames)->std::unique_ptr<pt::Decoder> {
            std::unique_ptr<PTPreparedTrack> next;
            {
                std::lock_guard lock(control);next=std::move(nextTrack);
                if(!next)return nullptr;
                const uint64_t end=trackInputStarts[size_t(decodedTrack)]+endedFrames;
                decodedTrack++;trackInputStarts.resize(size_t(decodedTrack)+1);trackInputStarts[size_t(decodedTrack)]=end;
                boundaries.push_back({uint64_t(std::llround(double(end)*rate/original.sampleRate))-stateBaseFrame,decodedTrack});
                trackPaths.resize(size_t(decodedTrack)+1);trackPaths[size_t(decodedTrack)]=std::move(next->path);
            }
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
                PTEQ update{};double gain{};uint64_t revision{},modeRevision{};bool change=false;
                bool changeMode=false,bypassed=false,preserveGain=true;
                std::unique_ptr<Verified> ready;
                {
                    std::lock_guard lock(control);
                    if(!transition) {
                        if(verified&&verified->revision==latestRevision.load()){ready=std::move(verified);revision=ready->revision;change=true;}
                        else if(pendingEQ){update=requested;gain=requestedGain;revision=requestedRevision;pendingEQ=false;change=true;}
                    }
                    bypassed=requestedBypass;preserveGain=preserveBypassGain;
                    if(pendingBypass){changeMode=true;modeRevision=requestedModeRevision;pendingBypass=false;}
                }
                if(change) {
                    const size_t historyCapacity=history.size()/original.channels;
                    std::unique_ptr<PlaybackDSP> replacement;
                    if(ready) {
                        const uint64_t at=stateBaseFrame+produced;
                        if(ready->frame>at||at-ready->frame>historyFrames)throw std::runtime_error("Verified EQ could not catch up with the playback history");
                        const size_t missing=size_t(at-ready->frame);
                        for(size_t i=0;i<missing;i++) {
                            const size_t offset=(historyCursor+historyCapacity-missing+i)%historyCapacity;
                            if(!ready->dsp->process(history.data()+offset*original.channels,old.data(),1))throw std::runtime_error("Verified EQ state not finite");
                        }
                        replacement=std::move(ready->dsp);
                    } else if(current->sameShape(update)) {
                        // Static gain calibration must not discard a long high-Q filter history.
                        replacement=std::make_unique<PlaybackDSP>(*current);replacement->setGain(gain);
                    } else {
                        update.preampDB=gain;replacement=std::make_unique<PlaybackDSP>(rate,original.channels,update);
                        // Live preview is conservative. Exact full-source history is restored after analysis.
                        const size_t historyCapacity=history.size()/original.channels;
                        for(size_t i=0;i<historyFrames;i++) {
                            auto offset=(historyCursor+historyCapacity-historyFrames+i)%historyCapacity;
                            if(!replacement->process(history.data()+offset*original.channels,old.data(),1))throw std::runtime_error("EQ warm-up failed");
                        }
                    }
                    // Coalesce requests that arrived while warming a potentially long cascade.
                    if(revision==latestRevision.load()) {
                        replacement->setBypass(bypassed,preserveGain,true);
                        previous=std::move(current);current=std::move(replacement);
                        transition=size_t(rate*.05);previousRevision=producingRevision;producingRevision=revision;
                    }
                }
                if(changeMode) {
                    current->setBypass(bypassed,preserveGain);
                    if(previous)previous->setBypass(bypassed,preserveGain);
                    producingModeRevision=modeRevision;
                }
                const uint64_t blockModeRevision=current->changingMode()||(previous&&previous->changingMode())
                    ?settledModeRevision:producingModeRevision;
                settledModeRevision=blockModeRevision;
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
                        revisions[i]=w>0?previousRevision:producingRevision;
                    }
                    if(!transition)previous.reset();
                }
                for(size_t i=0;i<n;i++) {
                    const double l=output[i*original.channels],r=output[i*original.channels+original.channels-1];
                    if(!std::isfinite(l)||!std::isfinite(r))throw std::runtime_error("Non-finite audio sample; playback stopped");
                    if(std::abs(l)>1.0000001||std::abs(r)>1.0000001) {
                        const double peak=std::max(std::abs(l),std::abs(r));
                        throw std::runtime_error("PCM overload: +"+std::to_string(20*std::log10(peak))+" dBFS; track="+std::to_string(producingTrack)+"; frame="+std::to_string(stateBaseFrame+produced+i)+"; EQ="+std::to_string(producingRevision));
                    }
                    while(boundaryCursor<boundaries.size()&&produced+i>=boundaries[boundaryCursor].frame) {
                        const auto &b=boundaries[boundaryCursor++];producingTrack=b.track;outputTrackStart=b.frame;seekBase=0;
                    }
                    ring.push({float(l),float(r),seekBase+double(produced+i-outputTrackStart)/rate,producingTrack,revisions[i],blockModeRevision});
                    for(int c=0;c<original.channels;c++)history[historyCursor*original.channels+c]=input[i*original.channels+c];
                    historyCursor=(historyCursor+1)%(history.size()/original.channels);historyFrames=std::min(historyFrames+1,history.size()/original.channels);
                }
                produced+=n;
                processedFrame.store(stateBaseFrame+produced,std::memory_order_release);
            }
        } catch(const std::exception &e){if(!stop.load())fail(e);}
    }
};
extern "C" int pt_analyze(const char *path,double fs,const PTEQ *eq,PTAnalysis *out) {
    return pt_analyze_cancelable(path,fs,eq,out,nullptr,nullptr);
}
extern "C" int pt_analyze_cancelable(const char *path,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *)) {
    return pt_analyze_sequence_cancelable(&path,1,fs,eq,out,context,cancelled);
}
static int analyzeSequence(const char *const *paths,size_t count,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *),bool comparison) {
    if(!eq||!out||!paths||!count)return 0;
    soxr_t up{};
    try {
        for(size_t i=0;i<count;i++)if(!paths[i])throw std::runtime_error("Null analysis path");
        pt::Reader source(paths[0],fs);int ch=source.info().channels;pt::DSP dsp(fs,ch,*eq);size_t next=1;
        source.continuation=[&](uint64_t)->std::unique_ptr<pt::Decoder>{return next<count?pt::Decoder::open(paths[next++]):nullptr;};
        auto io=soxr_io_spec(SOXR_FLOAT64_I,SOXR_FLOAT64_I);auto q=soxr_quality_spec(SOXR_VHQ,SOXR_DOUBLE_PRECISION);
        const int analysisChannels=comparison?ch*2:ch;
        const double dryGain=eq->enabled?std::pow(10.,eq->preampDB/20.):1.;
        soxr_error_t err{};auto rt=soxr_runtime_spec(1);up=soxr_create(fs,fs*8,unsigned(analysisChannels),&err,&io,&q,&rt);
        if(err||!up)throw std::runtime_error(err?err:"True-peak SRC failed");
        std::vector<double> in(8192*ch),processed(in.size()),measure(8192*analysisChannels),hi(8192*8*analysisChannels);PTAnalysis a{};
        for(;;) {
            if(cancelled&&cancelled(context))throw std::runtime_error("Analysis cancelled");
            size_t n=source.read(in.data(),8192);
            if(!dsp.process(in.data(),processed.data(),n))throw std::runtime_error("Analysis DSP not finite");
            for(size_t i=0;i<n*ch;i++){a.inputPeak=std::max(a.inputPeak,std::abs(in[i]));a.samplePeak=std::max(a.samplePeak,std::abs(processed[i]));}
            if(comparison)for(size_t i=0;i<n;i++)for(int c=0;c<ch;c++) {
                measure[i*analysisChannels+c]=processed[i*ch+c];
                const double dry=in[i*ch+c]*dryGain;
                measure[i*analysisChannels+ch+c]=dry;
                a.samplePeak=std::max(a.samplePeak,std::abs(dry));
            }
            const double *analysisInput=comparison?measure.data():processed.data();
            a.frames+=n;size_t used=0;
            do {
                size_t id=0,od=0;
                err=soxr_process(up,n?analysisInput+used*analysisChannels:nullptr,n-used,&id,hi.data(),hi.size()/analysisChannels,&od);
                if(err)throw std::runtime_error(err);
                for(size_t i=0;i<od*analysisChannels;i++)a.truePeak=std::max(a.truePeak,std::abs(hi[i]));
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
extern "C" int pt_analyze_sequence_cancelable(const char *const *paths,size_t count,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *)) {
    return analyzeSequence(paths,count,fs,eq,out,context,cancelled,false);
}
extern "C" int pt_analyze_comparison_sequence_cancelable(const char *const *paths,size_t count,double fs,const PTEQ *eq,PTAnalysis *out,void *context,int (*cancelled)(void *)) {
    return analyzeSequence(paths,count,fs,eq,out,context,cancelled,true);
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
    std::lock_guard lock(p->control);p->requested=*eq;p->requestedGain=gain;p->pendingEQ=true;p->verified.reset();
    p->requestedRevision=p->latestRevision.fetch_add(1)+1;return p->requestedRevision;
}
extern "C" uint64_t pt_player_set_bypass(PTPlayer *p,int bypassed,int preserveGain) {
    if(!p)return 0;
    std::lock_guard lock(p->control);p->requestedBypass=bypassed!=0;p->preserveBypassGain=preserveGain!=0;
    p->pendingBypass=true;return ++p->requestedModeRevision;
}
extern "C" void pt_player_cancel_eq_update(PTPlayer *p) {
    if(!p)return;
    std::lock_guard lock(p->control);p->latestRevision++;p->pendingEQ=false;p->verified.reset();
}
extern "C" uint64_t pt_player_bypass_revision(PTPlayer *p){return p?p->audibleModeRevision.load():0;}
extern "C" const char *pt_player_error(PTPlayer *p) {
    static thread_local std::string message;
    if(!p){message="Player unavailable";return message.c_str();}
    std::lock_guard lock(p->control);message=p->errorText;return message.c_str();
}
extern "C" uint64_t pt_player_set_verified_eq_revision(PTPlayer *p,const PTEQ *eq,double gain) {
    if(!p||!pt_eq_validate(eq,p->rate)||!std::isfinite(gain))return 0;
    const uint64_t revision=p->latestRevision.fetch_add(1)+1;
    if(p->verificationWorker.joinable())p->verificationWorker.join();
    std::string firstPath;
    {std::lock_guard lock(p->control);p->pendingEQ=false;p->verified.reset();firstPath=p->trackPaths.front();}
    auto applied=*eq;applied.preampDB=gain;
    {std::lock_guard lock(p->control);p->requested=*eq;p->requestedGain=gain;p->requestedRevision=revision;}
    p->verificationWorker=std::thread([p,applied,firstPath=std::move(firstPath),revision] {
        try {
            if(firstPath.empty())throw std::runtime_error("Verified EQ requires complete local originals");
            auto source=std::make_unique<pt::Reader>(firstPath,p->rate);
            // The producer can cross a track boundary while reconstruction catches up.
            // Resolve each crossed original under control instead of freezing a stale path list.
            source->continuation=[p,next=size_t(1)](uint64_t)mutable->std::unique_ptr<pt::Decoder> {
                std::string path;
                {std::lock_guard lock(p->control);if(next<p->trackPaths.size())path=p->trackPaths[next++];}
                return path.empty()?nullptr:pt::Decoder::open(path);
            };
            auto dsp=std::make_unique<PlaybackDSP>(p->rate,p->original.channels,applied);
            std::vector<double> input(blockSize*p->original.channels),output(input.size());uint64_t frame=0;
            for(;;) {
                if(p->stop.load()||revision!=p->latestRevision.load())return;
                const uint64_t target=p->processedFrame.load(std::memory_order_acquire);
                if(target==frame)break;
                const size_t wanted=size_t(std::min<uint64_t>(blockSize,target-frame));
                const size_t got=source->read(input.data(),wanted);
                if(got!=wanted||!dsp->process(input.data(),output.data(),got))throw std::runtime_error("Cannot reconstruct verified EQ state");
                frame+=got;
            }
            std::lock_guard lock(p->control);
            if(revision==p->latestRevision.load())p->verified=std::make_unique<PTPlayer::Verified>(PTPlayer::Verified{std::move(dsp),frame,revision});
        }catch(const std::exception &e){if(!p->stop.load()&&revision==p->latestRevision.load())p->fail(e);}
    });
    return revision;
}
extern "C" int pt_player_seek(PTPlayer *p,double sec) {
    if(!p||!std::isfinite(sec)||sec<0)return 0;
    bool paused=p->paused.exchange(true);
    while(p->rendering.load())std::this_thread::yield();
    p->stop=true;p->latestRevision++;if(p->worker.joinable())p->worker.join();if(p->verificationWorker.joinable())p->verificationWorker.join();
    try {
        const auto audible=p->track.load();
        auto applied=p->requested;applied.preampDB=p->requestedGain;
        auto restored=std::make_unique<PlaybackDSP>(p->rate,p->original.channels,applied);
        p->verified.reset();p->pendingEQ=false;
        if(audible<p->trackPaths.size()&&!p->trackPaths[size_t(audible)].empty()) {
            p->trackPaths.resize(size_t(audible)+1);p->trackInputStarts.resize(size_t(audible)+1);
            const uint64_t target=uint64_t(std::llround((double(p->trackInputStarts[size_t(audible)])/p->original.sampleRate+sec)*p->rate));
            const uint64_t start=uint64_t(std::llround(double(p->trackInputStarts[size_t(audible)])*p->rate/p->original.sampleRate));
            p->reader=p->replay(p->trackPaths);
            std::vector<double> input(blockSize*p->original.channels),output(input.size());uint64_t frame=0;
            while(frame<target) {
                const size_t wanted=size_t(std::min<uint64_t>(blockSize,target-frame)),got=p->reader->read(input.data(),wanted);
                if(got!=wanted||!restored->process(input.data(),output.data(),got))throw std::runtime_error("Cannot reconstruct seek history");
                frame+=got;
            }
            p->stateBaseFrame=target;p->seekBase=double(target-start)/p->rate;
        }else {
            if(applied.enabled)throw std::runtime_error("Streaming seek with EQ requires complete original");
            p->reader->seek(sec);p->seekBase=sec;p->stateBaseFrame=uint64_t(sec*p->rate);
        }
        p->produced=0;p->position=p->seekBase;p->current=std::move(restored);
        p->current->setBypass(p->requestedBypass,p->preserveBypassGain,true);
        p->decodedTrack=p->producingTrack=audible;p->boundaries.clear();p->boundaryCursor=0;p->outputTrackStart=0;p->nextTrack.reset();
        p->ring.head=0;p->ring.tail=0;p->previous.reset();p->transition=0;p->fault=0;p->errorText.clear();p->historyFrames=p->historyCursor=0;
        p->producingModeRevision=p->settledModeRevision=p->requestedModeRevision;
        p->producingRevision=p->requestedRevision;
        p->processedFrame=p->stateBaseFrame;
        p->start();p->paused=paused;return 1;
    }catch(const std::exception&e){pt_set_error(e.what());p->fail(e);return 0;}
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
    while(done<n&&p->ring.pop(f)){out[done*2]=f.l;out[done*2+1]=f.r;p->position=f.position;p->track=f.track;p->audibleRevision=f.revision;p->audibleModeRevision=f.modeRevision;done++;}
    if(done<n){std::fill(out+done*2,out+n*2,0.f);if(!p->finished)p->underruns++;}
    p->rendering.fetch_sub(1);return done;
}
extern "C" double pt_player_position(PTPlayer*p){return p?p->position.load():0;}
extern "C" uint64_t pt_player_track_index(PTPlayer*p){return p?p->track.load():0;}
extern "C" int pt_player_state(PTPlayer*p){if(!p)return -1;if(p->fault)return -1;if(p->finished&&p->ring.room()==capacity)return 2;return p->ring.room()<capacity?1:0;}
extern "C" uint64_t pt_player_underruns(PTPlayer*p){return p?p->underruns.load():0;}
extern "C" uint64_t pt_player_eq_revision(PTPlayer*p){return p?p->audibleRevision.load():0;}
