#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/file.h>
#include <pwd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <CommonCrypto/CommonDigest.h>
#include "EngineHash.h"
static int resourceFD=-1;
static uid_t callerUID=0;
static uint64_t partitionOffset=0;
static uint16_t volumeFlags=0;
static void** ioVtableOverride=nullptr;
#include <unistd.h>
static bool streaming=false;
static int cachedFD=-1;
static NSNumber*cachedRegistry=nil;
static void releaseCached(){if(cachedFD>=0)close(cachedFD);cachedFD=-1;cachedRegistry=nil;}
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <stdexcept>
#include <initializer_list>
#include <algorithm>
using Status=uint32_t;
static void check(Status s,const char *what){if(s){char b[200];snprintf(b,sizeof b,"%s: UFSD 0x%08x",what,s);throw std::runtime_error(b);}}
static uint64_t u64(const uint8_t*p){uint64_t v;memcpy(&v,p,8);return v;}
static uint32_t u32(const uint8_t*p){uint32_t v;memcpy(&v,p,4);return v;}
static uint16_t u16(const uint8_t*p){uint16_t v;memcpy(&v,p,2);return v;}
// Progress lines and cooperative cancellation for long transfers (serve mode only).
// The app sends SIGUSR1 to request cancellation; the flag is reset for each request.
static volatile sig_atomic_t cancelRequested=0;
static bool progressEnabled=false;
static void onCancelSignal(int){cancelRequested=1;}
static void throwIfCancelled(){if(cancelRequested)throw std::runtime_error("Operation cancelled");}
static void json(id object);
// Batches report bytes across all their files; progressItem is the operation being processed.
static uint64_t progressBase=0;
static long progressItem=-1;
static void reportProgress(uint64_t bytes,bool force){
 if(!progressEnabled)return;
 static uint64_t last=0;struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
 uint64_t ms=(uint64_t)now.tv_sec*1000+now.tv_nsec/1000000;
 if(!force&&ms-last<80)return;last=ms;
 if(progressItem>=0)json(@{@"progress":@(progressBase+bytes),@"item":@(progressItem)});else json(@{@"progress":@(progressBase+bytes)});
}
// The engine's device Flush only calls fsync(), which on macOS does not empty the drive's own
// write cache. A durable barrier needs DKIOCSYNCHRONIZECACHE on devices / F_FULLFSYNC on images,
// otherwise data acknowledged as written can still be lost when the drive is unplugged.
static void syncDevice(int fd){
 struct stat st{};if(fstat(fd,&st))throw std::runtime_error("Cannot synchronize NTFS writes");
 if(S_ISBLK(st.st_mode)||S_ISCHR(st.st_mode)){
  if(fsync(fd))throw std::runtime_error("Cannot synchronize NTFS writes");
  if(ioctl(fd,DKIOCSYNCHRONIZECACHE)==0)return;
  if(errno==ENOTTY||errno==ENOTSUP||errno==EINVAL||errno==ENODEV)return; // drive without a flushable cache
  throw std::runtime_error("Cannot flush the drive's write cache");
 }
 if(fcntl(fd,F_FULLFSYNC)==0)return;
 if(fsync(fd))throw std::runtime_error("Cannot synchronize NTFS writes");
}

