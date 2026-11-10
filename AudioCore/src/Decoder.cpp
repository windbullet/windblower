#include "Decoder.hpp"
#include <FLAC/stream_decoder.h>
#include <mpg123.h>
#include <soxr.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <stdexcept>
namespace pt {
class FLACDecoder final:public Decoder {
    FLAC__StreamDecoder *handle{};
    std::vector<double> pending;
    size_t cursor{};
    std::string error;
    PTByteSource source{};
    uint64_t bytePosition{};
    bool finished{},verifyMD5{};
    std::string filePath;
    static FLAC__StreamDecoderReadStatus sourceRead(const FLAC__StreamDecoder*,FLAC__byte *buffer,size_t *bytes,void *context) {
        auto &s=*static_cast<FLACDecoder*>(context);
        auto n=s.source.read(s.source.context,s.bytePosition,buffer,*bytes);
        if(n<0)return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
        *bytes=size_t(n);s.bytePosition+=uint64_t(n);
        return n?FLAC__STREAM_DECODER_READ_STATUS_CONTINUE:FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }
    static FLAC__StreamDecoderSeekStatus sourceSeek(const FLAC__StreamDecoder*,FLAC__uint64 offset,void *context){auto&s=*static_cast<FLACDecoder*>(context);if(offset>s.source.length)return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;s.bytePosition=offset;return FLAC__STREAM_DECODER_SEEK_STATUS_OK;}
    static FLAC__StreamDecoderTellStatus sourceTell(const FLAC__StreamDecoder*,FLAC__uint64 *offset,void *context){*offset=static_cast<FLACDecoder*>(context)->bytePosition;return FLAC__STREAM_DECODER_TELL_STATUS_OK;}
    static FLAC__StreamDecoderLengthStatus sourceLength(const FLAC__StreamDecoder*,FLAC__uint64 *length,void *context){*length=static_cast<FLACDecoder*>(context)->source.length;return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;}
    static FLAC__bool sourceEOF(const FLAC__StreamDecoder*,void *context){auto&s=*static_cast<FLACDecoder*>(context);return s.bytePosition>=s.source.length;}
    static FLAC__StreamDecoderWriteStatus write(const FLAC__StreamDecoder*,const FLAC__Frame *f,const FLAC__int32 *const buf[],void *p) {
        auto &s=*static_cast<FLACDecoder*>(p);
        const auto ch=f->header.channels;
        if(ch>2){s.error="Only mono/stereo FLAC is supported";return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;}
        s.pending.resize(size_t(f->header.blocksize)*ch);s.cursor=0;
        const double scale=std::ldexp(1.,1-int(f->header.bits_per_sample));
        for(size_t n=0;n<f->header.blocksize;n++) for(size_t c=0;c<ch;c++)s.pending[n*ch+c]=buf[c][n]*scale;
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }
    static void metadata(const FLAC__StreamDecoder*,const FLAC__StreamMetadata *m,void *p) {
        if(m->type!=FLAC__METADATA_TYPE_STREAMINFO)return;
        auto &s=*static_cast<FLACDecoder*>(p);const auto &i=m->data.stream_info;
        s.info={double(i.sample_rate),i.sample_rate?double(i.total_samples)/i.sample_rate:0,int32_t(i.channels),int32_t(i.bits_per_sample),i.total_samples};
    }
    static void failure(const FLAC__StreamDecoder*,FLAC__StreamDecoderErrorStatus e,void *p){static_cast<FLACDecoder*>(p)->error=FLAC__StreamDecoderErrorStatusString[e];}
public:
    explicit FLACDecoder(PTByteSource input):source(input) {
        handle=FLAC__stream_decoder_new();if(!handle)throw std::bad_alloc();
        if(FLAC__stream_decoder_init_stream(handle,sourceRead,sourceSeek,sourceTell,sourceLength,sourceEOF,write,metadata,failure,this)!=FLAC__STREAM_DECODER_INIT_STATUS_OK||
           !FLAC__stream_decoder_process_until_end_of_metadata(handle)||info.channels<1||info.channels>2) {
            FLAC__stream_decoder_delete(handle);handle=nullptr;throw std::runtime_error("Unable to open FLAC byte source");
        }
    }
    explicit FLACDecoder(const std::string &path):filePath(path) {
        handle=FLAC__stream_decoder_new();if(!handle)throw std::bad_alloc();
        FLAC__stream_decoder_set_md5_checking(handle,true);
        verifyMD5=true;
        if(FLAC__stream_decoder_init_file(handle,path.c_str(),write,metadata,failure,this)!=FLAC__STREAM_DECODER_INIT_STATUS_OK||
           !FLAC__stream_decoder_process_until_end_of_metadata(handle)||info.channels<1||info.channels>2) {
            FLAC__stream_decoder_delete(handle);handle=nullptr;throw std::runtime_error("Unable to open mono/stereo FLAC");
        }
    }
    ~FLACDecoder() override {if(handle){if(!finished)FLAC__stream_decoder_finish(handle);FLAC__stream_decoder_delete(handle);}}
    size_t read(double *out,size_t frames) override {
        size_t done=0;
        while(done<frames) {
            if(finished)break;
            if(!error.empty())throw std::runtime_error(error);
            if(cursor<pending.size()) {
                size_t n=std::min((pending.size()-cursor)/info.channels,frames-done);
                std::copy_n(pending.data()+cursor,n*info.channels,out+done*info.channels);
                done+=n;cursor+=n*info.channels;
            } else {
                if(FLAC__stream_decoder_get_state(handle)==FLAC__STREAM_DECODER_END_OF_STREAM){
                    const bool valid=FLAC__stream_decoder_finish(handle);finished=true;
                    if(verifyMD5&&!valid)throw std::runtime_error("FLAC STREAMINFO MD5 verification failed");
                    break;
                }
                pending.clear();cursor=0;
                if(!FLAC__stream_decoder_process_single(handle))throw std::runtime_error("FLAC decode failure");
            }
        }
        return done;
    }
    void seek(uint64_t f) override {
        if(finished){
            bytePosition=0;finished=false;
            const auto status=source.read
                ? FLAC__stream_decoder_init_stream(handle,sourceRead,sourceSeek,sourceTell,sourceLength,sourceEOF,write,metadata,failure,this)
                : FLAC__stream_decoder_init_file(handle,filePath.c_str(),write,metadata,failure,this);
            if(status!=FLAC__STREAM_DECODER_INIT_STATUS_OK||!FLAC__stream_decoder_process_until_end_of_metadata(handle))throw std::runtime_error("FLAC reopen failed");
        }
        pending.clear();cursor=0;error.clear();
        if(!FLAC__stream_decoder_seek_absolute(handle,f))throw std::runtime_error("FLAC seek failed");
    }
};
class MP3Decoder final:public Decoder {
    mpg123_handle *handle{};
    int encoding{};
    std::vector<float> scratch;
    PTByteSource source{};
    uint64_t bytePosition{};
    static mpg123_ssize_t sourceRead(void *context,void *buffer,size_t bytes){auto&s=*static_cast<MP3Decoder*>(context);auto n=s.source.read(s.source.context,s.bytePosition,buffer,bytes);if(n>0)s.bytePosition+=uint64_t(n);return mpg123_ssize_t(n);}
    static off_t sourceSeek(void *context,off_t offset,int whence){auto&s=*static_cast<MP3Decoder*>(context);int64_t next=offset+(whence==SEEK_CUR?int64_t(s.bytePosition):(whence==SEEK_END?int64_t(s.source.length):0));if(next<0||uint64_t(next)>s.source.length)return -1;s.bytePosition=uint64_t(next);return off_t(next);}
public:
    explicit MP3Decoder(const std::string &path,PTByteSource input={},bool indexWholeFile=false):source(input) {
        static std::once_flag init;std::call_once(init,[]{if(mpg123_init()!=MPG123_OK)throw std::runtime_error("mpg123 init failed");});
        int error=0;handle=mpg123_new(nullptr,&error);if(!handle)throw std::runtime_error("mpg123 allocation failed");
        try {
            mpg123_param(handle,MPG123_ADD_FLAGS,MPG123_GAPLESS|MPG123_FORCE_FLOAT,0);
            mpg123_param(handle,MPG123_RVA,MPG123_RVA_OFF,0);
            mpg123_param(handle,MPG123_OUTSCALE,0,1.0);
            mpg123_param(handle,MPG123_DOWN_SAMPLE,0,0);
            mpg123_param(handle,MPG123_FORCE_RATE,0,0);
            mpg123_format_none(handle);
            const long *rates=nullptr;size_t n=0;mpg123_rates(&rates,&n);
            for(size_t i=0;i<n;i++)mpg123_format(handle,rates[i],MPG123_MONO|MPG123_STEREO,MPG123_ENC_FLOAT_32|MPG123_ENC_FLOAT_64);
            if(source.read) {
                mpg123_replace_reader_handle(handle,sourceRead,sourceSeek,nullptr);
                if(mpg123_open_handle(handle,this)!=MPG123_OK)throw std::runtime_error("Cannot open MP3 byte source");
            } else if(mpg123_open(handle,path.c_str())!=MPG123_OK)throw std::runtime_error("Cannot open MP3");
            long rate=0;int ch=0;
            if(mpg123_getformat(handle,&rate,&ch,&encoding)!=MPG123_OK||ch<1||ch>2)throw std::runtime_error("Unsupported MP3 format");
            if(encoding!=MPG123_ENC_FLOAT_32&&encoding!=MPG123_ENC_FLOAT_64)throw std::runtime_error("MP3 decoder did not return float PCM");
            // Xing/LAME metadata supplies gapless length where available. Do not scan the
            // entire local MP3 before its first sample; indexing can grow during reads/seeks.
            if(indexWholeFile&&!source.read&&mpg123_scan(handle)!=MPG123_OK)throw std::runtime_error("Invalid MP3 frame stream");
            auto frames=mpg123_length(handle);info={double(rate),frames>0?double(frames)/rate:0,ch,0,frames>0?uint64_t(frames):0};
            scratch.resize(8192*2);
        } catch(...){mpg123_delete(handle);handle=nullptr;throw;}
    }
    ~MP3Decoder() override {if(handle){mpg123_close(handle);mpg123_delete(handle);}}
    size_t read(double *out,size_t frames) override {
        size_t n=0;int status;
        if(encoding==MPG123_ENC_FLOAT_64) {
            status=mpg123_read(handle,reinterpret_cast<unsigned char*>(out),frames*info.channels*sizeof(double),&n);
            n/=sizeof(double)*info.channels;
        } else {
            frames=std::min(frames,scratch.size()/info.channels);
            status=mpg123_read(handle,reinterpret_cast<unsigned char*>(scratch.data()),frames*info.channels*sizeof(float),&n);
            n/=sizeof(float)*info.channels;
            for(size_t i=0;i<n*info.channels;i++)out[i]=scratch[i];
        }
        if(status!=MPG123_OK&&status!=MPG123_DONE&&status!=MPG123_NEW_FORMAT)throw std::runtime_error(mpg123_strerror(handle));
        if(status==MPG123_NEW_FORMAT)throw std::runtime_error("MP3 sample format changes mid-file");
        return n;
    }
    void seek(uint64_t f) override {if(mpg123_seek(handle,off_t(f),SEEK_SET)<0)throw std::runtime_error("MP3 seek failed");}
};
std::unique_ptr<Decoder> Decoder::open(const std::string &p,bool indexWholeFile) {
    auto ext=std::filesystem::path(reinterpret_cast<const char8_t*>(p.c_str())).extension().string();
    std::transform(ext.begin(),ext.end(),ext.begin(),[](unsigned char c){return char(std::tolower(c));});
    if(ext==".flac")return std::make_unique<FLACDecoder>(p);
    if(ext==".mp3")return std::make_unique<MP3Decoder>(p,PTByteSource{},indexWholeFile);
    throw std::runtime_error("Supported audio formats: FLAC, MP3");
}
std::unique_ptr<Decoder> Decoder::open(PTByteSource source,const std::string &extension) {
    if(!source.read||source.length==0)throw std::runtime_error("Invalid byte source");
    if(extension=="flac")return std::make_unique<FLACDecoder>(source);
    if(extension=="mp3")return std::make_unique<MP3Decoder>("",source);
    throw std::runtime_error("Unsupported stream format");
}
class PrefetchedDecoder final:public Decoder {
    std::unique_ptr<Decoder> decoder;
    std::vector<double> prefix;
    size_t cursor{};
public:
    PrefetchedDecoder(const std::string &path,size_t frames):decoder(Decoder::open(path)),prefix(frames*decoder->info.channels) {
        info=decoder->info;
        prefix.resize(decoder->read(prefix.data(),frames)*info.channels);
    }
    size_t read(double *output,size_t frames) override {
        const size_t ready=std::min(frames,(prefix.size()-cursor)/info.channels);
        std::copy_n(prefix.data()+cursor,ready*info.channels,output);cursor+=ready*info.channels;
        return ready==frames?ready:ready+decoder->read(output+ready*info.channels,frames-ready);
    }
    void seek(uint64_t frame) override {prefix.clear();cursor=0;decoder->seek(frame);}
};
std::unique_ptr<Decoder> Decoder::prepare(const std::string &path,size_t frames) {return std::make_unique<PrefetchedDecoder>(path,frames);}
Reader::Reader(const std::string &path,double fs):decoder(Decoder::open(path)),rate(fs),input(8192*decoder->info.channels) {configure();}
Reader::Reader(PTByteSource source,const std::string &ext,double fs):decoder(Decoder::open(source,ext)),rate(fs),input(8192*decoder->info.channels) {configure();}
void Reader::configure() {
    if(rate==decoder->info.sampleRate)return;
    auto io=soxr_io_spec(SOXR_FLOAT64_I,SOXR_FLOAT64_I);
    auto q=soxr_quality_spec(SOXR_VHQ,SOXR_DOUBLE_PRECISION|SOXR_HI_PREC_CLOCK);q.phase_response=50;
    auto rt=soxr_runtime_spec(1);soxr_error_t error{};
    resampler=soxr_create(decoder->info.sampleRate,rate,unsigned(decoder->info.channels),&error,&io,&q,&rt);
    if(error||!resampler)throw std::runtime_error(error?error:"SRC allocation failed");
}
Reader::~Reader(){if(resampler)soxr_delete(static_cast<soxr_t>(resampler));}
size_t Reader::readSource(double *out,size_t frames) {
    size_t done=0;
    while(done<frames) {
        const size_t n=decoder->read(out+done*decoder->info.channels,frames-done);
        done+=n;trackInputFrames+=n;
        if(n)continue;
        auto next=continuation?continuation(trackInputFrames):nullptr;
        if(!next)break;
        if(next->info.sampleRate!=decoder->info.sampleRate||next->info.channels!=decoder->info.channels)
            throw std::runtime_error("A continuous source must keep its native sample rate and channel count");
        decoder=std::move(next);trackInputFrames=0;
    }
    return done;
}
size_t Reader::read(double *out,size_t frames) {
    if(!resampler)return readSource(out,frames);
    size_t done=0;const auto ch=decoder->info.channels;
    while(done<frames) {
        if(used==available&&!eof){available=readSource(input.data(),input.size()/ch);used=0;eof=available==0;}
        size_t id=0,od=0;
        auto error=soxr_process(static_cast<soxr_t>(resampler),eof?nullptr:input.data()+used*ch,available-used,&id,out+done*ch,frames-done,&od);
        if(error)throw std::runtime_error(error);
        used+=id;done+=od;
        if(eof&&od==0)break;
    }
    return done;
}
void Reader::seek(double sec){decoder->seek(uint64_t(sec*decoder->info.sampleRate));trackInputFrames=uint64_t(sec*decoder->info.sampleRate);used=available=0;eof=false;if(resampler)soxr_clear(static_cast<soxr_t>(resampler));}
}
struct PTDecoder {std::unique_ptr<pt::Decoder> value;};
extern "C" PTDecoder *pt_decoder_open(const char *path){try{return new PTDecoder{pt::Decoder::open(path)};}catch(const std::exception&e){pt_set_error(e.what());return nullptr;}}
extern "C" PTDecoder *pt_decoder_open_indexed(const char *path){try{return new PTDecoder{pt::Decoder::open(path,true)};}catch(const std::exception&e){pt_set_error(e.what());return nullptr;}}
extern "C" void pt_decoder_close(PTDecoder *d){delete d;}
extern "C" PTFileInfo pt_decoder_info(PTDecoder *d){return d?d->value->info:PTFileInfo{};}
extern "C" int pt_source_info(PTByteSource source,const char *extension,PTFileInfo *info){try{auto d=pt::Decoder::open(source,extension);*info=d->info;return 1;}catch(const std::exception&e){pt_set_error(e.what());return 0;}}
extern "C" int64_t pt_decoder_read(PTDecoder *d,double *out,size_t n){try{return int64_t(d->value->read(out,n));}catch(const std::exception&e){pt_set_error(e.what());return -1;}}
extern "C" int pt_decoder_seek(PTDecoder*d,uint64_t f){try{d->value->seek(f);return 1;}catch(const std::exception&e){pt_set_error(e.what());return 0;}}