// ---- Windows-compatible security descriptors -------------------------------------------
// Without explicit security the engine stamps new objects with a built-in template
// (owner Everyone, group of a foreign domain, protected DACL) or reuses the parent folder's
// descriptor verbatim. Windows never produces such objects. New files and folders instead get
// the descriptor Windows itself would compute: ACEs inherited from the parent folder.
namespace sec{
 enum:uint8_t{OI=1,CI=2,NP=4,IO=8,INH=0x10};
 struct Ace{uint8_t type=0,flags=0;uint32_t mask=0;std::vector<uint8_t>sid,raw;};
 struct Descriptor{std::vector<uint8_t>owner,group;bool daclPresent=false;std::vector<Ace>dacl;};
 static std::vector<uint8_t> sid(uint8_t authority,std::initializer_list<uint32_t>subs){
  std::vector<uint8_t>s{1,(uint8_t)subs.size(),0,0,0,0,0,authority};
  for(uint32_t v:subs)for(int i=0;i<4;i++)s.push_back((uint8_t)(v>>(8*i)));
  return s;
 }
 static const std::vector<uint8_t>everyone=sid(1,{0}),creatorOwner=sid(3,{0}),creatorGroup=sid(3,{1}),
  systemSid=sid(5,{18}),admins=sid(5,{32,544}),users=sid(5,{32,545}),authenticated=sid(5,{11}),
  // Group SID embedded in the engine's built-in file template; it belongs to no real machine.
  foreignGroup=sid(5,{21,1987932187u,4155540637u,3944497785u,513});
 static size_t sidLength(const std::vector<uint8_t>&b,size_t o){
  if(o+8>b.size()||b[o]!=1||b[o+1]>15)throw std::runtime_error("Invalid security identifier");
  size_t n=8+4*(size_t)b[o+1];if(o+n>b.size())throw std::runtime_error("Invalid security identifier");return n;
 }
 static Descriptor parse(const std::vector<uint8_t>&b){
  if(b.size()<20||b[0]!=1)throw std::runtime_error("Invalid security descriptor");
  uint16_t control=u16(b.data()+2);if(!(control&0x8000))throw std::runtime_error("Security descriptor is not self-relative");
  Descriptor d;uint32_t oo=u32(b.data()+4),og=u32(b.data()+8),od=u32(b.data()+16);
  if(oo){size_t n=sidLength(b,oo);d.owner.assign(b.begin()+oo,b.begin()+oo+n);}
  if(og){size_t n=sidLength(b,og);d.group.assign(b.begin()+og,b.begin()+og+n);}
  if((control&4)&&od){
   if(od+8>b.size())throw std::runtime_error("Invalid DACL");
   uint16_t size=u16(b.data()+od+2),count=u16(b.data()+od+4);if(od+size>b.size()||size<8)throw std::runtime_error("Invalid DACL");
   d.daclPresent=true;size_t p=od+8;
   for(unsigned i=0;i<count;i++){
    if(p+4>od+size)throw std::runtime_error("Invalid ACE");
    Ace a;a.type=b[p];a.flags=b[p+1];uint16_t aceSize=u16(b.data()+p+2);
    if(aceSize<4||p+aceSize>od+size)throw std::runtime_error("Invalid ACE");
    if(a.type<=3&&aceSize>=16){a.mask=u32(b.data()+p+4);size_t n=sidLength(b,p+8);if(8+n>aceSize)throw std::runtime_error("Invalid ACE");a.sid.assign(b.begin()+p+8,b.begin()+p+8+n);}
    else a.raw.assign(b.begin()+p+4,b.begin()+p+aceSize);
    d.dacl.push_back(a);p+=aceSize;
   }
  }
  return d;
 }
 static void put16(std::vector<uint8_t>&b,size_t o,uint16_t v){memcpy(b.data()+o,&v,2);}
 static void put32(std::vector<uint8_t>&b,size_t o,uint32_t v){memcpy(b.data()+o,&v,4);}
 static std::vector<uint8_t> build(const Descriptor&d,uint16_t control){
  std::vector<uint8_t>acl(8);uint8_t revision=2;
  for(const Ace&a:d.dacl){
   std::vector<uint8_t>body;
   if(!a.sid.empty()){body.resize(4);memcpy(body.data(),&a.mask,4);body.insert(body.end(),a.sid.begin(),a.sid.end());}
   else{body=a.raw;if(a.type>=5&&a.type<=8)revision=4;}
   while(body.size()%4)body.push_back(0);
   size_t at=acl.size();acl.resize(at+4);acl[at]=a.type;acl[at+1]=a.flags;put16(acl,at+2,(uint16_t)(4+body.size()));
   acl.insert(acl.end(),body.begin(),body.end());
  }
  acl[0]=revision;put16(acl,2,(uint16_t)acl.size());put16(acl,4,(uint16_t)d.dacl.size());
  std::vector<uint8_t>out(20);out[0]=1;put16(out,2,control|0x8000|4);
  put32(out,16,(uint32_t)out.size());out.insert(out.end(),acl.begin(),acl.end());
  put32(out,4,(uint32_t)out.size());out.insert(out.end(),d.owner.begin(),d.owner.end());
  put32(out,8,(uint32_t)out.size());out.insert(out.end(),d.group.begin(),d.group.end());
  return out;
 }
 static uint32_t mapGeneric(uint32_t m){
  uint32_t r=m&0x0fffffffu;
  if(m&0x80000000u)r|=0x120089;if(m&0x40000000u)r|=0x120116;if(m&0x20000000u)r|=0x1200a0;if(m&0x10000000u)r|=0x1f01ff;
  return r;
 }
 static bool usable(const std::vector<uint8_t>&s){return !s.empty()&&s!=everyone&&s!=foreignGroup&&s!=creatorOwner&&s!=creatorGroup;}
 // Mirrors Windows ACL inheritance for a new child object (files: OI ACEs; folders: OI/CI,
 // NP, IO, CREATOR OWNER/GROUP substitution and generic-right mapping).
 static std::vector<uint8_t> inherit(const std::vector<uint8_t>&parentBytes,bool directory){
  Descriptor parent;bool parsed=false;
  try{parent=parse(parentBytes);parsed=true;}catch(...){}
  Descriptor child;child.owner=parsed&&usable(parent.owner)?parent.owner:admins;child.group=parsed&&usable(parent.group)?parent.group:admins;child.daclPresent=true;
  auto subst=[&](const std::vector<uint8_t>&s){return s==creatorOwner?child.owner:s==creatorGroup?child.group:s;};
  if(parsed&&parent.daclPresent)for(const Ace&a:parent.dacl){
   uint8_t f=a.flags;bool basic=!a.sid.empty();
   if(!directory){
    if(!(f&OI))continue;
    Ace c=a;c.flags=INH;if(basic){c.mask=mapGeneric(a.mask);c.sid=subst(a.sid);}child.dacl.push_back(c);continue;
   }
   if(!(f&(OI|CI)))continue;
   bool applies=f&CI,propagate=!(f&NP);
   if(applies){
    bool split=propagate&&basic&&(a.sid==creatorOwner||a.sid==creatorGroup||(a.mask&0xf0000000u));
    if(split||!propagate){Ace c=a;c.flags=INH;if(basic){c.mask=mapGeneric(a.mask);c.sid=subst(a.sid);}child.dacl.push_back(c);}
    if(propagate){Ace c=a;c.flags=(uint8_t)((f&(OI|CI))|INH|(split?IO:0));child.dacl.push_back(c);}
   }else if(propagate){Ace c=a;c.flags=OI|IO|INH;child.dacl.push_back(c);}
  }
  if(!child.dacl.empty())return build(child,0x0400);
  // Nothing inheritable: the defaults Windows uses for the root of removable NTFS media.
  uint8_t f=directory?(OI|CI):0;
  for(auto&p:std::initializer_list<std::pair<std::vector<uint8_t>,uint32_t>>{{admins,0x1f01ff},{systemSid,0x1f01ff},{authenticated,0x1301bf},{users,0x1200a9}}){Ace c;c.type=0;c.flags=f;c.mask=p.second;c.sid=p.first;child.dacl.push_back(c);}
  return build(child,0);
 }
 // True for descriptors the engine produced without explicit security: its built-in templates
 // or the parent's descriptor copied verbatim. Windows-made ACLs are never touched.
 static bool engineDefault(const std::vector<uint8_t>&current,uint32_t id,uint32_t parentId,const std::vector<std::vector<uint8_t>>&templates){
  for(auto&t:templates)if(t==current)return true;
  if(id>=0x100&&id==parentId)return true;
  try{Descriptor d=parse(current);if(d.owner==everyone&&d.group==foreignGroup)return true;}catch(...){}
  return false;
 }
}
static std::vector<uint16_t> utf(const char *s){NSString *v=[NSString stringWithUTF8String:s];if(!v)throw std::runtime_error("Invalid UTF-8");std::vector<uint16_t> out(v.length+1);[v getCharacters:out.data() range:NSMakeRange(0,v.length)];return out;}
class Engine{
 intptr_t slide=0;
 public:
 explicit Engine(const char *path){
  if(!dlopen(path,RTLD_NOW|RTLD_LOCAL))throw std::runtime_error(dlerror());
  bool found=false;
  for(uint32_t i=0;i<_dyld_image_count();i++)if(strstr(_dyld_get_image_name(i),"NTFSEngine.bundle")){slide=_dyld_get_image_vmaddr_slide(i);found=true;break;}
  if(!found)throw std::runtime_error("Engine image missing");
 }
 template<class T>T fn(uint64_t addr){return reinterpret_cast<T>(slide+addr);}
};
static void*ioFromAuthorizedDescriptor(Engine&e,bool readOnly,const char*name){
 struct stat st{};if(resourceFD<0||fstat(resourceFD,&st))throw std::runtime_error("Missing authorized file descriptor");
 uint32_t sector=512;uint64_t bytes=0;
 if(S_ISBLK(st.st_mode)){uint64_t blocks=0;if(ioctl(resourceFD,DKIOCGETBLOCKSIZE,&sector)||ioctl(resourceFD,DKIOCGETBLOCKCOUNT,&blocks)||!sector||blocks>INT64_MAX/sector)throw std::runtime_error("Cannot read USB geometry");bytes=blocks*sector;}
 else if(S_ISREG(st.st_mode))bytes=st.st_size;else throw std::runtime_error("Unsupported descriptor type");
 if(sector!=512&&sector!=4096)throw std::runtime_error("Only 512-byte and 4096-byte sectors are supported");
 int duplicate=dup(resourceFD);if(duplicate<0)throw std::runtime_error("Cannot duplicate authorized descriptor");
 // Verified CUFSD_RWBlock ABI for the pinned engine build. Reuse its IO routines,
 // supplying dup(fd) so no pathname is reopened and no second authorization is attempted.
 auto*memory=static_cast<uint8_t*>(::operator new(0x28));memset(memory,0,0x28);
 void*table=ioVtableOverride?static_cast<void*>(ioVtableOverride):e.fn<void*>(0x100068708);memcpy(memory,&table,8);memcpy(memory+8,&duplicate,4);
 memory[0xc]=readOnly;memory[0xd]=1;memory[0x10]=S_ISBLK(st.st_mode)?1:0;
 memcpy(memory+0x14,&sector,4);memcpy(memory+0x18,&bytes,8);char*label=strdup(name);memcpy(memory+0x20,&label,8);return memory;
}
class Session{
 Engine&e;alignas(16) uint8_t ctx[256]{};void*io=nullptr;bool started=false;unsigned long initializationFlags=0;
 public:
 explicit Session(Engine&engine):e(engine){for(int base:{0x40,0x50}){void*p=ctx+base;memcpy(ctx+base,&p,8);memcpy(ctx+base+8,&p,8);}}
 ~Session(){if(started)e.fn<void(*)(void*)>(0x100012d58)(ctx);if(io)e.fn<void(*)(void*)>(0x100008668)(io);}
 void open(const char *path,bool readOnly){
  struct stat st{};if(stat(path,&st)||(!S_ISREG(st.st_mode)&&!(resourceFD>=0&&S_ISBLK(st.st_mode))))throw std::runtime_error("Unsupported target type");
  e.fn<void*(*)()>(0x10000878c)();
  io=ioFromAuthorizedDescriptor(e,readOnly,path);
  void*sm=e.fn<void*(*)()>(0x100009644)();void*tm=e.fn<void*(*)()>(0x100007a80)();started=true;
  check(e.fn<Status(*)(void*,unsigned long,void*,void*,void*,void*,unsigned long*,unsigned long,unsigned long*)>(0x100013134)(ctx,2,io,sm,tm,nullptr,nullptr,readOnly?0x40000000UL:0,&initializationFlags),"initialize NTFS");
  // The 0x40000000 read-only initialisation (CFileSystemNtfs::ReInit) returns right after
  // LoadBitmap and never loads $UpCase. Without that table CompareNtfsNames falls back to a
  // binary comparison, so name lookups miss entries in folders mixing upper- and lower-case
  // names (the index is sorted case-insensitively). LoadUpcase (0x100042760) only reads $UpCase.
  if(readOnly){void*fs=nullptr;memcpy(&fs,ctx+0x38,8);void*upcase=nullptr;if(fs)memcpy(&upcase,static_cast<uint8_t*>(fs)+0x2c0,8);
   if(fs&&!upcase)check(e.fn<Status(*)(void*)>(0x100042760)(fs),"load upcase");}
 }
 void*ctxPtr(){return ctx;}
 unsigned volumeState(){unsigned state=0;check(e.fn<Status(*)(void*,unsigned*)>(0x100015694)(ctx,&state),"read volume state");return state;}
 bool journalRecoveryNeeded(){return (initializationFlags&0x10000000UL)!=0;}
 void requireWritableState(){
  if(volumeState()!=2)throw std::runtime_error("NTFS is marked dirty. Run a filesystem check before writing");
  // A non-empty journal observed by a read-only mount is not itself an error.
  // The original engine's writable Init replays it and returns an error if replay fails.
  // Verified first using a kernel-enforced read-only backing device and a RAM overlay.
  // Do not clear the dirty bit, reset the log, or bypass the engine initialization result.
 }
 NSArray*list(const char *path){
  std::string directory=path;if(directory.empty()||directory.back()!='/')directory+='/';
  auto p=utf(directory.c_str());void*h=nullptr;alignas(16)uint8_t info[1024]{};
  Status s=e.fn<Status(*)(void*,uint8_t,const void*,void*,void**,unsigned long)>(0x100015454)(ctx,2,p.data(),info,&h,0);
  NSMutableArray*entries=[NSMutableArray array];size_t limit=0;
  while(s==0){
   uint16_t n=u16(info+0x6a);if(n>255)throw std::runtime_error("Invalid filename length");
   NSString*name=[[NSString alloc]initWithCharacters:reinterpret_cast<const unichar*>(info+0x6e) length:n];
   if(name&&![name isEqualToString:@"."]&&![name isEqualToString:@".."]&&u64(info)>=16){
    [entries addObject:@{@"name":name,@"size":@(u64(info+0x30)),@"attributes":@(u32(info+0x48)),@"directory":@((u32(info+0x48)&0x10)!=0),@"fileID":@(u64(info)),@"modifiedNTFS":@(u64(info+0x18))}];
   }
   if(++limit>100000)throw std::runtime_error("Directory too large");
   memset(info,0,sizeof info);
   s=e.fn<Status(*)(void*,void*,void*)>(0x1000155fc)(ctx,h,info);
  }
  if(h)check(e.fn<Status(*)(void*,void**)>(0x100012e4c)(ctx,&h),"close search");
  if(s!=0xa000100e)check(s,"list directory");
  return entries;
 }
 // Name equality exactly as this volume sees it: CompareNtfsNames (0x10000f8d4) with the
 // volume's own $UpCase table, plus Unicode case folding as a conservative superset. A missed
 // collision would make the engine's Rename crash, so "maybe equal" is treated as equal.
 bool sameName(NSString*a,NSString*b){
  if([a caseInsensitiveCompare:b]==NSOrderedSame)return true;
  void*fs=nullptr;memcpy(&fs,ctx+0x38,8);void*upcase=nullptr;if(fs)memcpy(&upcase,static_cast<uint8_t*>(fs)+0x2c0,8);
  if(!upcase)return false;
  std::vector<unichar>x(a.length+1),y(b.length+1);[a getCharacters:x.data() range:NSMakeRange(0,a.length)];[b getCharacters:y.data() range:NSMakeRange(0,b.length)];
  return e.fn<int(*)(const uint16_t*,unsigned long,const uint16_t*,unsigned long,const void*)>(0x10000f8d4)(reinterpret_cast<const uint16_t*>(x.data()),a.length,reinterpret_cast<const uint16_t*>(y.data()),b.length,upcase)==0;
 }
 NSDictionary*entry(NSString*path){
  NSString*parent=[path stringByDeletingLastPathComponent];NSString*name=path.lastPathComponent;
  NSArray*items=list(parent.UTF8String);
  for(NSDictionary*item in items)if([item[@"name"] isEqualToString:name])return item;
  for(NSDictionary*item in items)if(sameName(item[@"name"],name))return item;
  return nil;
 }
 static void checkComponent(NSString*part,bool first){
  if(!part.length||part.length>255||[part isEqual:@"."]||[part isEqual:@".."]||[part hasSuffix:@"."]||[part hasSuffix:@" "]||[part rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\:*?\"<>|"]].location!=NSNotFound||[part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)throw std::runtime_error("Unsupported NTFS filename");
  if(first&&[part hasPrefix:@"$"])throw std::runtime_error("NTFS metadata is protected");
 }
 void verifyPath(NSString*path,bool mustExist,bool directory,bool absent=false){
  if(![path hasPrefix:@"/"]||path.length>2048)throw std::runtime_error("Invalid NTFS path");
  if([path isEqual:@"/"]){if(!directory||absent)throw std::runtime_error("The root directory is protected");return;}
  NSArray*parts=[[path substringFromIndex:1] componentsSeparatedByString:@"/"];NSString*current=@"";
  for(NSUInteger i=0;i<parts.count;i++){
   NSString*part=parts[i];BOOL last=i+1==parts.count;
   checkComponent(part,i==0);
   current=[current stringByAppendingFormat:@"/%@",part];NSDictionary*item=entry(current);
   if(item&&([item[@"attributes"] unsignedIntValue]&0x400))throw std::runtime_error("Reparse points are not supported");
   if(!last&&(!item||![item[@"directory"] boolValue]))throw std::runtime_error("Parent directory does not exist");
   if(last){
    if(absent&&item)throw std::runtime_error("A file or folder with this name already exists");
    if(mustExist&&(!item||[item[@"directory"] boolValue]!=directory))throw std::runtime_error(directory?"Directory does not exist":"File does not exist");
   }
  }
 }
 // CUFSD::FsIoControl (0x100015908) forwards to CFileSystemNtfs::IoControl. Codes 0x3f/0x41 are
 // OnGetSecurityDesc/OnSetSecurityDesc; input[0] is the CFSObject*, SetSecurity takes the length
 // at +0x14 and the self-relative descriptor at +0x18 (CFileMFTRecord::SetSecurity, $Secure dedup).
 using IoctlFn=Status(*)(void*,unsigned long,const void*,unsigned long,void*,unsigned long,unsigned long*);
 std::vector<uint8_t> security(void*object,uint32_t*id){
  alignas(16) uint8_t in[16]{};memcpy(in,&object,8);
  std::vector<uint8_t>out(65536+8);unsigned long returned=0;
  check(e.fn<IoctlFn>(0x100015908)(ctx,0x3f,in,sizeof in,out.data(),out.size(),&returned),"read security");
  uint32_t length=u32(out.data()+4);if(length<20||length>out.size()-8||returned<8+(unsigned long)length)throw std::runtime_error("Invalid security descriptor");
  if(id)*id=u32(out.data());
  return std::vector<uint8_t>(out.begin()+8,out.begin()+8+length);
 }
 void setSecurity(void*object,const std::vector<uint8_t>&descriptor){
  std::vector<uint8_t>in(0x18+descriptor.size());memcpy(in.data(),&object,8);uint32_t n=(uint32_t)descriptor.size();memcpy(in.data()+0x14,&n,4);memcpy(in.data()+0x18,descriptor.data(),n);
  unsigned long returned=0;check(e.fn<IoctlFn>(0x100015908)(ctx,0x41,in.data(),in.size(),nullptr,0,&returned),"write security");
 }
 // CUFSD::OpenDir (ParsePath on the whole path) / CUFSD::CloseDir.
 struct Dir{Session&s;void*p=nullptr;Dir(Session&session,NSString*path):s(session){auto u=utf(path.UTF8String);check(s.e.fn<Status(*)(void*,uint8_t,const void*,void**)>(0x100015640)(s.ctx,2,u.data(),&p),"open folder");if(!p)throw std::runtime_error("open folder");}~Dir(){if(p)s.e.fn<Status(*)(void*,void*)>(0x100012fa4)(s.ctx,p);}};
 std::vector<uint8_t> inheritedSecurity(NSString*childPath,bool directory){
  NSString*parent=[childPath stringByDeletingLastPathComponent];if(!parent.length)parent=@"/";
  Dir d(*this,parent);return sec::inherit(security(d.p,nullptr),directory);
 }
 std::vector<std::vector<uint8_t>> engineTemplates(){
  std::vector<std::vector<uint8_t>>out;
  for(unsigned long i=0;i<4;i++){unsigned long n=0;auto*p=e.fn<const uint8_t*(*)(unsigned long,unsigned long*)>(0x10003cab8)(i,&n);if(p&&n>=20&&n<=65536)out.emplace_back(p,p+n);}
  return out;
 }
 // Re-derives security for objects that still carry an engine default (see sec::engineDefault),
 // recursing into folders. Explicit Windows ACLs are left unchanged.
 void repairSecurity(NSString*path,const std::vector<std::vector<uint8_t>>&templates,unsigned&checked,unsigned&fixed){
  throwIfCancelled();if(++checked>50000)throw std::runtime_error("Too many objects");
  NSDictionary*item=entry(path);if(!item)throw std::runtime_error("File does not exist");
  if([item[@"attributes"] unsignedIntValue]&0x400)return;
  bool directory=[item[@"directory"] boolValue];
  NSString*parent=[path stringByDeletingLastPathComponent];if(!parent.length)parent=@"/";
  uint32_t parentId=0;std::vector<uint8_t>parentSD;{Dir d(*this,parent);parentSD=security(d.p,&parentId);}
  auto update=[&](void*object){uint32_t id=0;auto current=security(object,&id);
   if(!sec::engineDefault(current,id,parentId,templates))return;
   auto wanted=sec::inherit(parentSD,directory);if(wanted==current)return; // already what Windows would assign
   setSecurity(object,wanted);fixed++;};
  if(directory){{Dir d(*this,path);update(d.p);}
   for(NSDictionary*child in list(path.UTF8String))repairSecurity([path stringByAppendingPathComponent:child[@"name"]],templates,checked,fixed);
  }else{
   auto p=utf(path.UTF8String);void*h=nullptr;
   check(e.fn<Status(*)(void*,void**,uint8_t,const void*,unsigned long)>(0x10001351c)(ctx,&h,2,p.data(),0),"open NTFS file");
   try{void*object=nullptr;memcpy(&object,static_cast<uint8_t*>(h)+8,8);update(object);}catch(...){e.fn<Status(*)(void*,void*)>(0x100012ee0)(ctx,h);throw;}
   check(e.fn<Status(*)(void*,void*)>(0x100012ee0)(ctx,h),"close NTFS file");
  }
 }
 void mkdir(const char *path){
  auto p=utf(path);NSString*name=[NSString stringWithUTF8String:path];auto descriptor=inheritedSecurity(name,true);
  check(e.fn<Status(*)(void*,uint8_t,const void*,void**)>(0x100014610)(ctx,2,p.data(),nullptr),"mkdir");
  Dir d(*this,name);setSecurity(d.p,descriptor);
 }
 void rename(const char*a,const char*b){auto p=utf(a),q=utf(b);check(e.fn<Status(*)(void*,uint8_t,const void*,const void*)>(0x1000143c8)(ctx,2,p.data(),q.data()),"rename");}
 void remove(const char*path,bool directory){auto p=utf(path);check(e.fn<Status(*)(void*,uint8_t,const void*)>(directory?0x100014a50:0x100014250)(ctx,2,p.data()),"remove");}
 uint64_t transfer(const char *local,const char *remote,bool writing){
  uid_t previous=geteuid();if(previous==0&&callerUID>=501&&seteuid(callerUID))throw std::runtime_error("Cannot use caller permissions");
  int fd=::open(local,(writing?O_RDONLY:(O_WRONLY|O_CREAT|O_EXCL))|O_NOFOLLOW,0600);int savedErrno=errno;
  if(geteuid()!=previous&&seteuid(previous)){if(fd>=0)close(fd);throw std::runtime_error("Cannot restore worker permissions");}
  if(fd<0)throw std::runtime_error(strerror(savedErrno));
  struct stat localInfo{};if(fstat(fd,&localInfo)||!S_ISREG(localInfo.st_mode)){close(fd);throw std::runtime_error("Local transfer target must be a regular file");}
  struct Fd{int n;~Fd(){close(n);}}guard{fd};
  // An export creates its local file exclusively (O_EXCL), so a failed or cancelled export
  // removes only the partial file it created itself.
  try{
   std::vector<uint8_t>descriptor;if(writing)descriptor=inheritedSecurity([NSString stringWithUTF8String:remote],false);
   auto p=utf(remote);void*h=nullptr;
   check(e.fn<Status(*)(void*,void**,uint8_t,const void*,unsigned long)>(0x10001351c)(ctx,&h,2,p.data(),writing?4:0),"open NTFS file");
   std::vector<char>buffer(1024*1024);uint64_t total=0;
   try{
    if(writing){void*object=nullptr;memcpy(&object,static_cast<uint8_t*>(h)+8,8);setSecurity(object,descriptor);}
    reportProgress(0,true);
    while(true){
     throwIfCancelled();
     unsigned long done=0;
     if(writing){ssize_t got=read(fd,buffer.data(),buffer.size());if(got<0)throw std::runtime_error(strerror(errno));if(got==0)break;
      check(e.fn<Status(*)(void*,unsigned long*,const void*,unsigned long,void*)>(0x1000141b0)(ctx,&done,buffer.data(),got,h),"write NTFS file");if(done!=(unsigned long)got)throw std::runtime_error("Short NTFS write");
     }else{
      check(e.fn<Status(*)(void*,unsigned long*,void*,unsigned long,void*)>(0x100014110)(ctx,&done,buffer.data(),buffer.size(),h),"read NTFS file");if(!done)break;
      size_t offset=0;while(offset<done){ssize_t w=write(fd,buffer.data()+offset,done-offset);if(w<=0)throw std::runtime_error(strerror(errno));offset+=w;}
     }
     total+=done;reportProgress(total,false);
    }
    if(!writing&&fsync(fd))throw std::runtime_error(strerror(errno));
    reportProgress(total,true);
   }catch(...){e.fn<Status(*)(void*,void*)>(0x100012ee0)(ctx,h);throw;}
   check(e.fn<Status(*)(void*,void*)>(0x100012ee0)(ctx,h),"close NTFS file");return total;
  }catch(...){struct stat now{};if(!writing&&!lstat(local,&now)&&now.st_dev==localInfo.st_dev&&now.st_ino==localInfo.st_ino)unlink(local);throw;}
 }
 // Engine flush followed by a full device barrier (see syncDevice).
 void flush(){check(e.fn<Status(*)(void*)>(0x100014f38)(ctx),"flush NTFS");syncDevice(resourceFD);}
};

// ---- Operations shared by single requests and batches ---------------------------------------
static NSString*temporaryName(NSString*remote,NSString*prefix){
 NSString*parent=[remote stringByDeletingLastPathComponent];if(!parent.length)parent=@"/";
 return [parent stringByAppendingPathComponent:[prefix stringByAppendingString:NSUUID.UUID.UUIDString]];
}
static uint64_t opGet(Session&s,const char*local,NSString*remote){
 s.verifyPath(remote,true,false);
 NSDictionary*item=s.entry(remote);
 if([item[@"attributes"] unsignedIntValue]&0x4000)throw std::runtime_error("Encrypted (EFS) files can only be read on Windows");
 return s.transfer(local,remote.UTF8String,false);
}
static void opMkdir(Session&s,NSString*path){s.verifyPath(path,false,true,true);s.mkdir(path.UTF8String);}
static void opRemove(Session&s,NSString*path,bool directory){
 s.verifyPath(path,true,directory);
 if(directory&&s.list(path.UTF8String).count)throw std::runtime_error("Only empty folders can be deleted");
 s.remove(path.UTF8String,directory);
}
static void opRename(Session&s,NSString*a,NSString*b){
 NSDictionary*item=s.entry(a);s.verifyPath(a,true,[item[@"directory"] boolValue]);
 if([b hasPrefix:[a stringByAppendingString:@"/"]])throw std::runtime_error("Cannot move a folder into itself");
 bool sameFolder=[[a stringByDeletingLastPathComponent] isEqualToString:[b stringByDeletingLastPathComponent]];
 if(sameFolder&&s.sameName(a.lastPathComponent,b.lastPathComponent)){
  // Case-only rename: the engine's Rename crashes on a name collision, and the old name collides
  // with the new one, so go through a unique temporary name.
  if([a isEqualToString:b])return;
  Session::checkComponent(b.lastPathComponent,[[b stringByDeletingLastPathComponent] isEqualToString:@"/"]);
  NSString*temporary=temporaryName(a,@".openntfs-rename-");
  s.rename(a.UTF8String,temporary.UTF8String);s.flush();s.rename(temporary.UTF8String,b.UTF8String);return;
 }
 s.verifyPath(b,false,false,true);s.rename(a.UTF8String,b.UTF8String);
}
static uint64_t opPut(Session&s,const char*local,NSString*remote){
 s.verifyPath(remote,false,false,true);
 NSString*temporary=temporaryName(remote,@".openntfs-");
 try{uint64_t n=s.transfer(local,temporary.UTF8String,true);s.flush();s.rename(temporary.UTF8String,remote.UTF8String);return n;}
 catch(...){try{s.remove(temporary.UTF8String,false);s.flush();}catch(...){}throw;}
}
// The engine sets the dirty flag itself only when it detects an inconsistency on the volume
// (CFileSystemNtfs::MarkVolumeDirty; GetVolumeState then reports 1). Writing starts only on a clean
// volume, so a dirty state after an operation means the engine found a problem during it.
static bool engineMarkedDirty(Session&s){try{return s.volumeState()!=2;}catch(...){return false;}}
static void json(id object){NSData*d=[NSJSONSerialization dataWithJSONObject:object options:(streaming?0:NSJSONWritingPrettyPrinted) error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static int legacyMain(int argc,char**argv){@autoreleasepool{
 try{
  if(argc<3)throw std::runtime_error("usage: engine-cli ENGINE command [image] [arguments]");
  Engine e(argv[1]);std::string cmd=argv[2];
  if(cmd=="version"){json(@{@"version":[NSString stringWithUTF8String:e.fn<const char*(*)()>(0x100009924)()]});return 0;}
  if(argc<4)throw std::runtime_error("Missing image");
  if(cmd=="format"){
   struct stat st{};if(stat(argv[3],&st)||(!S_ISREG(st.st_mode)&&!(resourceFD>=0&&S_ISBLK(st.st_mode))))throw std::runtime_error("Unsupported format target");
   void*io=ioFromAuthorizedDescriptor(e,false,argv[3]);
   struct IoGuard{Engine&e;void*p;~IoGuard(){e.fn<void(*)(void*)>(0x100008668)(p);}}guard{e,io};
   void*mm=e.fn<void*(*)()>(0x10000878c)();void*sm=e.fn<void*(*)()>(0x100009644)();void*tm=e.fn<void*(*)()>(0x100007a80)();
   auto label=utf(argc>4?argv[4]:"OPENNTFS");alignas(16)uint8_t options[64]{};
   uint32_t sector=u32(static_cast<uint8_t*>(io)+0x14);uint32_t hidden=(uint32_t)(partitionOffset/sector);uint16_t sectors=63,heads=255;
   memcpy(options+0x20,&hidden,4);memcpy(options+0x24,&sectors,2);memcpy(options+0x26,&heads,2);options[0x28]=0xf8;
   using FormatFn=Status(*)(unsigned long,void*,void*,void*,void*,void*,void*,bool,uint16_t,unsigned,uint8_t,const void*,unsigned long,const void*,const char*);
   check(e.fn<FormatFn>(0x1000159c8)(2,mm,sm,io,tm,nullptr,nullptr,true,0,0,2,label.data(),label.size()-1,options,argv[3]),"format NTFS");
   syncDevice(resourceFD);json(@{@"ok":@YES});return 0;
  }
  bool mutating=cmd=="put"||cmd=="mkdir"||cmd=="rename"||cmd=="remove"||cmd=="rmdir"||cmd=="fixsec";
  if(mutating){Session probe(e);probe.open(argv[3],true);probe.requireWritableState();for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");}
  Session s(e);s.open(argv[3],!mutating);
  auto done=[&](NSDictionary*d){if(mutating&&engineMarkedDirty(s)){NSMutableDictionary*m=[d mutableCopy];m[@"volumeMarkedDirty"]=@YES;d=m;}json(d);};
  if(cmd=="health"){json(@{@"flags":@(volumeFlags),@"flagsHex":[NSString stringWithFormat:@"0x%04x",volumeFlags],@"engineState":@(s.volumeState()),@"journalRecoveryNeeded":@(s.journalRecoveryNeeded()),@"readOnlyCheck":@YES});}
  else if(cmd=="ls"){s.verifyPath([NSString stringWithUTF8String:argv[4]],true,true);json(@{@"entries":s.list(argv[4])});}
  else if(cmd=="put"||cmd=="get"){
   if(argc!=6)throw std::runtime_error("transfer requires local path and NTFS path");
   NSString*remote=[NSString stringWithUTF8String:argv[5]];uint64_t n=0;
   if(cmd=="put"){n=opPut(s,argv[4],remote);s.flush();}else n=opGet(s,argv[4],remote);
   done(@{@"ok":@YES,@"bytes":@(n)});
  }else if(cmd=="mkdir"&&argc==5){opMkdir(s,[NSString stringWithUTF8String:argv[4]]);s.flush();done(@{@"ok":@YES});}
  else if(cmd=="rename"&&argc==6){opRename(s,[NSString stringWithUTF8String:argv[4]],[NSString stringWithUTF8String:argv[5]]);s.flush();done(@{@"ok":@YES});}
  else if(cmd=="fixsec"&&argc==5){NSString*path=[NSString stringWithUTF8String:argv[4]];if([path isEqual:@"/"])throw std::runtime_error("The root directory is protected");NSDictionary*item=s.entry(path);s.verifyPath(path,true,[item[@"directory"] boolValue]);unsigned checked=0,fixed=0;auto templates=s.engineTemplates();try{s.repairSecurity(path,templates,checked,fixed);}catch(...){s.flush();throw;}s.flush();done(@{@"ok":@YES,@"checked":@(checked),@"fixed":@(fixed)});}
  else if((cmd=="remove"||cmd=="rmdir")&&argc==5){opRemove(s,[NSString stringWithUTF8String:argv[4]],cmd=="rmdir");s.flush();done(@{@"ok":@YES});}
  else throw std::runtime_error("Unknown command or arguments");
  return 0;
 }catch(const std::exception&e){json(@{@"error":[NSString stringWithUTF8String:e.what()]});return 1;}
}}
// ---- Batches: many operations in one mounted session ----------------------------------------
// Consecutive puts are group-committed: their data is written under unique temporary names,
// one durable barrier makes all of it reach the medium, the files are renamed into place and a
// second barrier makes the names durable. A file therefore never appears under its final name
// before its contents are safely stored; on error or cancellation uncommitted temporaries are
// removed. Other operations commit pending puts first, so the order of the batch is preserved.
static void requireWritableVolume(Engine&e,const char*image){
 Session probe(e);probe.open(image,true);probe.requireWritableState();
 for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");
}
static int runBatch(const char*enginePathC,const char*image,NSArray*operations,bool mutating){
 NSUInteger completed=0;uint64_t bytes=0;bool markedDirty=false;
 try{
  Engine e(enginePathC);
  if(mutating)requireWritableVolume(e,image);
  Session s(e);s.open(image,!mutating);
  struct Pending{NSString*temporary;NSString*remote;uint64_t size;};
  std::vector<Pending>pending;uint64_t pendingBytes=0;NSUInteger firstPending=0;
  auto rollback=[&]{for(auto&p:pending){try{s.remove(p.temporary.UTF8String,false);}catch(...){}}pending.clear();pendingBytes=0;try{s.flush();}catch(...){}};
  auto commit=[&](NSUInteger upTo){
   if(pending.empty()){completed=upTo;return;}
   s.flush();
   for(size_t i=0;i<pending.size();i++){
    s.rename(pending[i].temporary.UTF8String,pending[i].remote.UTF8String);
    pending[i].temporary=nil;
   }
   pending.clear();pendingBytes=0;s.flush();completed=upTo;
  };
  try{
   NSUInteger sinceFlush=0;
   for(NSUInteger i=0;i<operations.count;i++){
    throwIfCancelled();progressItem=(long)i;progressBase=bytes;
    NSDictionary*o=operations[i];NSString*op=o[@"op"];NSArray*a=o[@"args"];
    if(![op isEqual:@"put"]){commit(i);}
    if([op isEqual:@"put"]){
     NSString*remote=a[1];s.verifyPath(remote,false,false,true);
     for(auto&p:pending)if([[p.remote stringByDeletingLastPathComponent] caseInsensitiveCompare:[remote stringByDeletingLastPathComponent]]==NSOrderedSame&&s.sameName(p.remote.lastPathComponent,remote.lastPathComponent))throw std::runtime_error("A file or folder with this name already exists");
     if(pending.empty())firstPending=i;
     NSString*temporary=temporaryName(remote,@".openntfs-");
     pending.push_back({temporary,remote,0});
     uint64_t n=0;
     try{n=s.transfer([a[0] UTF8String],temporary.UTF8String,true);}
     catch(...){pending.back().temporary=nil;pending.pop_back();try{s.remove(temporary.UTF8String,false);}catch(...){}throw;}
     pending.back().size=n;pendingBytes+=n;bytes+=n;
     if(pending.size()>=64||pendingBytes>=256ull*1024*1024)commit(i+1);
    }else if([op isEqual:@"get"]){bytes+=opGet(s,[a[0] UTF8String],a[1]);completed=i+1;}
    else if([op isEqual:@"mkdir"]){opMkdir(s,a[0]);completed=i+1;sinceFlush++;}
    else if([op isEqual:@"remove"]||[op isEqual:@"rmdir"]){opRemove(s,a[0],[op isEqual:@"rmdir"]);completed=i+1;sinceFlush++;}
    else throw std::runtime_error("Invalid operation");
    if(mutating&&sinceFlush>=256){s.flush();sinceFlush=0;}
   }
   commit(operations.count);
   if(mutating)s.flush();
  }catch(...){
   (void)firstPending;
   rollback();
   if(mutating)markedDirty=engineMarkedDirty(s);
   throw;
  }
  if(mutating)markedDirty=engineMarkedDirty(s);
  progressItem=-1;progressBase=0;
  json(@{@"ok":@YES,@"completed":@(completed),@"bytes":@(bytes),@"volumeMarkedDirty":@(markedDirty)});return 0;
 }catch(const std::exception&ex){progressItem=-1;progressBase=0;json(@{@"error":[NSString stringWithUTF8String:ex.what()],@"completed":@(completed),@"volumeMarkedDirty":@(markedDirty)});return 1;}
}
static NSDictionary*runDiskutil(NSArray<NSString*>*args){
 NSTask*t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/diskutil"];t.arguments=args;
 NSPipe*out=[NSPipe pipe];NSPipe*err=[NSPipe pipe];t.standardOutput=out;t.standardError=err;
 NSError*error=nil;if(![t launchAndReturnError:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
 NSData*d=[out.fileHandleForReading readDataToEndOfFile];[t waitUntilExit];
 if(t.terminationStatus)throw std::runtime_error("diskutil could not complete the operation; the volume may be busy");
 if([args containsObject:@"-plist"]){id result=[NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:nil error:&error];if(![result isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid disk metadata");return result;}
 return @{};
}
static int authorizedOpen(NSString*path,int flags){
 int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))throw std::runtime_error("Cannot create authorization channel");
 fcntl(pair[0],F_SETFD,FD_CLOEXEC);fcntl(pair[1],F_SETFD,FD_CLOEXEC);
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/libexec/authopen"];
 task.arguments=@[@"-stdoutpipe",@"-o",[@(flags) stringValue],path];
 task.standardInput=NSFileHandle.fileHandleWithNullDevice;
 NSFileHandle*channel=[[NSFileHandle alloc]initWithFileDescriptor:pair[1] closeOnDealloc:NO];task.standardOutput=channel;
 NSPipe*errors=[NSPipe pipe];task.standardError=errors;NSError*error=nil;
 if(![task launchAndReturnError:&error]){close(pair[0]);close(pair[1]);throw std::runtime_error(error.localizedDescription.UTF8String);}
 close(pair[1]);
 char payload[256];union{struct cmsghdr alignment;char bytes[CMSG_SPACE(sizeof(int)*4)];}control{};
 struct iovec iov{payload,sizeof payload};struct msghdr message{};message.msg_iov=&iov;message.msg_iovlen=1;message.msg_control=control.bytes;message.msg_controllen=sizeof control.bytes;
 ssize_t received;do{received=recvmsg(pair[0],&message,0);}while(received<0&&errno==EINTR);
 int fd=-1;
 if(received>0&&!(message.msg_flags&MSG_CTRUNC))for(struct cmsghdr*c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c))if(c->cmsg_level==SOL_SOCKET&&c->cmsg_type==SCM_RIGHTS&&c->cmsg_len>=CMSG_LEN(sizeof(int))){memcpy(&fd,CMSG_DATA(c),sizeof fd);break;}
 close(pair[0]);NSData*diagnostic=[errors.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];
 if(task.terminationStatus||fd<0){if(fd>=0)close(fd);NSString*detail=[[NSString alloc]initWithData:diagnostic encoding:NSUTF8StringEncoding];throw std::runtime_error((detail.length?detail:@"USB access authorization was cancelled or denied").UTF8String);}
 fcntl(fd,F_SETFD,FD_CLOEXEC);return fd;
}
static bool same(id a,id b){return a&&b&&[a isEqual:b];}
static NSNumber*mediaRegistryID(NSString*disk){
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOBSDNameMatching(kIOMainPortDefault,0,disk.UTF8String));
 if(!service)throw std::runtime_error("The USB partition has been disconnected");
 uint64_t identifier=0;kern_return_t result=IORegistryEntryGetRegistryEntryID(service,&identifier);IOObjectRelease(service);
 if(result!=KERN_SUCCESS||!identifier)throw std::runtime_error("Cannot identify the connected USB partition");return @(identifier);
}
// External drives on any bus (USB, Thunderbolt, SATA/PCIe enclosures) plus removable cards in a
// built-in SD reader. Internal fixed disks are never accepted.
static bool supportedParent(NSDictionary*p){
 if(!same(p[@"WholeDisk"],@YES)||!same(p[@"VirtualOrPhysical"],@"Physical"))return false;
 if(same(p[@"Internal"],@NO))return true;
 return same(p[@"BusProtocol"],@"Secure Digital")&&same(p[@"RemovableMedia"],@YES);
}
static NSDictionary*validateVolume(NSDictionary*target,bool formatting){
 NSString*disk=target[@"device"];
 if(![disk isKindOfClass:NSString.class]||![[NSPredicate predicateWithFormat:@"SELF MATCHES %@",@"disk[0-9]+s[0-9]+"] evaluateWithObject:disk])throw std::runtime_error("Invalid partition identifier");
 NSDictionary*d=runDiskutil(@[@"info",@"-plist",disk]);NSString*parent=d[@"ParentWholeDisk"];
 if(!same(d[@"DeviceIdentifier"],disk)||!same(d[@"WholeDisk"],@NO)||!same(d[@"WritableMedia"],@YES)||![parent isKindOfClass:NSString.class]||!same(parent,target[@"parent"]))throw std::runtime_error("Only partitions on external drives are supported");
 NSDictionary*p=runDiskutil(@[@"info",@"-plist",parent]);
 if(!supportedParent(p)||!same(d[@"Internal"],p[@"Internal"]))throw std::runtime_error("Unsupported parent device");
 NSNumber*registry=mediaRegistryID(disk);
 NSString*identity=d[@"DiskUUID"]?:[@"ioreg:" stringByAppendingString:registry.stringValue];
 if(![identity isKindOfClass:NSString.class]||identity.length==0||!same(identity,target[@"identity"])||!same(registry,target[@"registryID"])||!same(d[@"IOKitSize"],target[@"size"])||!same(d[@"PartitionMapPartitionOffset"],target[@"offset"])||!same(p[@"IOKitSize"],target[@"parentSize"])||!same(p[@"DeviceTreePath"],target[@"tree"]))throw std::runtime_error("The selected device has changed. Refresh the device list");
 if(![@[@"Microsoft Basic Data",@"Windows_NTFS"] containsObject:d[@"Content"]])throw std::runtime_error("This partition type is not supported; APFS and system partitions are protected");
 if([d[@"IOKitSize"] unsignedLongLongValue]<16*1024*1024)throw std::runtime_error("Partition is too small");
 if(formatting&&!same(target[@"formatConfirmation"],identity))throw std::runtime_error("Missing format confirmation");
 return d;
}
static uint16_t readNTFSVolumeFlags(int fd,const uint8_t*boot){
 uint32_t sector=u16(boot+11),cluster=boot[13]*sector;int8_t encoded=(int8_t)boot[64];
 if(sector<512||sector>4096||(sector&(sector-1))||cluster<sector||cluster>2*1024*1024||(cluster&(cluster-1)))throw std::runtime_error("Unsupported NTFS geometry");
 uint32_t record=encoded<0?(encoded>=-16?1U<<(-encoded):0):(uint32_t)encoded*cluster;
 if(record<sector||record>65536||record%sector)throw std::runtime_error("Unsupported NTFS record size");
 uint64_t mft=u64(boot+48);if(mft>INT64_MAX/cluster-4)throw std::runtime_error("Invalid MFT offset");
 std::vector<uint8_t>v(record);uint64_t offset=mft*cluster+3*record;
 if(pread(fd,v.data(),record,offset)!=(ssize_t)record||memcmp(v.data(),"FILE",4))throw std::runtime_error("Cannot validate NTFS volume metadata");
 uint16_t usa=u16(v.data()+4),count=u16(v.data()+6);
 if(count!=record/sector+1||usa+count*2>record)throw std::runtime_error("Invalid NTFS update sequence");
 for(unsigned i=1;i<count;i++){unsigned end=i*sector-2;if(u16(v.data()+end)!=u16(v.data()+usa))throw std::runtime_error("NTFS metadata integrity check failed");memcpy(v.data()+end,v.data()+usa+i*2,2);}
 uint32_t used=u32(v.data()+24),at=u16(v.data()+20);if(used>record||at<24)throw std::runtime_error("Invalid volume record");
 while(at+24<=used){
  uint32_t type=u32(v.data()+at),length=u32(v.data()+at+4);if(type==0xffffffff)break;
  if(length<24||length>used-at)throw std::runtime_error("Invalid volume attribute");
  if(type==0x70){uint16_t value=u16(v.data()+at+20);uint32_t bytes=u32(v.data()+at+16);
   if(v[at+8]||value<24||bytes<12||value>length||bytes>length-value)throw std::runtime_error("Invalid volume information");
   return u16(v.data()+at+value+10);
  }at+=length;
 }
 throw std::runtime_error("NTFS volume information is missing");
}
static void requireCleanNTFS(uint16_t flags){
 // Verified against this engine's LoadVolume (0x1000549dc): dirty is bit 0,
 // not "any flag set". The user's healthy Windows NTFS volume carries 0x0080.
 // Preserve that flag; never clear it or modify metadata to pass this check.
 if(flags&1)throw std::runtime_error("NTFS is marked dirty (volume flags include 0x0001). A filesystem check is required before writing");
 if(flags&~0x0080U){char message[160];snprintf(message,sizeof message,"NTFS volume flags 0x%04x require further checking before writing",flags);throw std::runtime_error(message);}
}
static NSString*enginePath(){
 char buf[4096];uint32_t n=sizeof buf;if(_NSGetExecutablePath(buf,&n))throw std::runtime_error("Executable path too long");
 NSString*exe=[[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
 NSString*path=[[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Frameworks/NTFSEngine.bundle"];
 NSData*bytes=[NSData dataWithContentsOfFile:path];if(!bytes)throw std::runtime_error("Bundled NTFS engine is missing");
 unsigned char h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,h);char hex[65];for(int i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",h[i]);
 if(strcmp(hex,EXPECTED_ENGINE_SHA256))throw std::runtime_error("NTFS engine integrity check failed");return path;
}
// ---- Volume check: the engine's own chkntfs (UFSD::CheckFs, the code behind Paragon's First Aid) ----
// Modes: "verify" uses a read-only device object, so the checker cannot write at all (the device's
// WriteBytes refuses). "safe" (chkntfs -f --safe) repairs nothing and only clears the dirty flag
// when no errors are found. "repair" (chkntfs -f) fixes the errors it finds.
// ABI, verified against CHKNTFS::main 0x1000008f0 and CCheckNtfs's constructor: OptCheck is
// {u64 flags (1 show minors, 2 no orphans, 4 safe, 8 short), u64 memory limit, u64 0}; fixing is
// enabled by a writable device. CHKDSK_INFO is 0x90 bytes: status u32 @0, total clusters @0x10,
// free clusters @0x18, cluster size @0x20. Status: 0 OK, 2 errors not fixed, 3 repaired,
// 4 minor errors, 6 OK but journal not replayed (read-only), 7 unsupported features.
struct CheckLog{std::string text,digits;int percent=-1;bool afterProgress=false;};
// The message service prints progress as "NN%" with no newline on a non-terminal, glued to the
// surrounding messages and often one character per write. Progress runs are reported as stages
// (a run that follows a message starts a new stage) and kept out of the log.
static void checkLogFlushDigits(CheckLog*log){if(log->text.size()<256*1024)log->text+=log->digits;log->digits.clear();}
static int checkLogWrite(void*cookie,const char*buffer,int length){
 auto*log=static_cast<CheckLog*>(cookie);
 for(int i=0;i<length;i++){
  char c=buffer[i];
  bool boundary=log->afterProgress||log->text.empty()||log->text.back()=='\n';
  if(c>='0'&&c<='9'&&(boundary||!log->digits.empty())&&log->digits.size()<3){log->digits.push_back(c);continue;}
  if(c=='%'&&!log->digits.empty()){
   int value=std::min(atoi(log->digits.c_str()),100);log->digits.clear();
   bool stage=!log->afterProgress;if(stage){progressItem++;log->percent=-1;}
   if(value!=log->percent){log->percent=value;reportProgress((uint64_t)value,stage||value==100);}
   log->afterProgress=true;continue;
  }
  if(c==' '&&log->afterProgress&&log->digits.empty())continue;
  if(!log->digits.empty())checkLogFlushDigits(log);
  if(c=='\r')continue;
  log->afterProgress=false;
  if(log->text.size()<256*1024)log->text.push_back(c);
 }
 return length;
}
static int runCheck(const char*enginePathC,const char*image,NSString*mode){
 try{
  bool verify=[mode isEqual:@"verify"],safe=[mode isEqual:@"safe"];
  Engine e(enginePathC);
  uint16_t flagsBefore=volumeFlags;bool hibernated=false;
  if(!verify){
   // Repairing a hibernated Windows volume destroys the hibernated session (and its unsaved data).
   try{Session probe(e);probe.open(image,true);for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)hibernated=true;}catch(...){}
   if(hibernated)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");
  }
  e.fn<void*(*)()>(0x10000878c)();
  void*mm=e.fn<void*(*)()>(0x10000878c)();void*sm=e.fn<void*(*)()>(0x100009644)();void*tm=e.fn<void*(*)()>(0x100007a80)();
  void*io=ioFromAuthorizedDescriptor(e,verify,image);
  struct IoGuard{Engine&e;void*p;~IoGuard(){e.fn<void(*)(void*)>(0x100008668)(p);}}ioGuard{e,io};
  CheckLog log;FILE*out=funopen(&log,nullptr,checkLogWrite,nullptr,nullptr);if(!out)throw std::runtime_error("Cannot start the volume check");
  using MessageFn=void*(*)(FILE*,void*,bool);
  // The message service's first call installs a SIGINT handler whose "break" makes the checker ask
  // a yes/no question on stdin, which is this worker's request pipe. Keep our own SIGINT action so
  // that question can never be asked.
  struct sigaction previous{};sigaction(SIGINT,nullptr,&previous);
  void*message=e.fn<MessageFn>(0x100008ebc)(out,nullptr,false);
  sigaction(SIGINT,&previous,nullptr);
  struct OutGuard{Engine&e;FILE*f;~OutGuard(){e.fn<MessageFn>(0x100008ebc)(nullptr,nullptr,true);fclose(f);}}outGuard{e,out};
  alignas(16) uint64_t options[3]={safe?4ULL:0ULL,0,0};alignas(16) uint8_t info[0x100]{};
  using CheckFn=Status(*)(unsigned long,void*,void*,void*,void*,void*,void*,const void*,const char*,void*);
  progressItem=-1;progressBase=0;
  struct StageGuard{~StageGuard(){progressItem=-1;}}stageGuard;
  Status status=e.fn<CheckFn>(0x100015d18)(2,mm,sm,io,tm,message,nullptr,options,"NTFS",info);
  // Whatever the checker wrote must reach the medium, also when it stopped with an error.
  if(!verify)syncDevice(resourceFD);
  fflush(out);
  if(!log.digits.empty())checkLogFlushDigits(&log);
  if(status){char b[200];snprintf(b,sizeof b,"check NTFS: UFSD 0x%08x",status);throw std::runtime_error(b);}
  uint32_t result=u32(info);uint64_t clusters=u64(info+0x10),freeClusters=u64(info+0x18),clusterSize=u64(info+0x20);
  uint16_t flagsAfter=flagsBefore;bool stateKnown=false;
  {uint8_t boot[512];if(pread(resourceFD,boot,512,0)==512){try{flagsAfter=readNTFSVolumeFlags(resourceFD,boot);stateKnown=true;}catch(...){}}}
  NSString*name=@"unknown";
  switch(result){case 0:name=@"clean";break;case 2:name=@"errors";break;case 3:name=@"repaired";break;case 4:name=@"minor";break;case 6:name=@"journal";break;case 7:name=@"unsupported";break;default:break;}
  NSString*text=[[NSString alloc]initWithBytes:log.text.data() length:log.text.size() encoding:NSUTF8StringEncoding]?:[[NSString alloc]initWithBytes:log.text.data() length:log.text.size() encoding:NSISOLatin1StringEncoding]?:@"";
  json(@{@"ok":@YES,@"mode":mode,@"result":name,@"status":@(result),
         @"flagsBefore":@(flagsBefore),@"flagsAfter":@(flagsAfter),@"flagsKnown":@(stateKnown),
         @"dirtyBefore":@((flagsBefore&1)!=0),@"dirtyAfter":@((flagsAfter&1)!=0),
         @"writable":@(stateKnown&&(flagsAfter&~0x0080U)==0),
         @"totalBytes":@(clusters*clusterSize),@"freeBytes":@(freeClusters*clusterSize),@"log":text});
  return 0;
 }catch(const std::exception&ex){json(@{@"error":[NSString stringWithUTF8String:ex.what()]});return 1;}
}
static int processRequest(NSData*data,const char*executable){@autoreleasepool{
 try{
  // Per-request metadata must not leak from a previous USB target into an image.
  partitionOffset=0;volumeFlags=0;cancelRequested=0;progressEnabled=false;
  if(data.length>16*1024*1024)throw std::runtime_error("Request too large");
  id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if(![object isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid request");
  NSDictionary*r=object;NSString*action=r[@"action"];NSDictionary*t=r[@"target"];NSArray*args=r[@"arguments"]?:@[];
  progressEnabled=streaming&&[r[@"progress"] isEqual:@YES];
  NSDictionary*counts=@{@"ls":@1,@"put":@2,@"get":@2,@"mkdir":@1,@"rename":@2,@"remove":@1,@"rmdir":@1,@"format":@1,@"inspect":@0,@"release":@0,@"health":@0,@"fixsec":@1,@"batch":@0,@"check":@1};
  if(![action isKindOfClass:NSString.class]||!counts[action]||![args isKindOfClass:NSArray.class]||args.count!=[counts[action] unsignedIntegerValue]||![t isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid operation");
  for(id arg in args)if(![arg isKindOfClass:NSString.class]||[(NSString*)arg length]>4096||[(NSString*)arg rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)throw std::runtime_error("Invalid operation argument");
  if([action isEqual:@"release"]){releaseCached();json(@{@"ok":@YES});return 0;}
  NSArray*operations=nil;bool batchMutating=false;
  if([action isEqual:@"batch"]){
   operations=r[@"operations"];
   if(![operations isKindOfClass:NSArray.class]||operations.count==0||operations.count>5000)throw std::runtime_error("Invalid operation");
   NSDictionary*arity=@{@"put":@2,@"get":@2,@"mkdir":@1,@"remove":@1,@"rmdir":@1};
   for(NSDictionary*o in operations){
    if(![o isKindOfClass:NSDictionary.class]||![o[@"op"] isKindOfClass:NSString.class]||!arity[o[@"op"]]||![o[@"args"] isKindOfClass:NSArray.class]||[o[@"args"] count]!=[arity[o[@"op"]] unsignedIntegerValue])throw std::runtime_error("Invalid operation");
    for(id arg in o[@"args"])if(![arg isKindOfClass:NSString.class]||[(NSString*)arg length]==0||[(NSString*)arg length]>4096||[(NSString*)arg rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)throw std::runtime_error("Invalid operation argument");
    if(![o[@"op"] isEqual:@"get"])batchMutating=true;
   }
  }
  bool checking=[action isEqualToString:@"check"];NSString*checkMode=checking?args[0]:nil;
  if(checking&&![@[@"verify",@"safe",@"repair"] containsObject:checkMode])throw std::runtime_error("Invalid operation");
  NSString*engine=enginePath();bool mutating=operations?batchMutating:checking?![checkMode isEqual:@"verify"]:![@[@"ls",@"get",@"health"] containsObject:action];bool formatting=[action isEqualToString:@"format"];
  NSString*path=nil;bool volume=[t[@"kind"] isEqual:@"volume"];
  if([action isEqual:@"inspect"]){if(!volume)throw std::runtime_error("Inspect requires a USB partition");NSDictionary*d=validateVolume(t,false);json(@{@"ok":@YES,@"device":d[@"DeviceIdentifier"]});return 0;}
  if(volume){
   if(geteuid()==0)throw std::runtime_error("Launch the application as your normal user; USB authorization is handled by macOS");
   callerUID=getuid();
   NSDictionary*d=validateVolume(t,formatting);
   if([d[@"MountPoint"] length])runDiskutil(@[@"unmount",t[@"device"]]);
   d=validateVolume(t,formatting);if([d[@"MountPoint"] length])throw std::runtime_error("Volume is still mounted");
   path=[@"/dev/" stringByAppendingString:t[@"device"]];partitionOffset=[t[@"offset"] unsignedLongLongValue];
  }else if([t[@"kind"] isEqual:@"image"]){
   path=t[@"path"];if(![path isKindOfClass:NSString.class]||![path isAbsolutePath])throw std::runtime_error("Invalid image path");
   if(geteuid()==0)throw std::runtime_error("Images must be opened without administrator privileges");
   if(formatting&&!same(t[@"formatConfirmation"],path))throw std::runtime_error("Missing image format confirmation");
  }else throw std::runtime_error("Unknown target kind");
  struct stat before{};if(lstat(path.fileSystemRepresentation,&before)||(!volume&&!S_ISREG(before.st_mode))||(volume&&!S_ISBLK(before.st_mode)))throw std::runtime_error("Target is missing or has an unsupported type");
  if(volume&&streaming){
   if(cachedFD>=0&&!same(cachedRegistry,t[@"registryID"]))releaseCached();
   if(cachedFD<0){cachedFD=authorizedOpen(path,O_RDWR|O_NOFOLLOW);cachedRegistry=t[@"registryID"];}
   resourceFD=dup(cachedFD);
  }else resourceFD=volume?authorizedOpen(path,(mutating?O_RDWR:O_RDONLY)|O_NOFOLLOW):open(path.fileSystemRepresentation,(mutating?O_RDWR:O_RDONLY)|O_NOFOLLOW);
  if(resourceFD<0)throw std::runtime_error(strerror(errno));
  struct Resource{~Resource(){if(resourceFD>=0)close(resourceFD);resourceFD=-1;}}lease;
  struct stat after{};if(fstat(resourceFD,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_rdev!=after.st_rdev)throw std::runtime_error("Target changed during open");
  if(volume&&!same(mediaRegistryID(t[@"device"]),t[@"registryID"]))throw std::runtime_error("USB partition changed while opening");
  if(flock(resourceFD,LOCK_EX|LOCK_NB))throw std::runtime_error("Image is in use by another process");
  if(!volume&&after.st_size<16*1024*1024)throw std::runtime_error("Image is too small");
  if(!formatting){uint8_t boot[512];if(pread(resourceFD,boot,512,0)!=512||memcmp(boot+3,"NTFS    ",8)||boot[510]!=0x55||boot[511]!=0xaa)throw std::runtime_error("The selected target does not contain an NTFS filesystem");volumeFlags=readNTFSVolumeFlags(resourceFD,boot);if(mutating&&!checking)requireCleanNTFS(volumeFlags);}
  if(formatting){NSString*label=args[0];if(!label.length||label.length>32||[label rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)throw std::runtime_error("Volume name must contain 1-32 characters");}
  std::string fdpath="/dev/fd/"+std::to_string(resourceFD);
  if(checking)return runCheck(engine.UTF8String,fdpath.c_str(),checkMode);
  if(operations)return runBatch(engine.UTF8String,fdpath.c_str(),operations,mutating);
  std::vector<std::string>strings={executable,engine.UTF8String,action.UTF8String,fdpath};
  for(NSString*a in args)strings.push_back(a.UTF8String);
  std::vector<char*>raw;for(auto&s:strings)raw.push_back(s.data());raw.push_back(nullptr);
  return legacyMain((int)strings.size(),raw.data());
 }catch(const std::exception&e){json(@{@"error":[NSString stringWithUTF8String:e.what()]});return 1;}
}}

int main(int argc,char**argv){struct rlimit noCore{0,0};setrlimit(RLIMIT_CORE,&noCore);@autoreleasepool{
 if(argc!=2||(strcmp(argv[1],"request")&&strcmp(argv[1],"serve"))){json(@{@"error":@"Use the application to send a JSON request"});return 2;}
 streaming=!strcmp(argv[1],"serve");
 // If the app disappears mid-operation the response write must not kill the worker before the
 // engine session is flushed and closed; EOF on stdin then ends the serve loop cleanly.
 signal(SIGPIPE,SIG_IGN);
 struct sigaction cancel{};cancel.sa_handler=onCancelSignal;cancel.sa_flags=SA_RESTART;sigemptyset(&cancel.sa_mask);sigaction(SIGUSR1,&cancel,nullptr);
 if(!streaming)return processRequest([NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile],argv[0]);
 char*line=nullptr;size_t capacity=0;ssize_t length;
 while((length=getline(&line,&capacity,stdin))>=0){@autoreleasepool{NSData*data=[NSData dataWithBytes:line length:length];processRequest(data,argv[0]);}}
 free(line);releaseCached();return 0;
}}
