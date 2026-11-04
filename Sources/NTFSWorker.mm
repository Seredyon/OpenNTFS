#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/file.h>
#include <pwd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <cctype>
#include <time.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
static int resourceFD=-1;
static uid_t callerUID=0;
static uint64_t partitionOffset=0;
static uint16_t volumeFlags=0;
#include <unistd.h>
static bool streaming=false;
static int cachedFD=-1;
static NSNumber*cachedRegistry=nil;
// The last target that passed the full validation while cachedFD stays open (see stillValidated).
static NSDictionary*validatedTarget=nil;
static uint64_t validatedAt=0;
// Serve mode: a volume's $Bitmap is counted once, then write sessions report the result of
// their own changes. Any other change (a failed write, repair, format) forgets the value.
static NSString*freeKnownFor=nil,*currentTarget=nil;
static uint64_t freeKnownBytes=0;
static void releaseCached(){if(cachedFD>=0)close(cachedFD);cachedFD=-1;cachedRegistry=nil;validatedTarget=nil;freeKnownFor=nil;}
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
#include <list>
#include <unordered_map>
#include <sys/sysctl.h>
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
// fsync() alone does not empty the drive's own write cache on macOS. A durable barrier needs
// DKIOCSYNCHRONIZECACHE on devices / F_FULLFSYNC on images, otherwise data acknowledged as written
// can still be lost when the drive is unplugged.
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

#include "NativeSession.h"
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
  // Case-only rename: the old name collides with the new one, so go through a unique temporary name.
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
// Writing starts only on a clean volume and closes it clean, so a dirty state after an operation
// means the writer met a problem it could not finish cleanly.
static bool volumeLeftDirty(Session&s){try{return s.volumeState()!=2;}catch(...){return false;}}
static void json(id object){NSData*d=[NSJSONSerialization dataWithJSONObject:object options:(streaming?0:NSJSONWritingPrettyPrinted) error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static int runOperation(int argc,char**argv){@autoreleasepool{
 try{
  if(argc<3)throw std::runtime_error("Missing image");
  std::string cmd=argv[1];
  if(cmd=="format"){
   struct stat st{};if(stat(argv[2],&st)||(!S_ISREG(st.st_mode)&&!(resourceFD>=0&&S_ISCHR(st.st_mode))))throw std::runtime_error("Unsupported format target");
   uint64_t bytes=0;uint32_t alignment=1,sector=512;descriptorGeometry(resourceFD,bytes,alignment,sector);
   char message[512]{};
   if(ntfs_format(resourceFD,bytes,(int32_t)sector,(uint32_t)(partitionOffset/sector),argc>3?argv[3]:"OPENNTFS",message,sizeof message))throw std::runtime_error(message[0]?message:"format NTFS");
   syncDevice(resourceFD);json(@{@"ok":@YES});return 0;
  }
  bool mutating=cmd=="put"||cmd=="mkdir"||cmd=="rename"||cmd=="remove"||cmd=="rmdir"||cmd=="fixsec";
  if(mutating){Session probe;probe.open(argv[2],true);probe.requireWritableState();for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");}
  Session s;s.open(argv[2],!mutating);
  auto done=[&](NSDictionary*d){if(mutating&&volumeLeftDirty(s)){NSMutableDictionary*m=[d mutableCopy];m[@"volumeMarkedDirty"]=@YES;d=m;}json(d);};
  if(cmd=="health"){NSMutableDictionary*report=[@{@"flags":@(volumeFlags),@"flagsHex":[NSString stringWithFormat:@"0x%04x",volumeFlags],@"engineState":@(s.volumeState()),@"journalRecoveryNeeded":@(s.journalRecoveryNeeded()),@"readOnlyCheck":@YES} mutableCopy];uint64_t free=0;if(s.freeBytes(free))report[@"freeBytes"]=@(free);json(report);}
  else if(cmd=="ls"){s.verifyPath([NSString stringWithUTF8String:argv[3]],true,true);json(@{@"entries":s.list(argv[3])});}
  else if(cmd=="foldersize"){
   NSString*folder=[NSString stringWithUTF8String:argv[3]];s.verifyPath(folder,true,true);
   NSMutableDictionary*folders=[NSMutableDictionary new];uint64_t total=s.folderSize(folder,folders);
   // A reply has to fit one line of the app's pipe: a very large tree reports the folder alone.
   json(@{@"ok":@YES,@"bytes":@(total),@"folders":folders.count>300000?@{folder:@(total)}:folders});
  }
  else if(cmd=="put"||cmd=="get"){
   if(argc!=5)throw std::runtime_error("transfer requires local path and NTFS path");
   NSString*remote=[NSString stringWithUTF8String:argv[4]];uint64_t n=0;
   if(cmd=="put"){n=opPut(s,argv[3],remote);s.flush();}else n=opGet(s,argv[3],remote);
   done(@{@"ok":@YES,@"bytes":@(n)});
  }else if(cmd=="mkdir"&&argc==4){opMkdir(s,[NSString stringWithUTF8String:argv[3]]);s.flush();done(@{@"ok":@YES});}
  else if(cmd=="rename"&&argc==5){opRename(s,[NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]]);s.flush();done(@{@"ok":@YES});}
  else if(cmd=="fixsec"&&argc==4){NSString*path=[NSString stringWithUTF8String:argv[3]];if([path isEqual:@"/"])throw std::runtime_error("The root directory is protected");NSDictionary*item=s.entry(path);s.verifyPath(path,true,[item[@"directory"] boolValue]);unsigned checked=0,fixed=0;
   try{s.repairSecurity(path,checked,fixed);}catch(...){s.flush();throw;}
s.flush();done(@{@"ok":@YES,@"checked":@(checked),@"fixed":@(fixed)});}
  else if((cmd=="remove"||cmd=="rmdir")&&argc==4){opRemove(s,[NSString stringWithUTF8String:argv[3]],cmd=="rmdir");s.flush();done(@{@"ok":@YES});}
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
static void requireWritableVolume(const char*image){
 Session probe;probe.open(image,true);probe.requireWritableState();
 for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");
}
static int runBatch(const char*image,NSArray*operations,bool mutating){
 NSUInteger completed=0;uint64_t bytes=0;bool markedDirty=false;
 try{
  if(mutating)requireWritableVolume(image);
  Session s;s.open(image,!mutating);
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
   // Refuse a batch whose files cannot fit before anything is copied (each file is checked again).
   if(mutating){uint64_t total=0;for(NSDictionary*o in operations)if([o[@"op"] isEqual:@"put"]){struct stat st{};if(!stat([o[@"args"][0] UTF8String],&st)&&S_ISREG(st.st_mode))total+=(uint64_t)st.st_size;}if(total)s.requireSpace(total);}
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
   if(mutating)markedDirty=volumeLeftDirty(s);
   throw;
  }
  if(mutating)markedDirty=volumeLeftDirty(s);
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
static bool mountedNow(NSString*disk){
 struct statfs*list=nullptr;int count=getmntinfo(&list,MNT_NOWAIT);
 const char*name=disk.UTF8String;size_t length=strlen(name);
 for(int i=0;i<count;i++)for(const char*at=list[i].f_mntfromname;(at=strstr(at,name));at+=length)if(!isalnum((unsigned char)at[length]))return true;
 return false;
}
// The full validation below starts two diskutil processes (0.3 s). While the descriptor stays
// open it is repeated every 30 seconds; between those runs the identifier of the same IOMedia
// object is compared, which changes when a drive is replaced or repartitioned.
static bool stillValidated(NSDictionary*target){
 if(cachedFD<0||![validatedTarget isEqual:target])return false;
 if(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)-validatedAt>30000000000ull)return false;
 return same(mediaRegistryID(target[@"device"]),target[@"registryID"])&&!mountedNow(target[@"device"]);
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
 // Dirty is bit 0 (VOLUME_IS_DIRTY),
 // not "any flag set". The user's healthy Windows NTFS volume carries 0x0080.
 // Preserve that flag; never clear it or modify metadata to pass this check.
 if(flags&1)throw std::runtime_error("NTFS is marked dirty (volume flags include 0x0001). A filesystem check is required before writing");
 if(flags&~0x0080U){char message[160];snprintf(message,sizeof message,"NTFS volume flags 0x%04x require further checking before writing",flags);throw std::runtime_error(message);}
}
// ---- Volume check: native consistency check and repair (NTFSCheck.swift) ---------------------
static void nativeCheckProgress(int32_t percent,void*){progressItem=0;reportProgress((uint64_t)percent,percent==100);}
static int runCheck(const char*image,NSString*mode){
 try{
  bool verify=[mode isEqual:@"verify"];
  uint16_t flagsBefore=volumeFlags;bool hibernated=false;
  if(!verify){
   // Repairing a hibernated Windows volume destroys the hibernated session (and its unsaved data).
   try{Session probe;probe.open(image,true);for(NSDictionary*entry in probe.list("/"))if([entry[@"name"] caseInsensitiveCompare:@"hiberfil.sys"]==NSOrderedSame)hibernated=true;}catch(...){}
   if(hibernated)throw std::runtime_error("Windows hibernation file detected. Disable hibernation and cleanly shut down Windows before writing");
  }
  uint64_t bytes=0;uint32_t alignment=1,sector=512;descriptorGeometry(resourceFD,bytes,alignment,sector);
  char message[1024]{};progressItem=-1;progressBase=0;
  struct StageGuard{~StageGuard(){progressItem=-1;}}stageGuard;
  reportProgress(0,true);
  NSDictionary*report=parseJSON(ntfs_check(resourceFD,bytes,(int32_t)alignment,mode.UTF8String,nativeCheckProgress,nullptr,message,sizeof message));
  if(!verify)syncDevice(resourceFD);
  if(![report isKindOfClass:NSDictionary.class])throw std::runtime_error(message[0]?message:"check NTFS");
  uint16_t flagsAfter=flagsBefore;bool stateKnown=false;
  {uint8_t boot[512];if(pread(resourceFD,boot,512,0)==512){try{flagsAfter=readNTFSVolumeFlags(resourceFD,boot);stateKnown=true;}catch(...){}}}
  NSString*name=report[@"result"];
  NSDictionary*codes=@{@"clean":@0,@"errors":@2,@"repaired":@3,@"minor":@4,@"journal":@6,@"unsupported":@7};
  json(@{@"ok":@YES,@"mode":mode,@"result":name,@"status":codes[name]?:@99,
         @"flagsBefore":@(flagsBefore),@"flagsAfter":@(flagsAfter),@"flagsKnown":@(stateKnown),
         @"dirtyBefore":@((flagsBefore&1)!=0),@"dirtyAfter":@((flagsAfter&1)!=0),
         @"writable":@(stateKnown&&(flagsAfter&~0x0080U)==0&&![name isEqual:@"journal"]),
         @"totalBytes":report[@"totalBytes"]?:@0,@"freeBytes":report[@"freeBytes"]?:@0,@"log":report[@"log"]?:@"",
         @"cache":@{@"enabled":@NO,@"hits":@0,@"deviceReads":@0,@"bypassed":@0,@"bytes":@0}});
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
  NSDictionary*counts=@{@"ls":@1,@"put":@2,@"get":@2,@"mkdir":@1,@"rename":@2,@"remove":@1,@"rmdir":@1,@"format":@1,@"inspect":@0,@"release":@0,@"health":@0,@"recount":@0,@"foldersize":@1,@"fixsec":@1,@"batch":@0,@"check":@1};
  if(![action isKindOfClass:NSString.class]||!counts[action]||![args isKindOfClass:NSArray.class]||args.count!=[counts[action] unsignedIntegerValue]||![t isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid operation");
  for(id arg in args)if(![arg isKindOfClass:NSString.class]||[(NSString*)arg length]>4096||[(NSString*)arg rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)throw std::runtime_error("Invalid operation argument");
  if([action isEqual:@"release"]){releaseCached();json(@{@"ok":@YES});return 0;}
  if([action isEqual:@"recount"]){freeKnownFor=nil;action=@"health";}
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
  bool mutating=operations?batchMutating:checking?![checkMode isEqual:@"verify"]:![@[@"ls",@"get",@"health",@"foldersize"] containsObject:action];bool formatting=[action isEqualToString:@"format"];
  if(mutating)freeKnownFor=nil;
  NSString*path=nil;bool validated=false;bool volume=[t[@"kind"] isEqual:@"volume"];
  if([action isEqual:@"inspect"]){if(!volume)throw std::runtime_error("Inspect requires a USB partition");NSDictionary*d=validateVolume(t,false);json(@{@"ok":@YES,@"device":d[@"DeviceIdentifier"]});return 0;}
  if(volume){
   if(geteuid()==0)throw std::runtime_error("Launch the application as your normal user; USB authorization is handled by macOS");
   callerUID=getuid();
   if(formatting||!streaming||!stillValidated(t)){
    NSDictionary*d=validateVolume(t,formatting);
    if([d[@"MountPoint"] length]){
     runDiskutil(@[@"unmount",t[@"device"]]);
     d=validateVolume(t,formatting);if([d[@"MountPoint"] length])throw std::runtime_error("Volume is still mounted");
    }
    validatedTarget=nil;validated=true;
   }
   // The raw node: the block node goes through the buffer cache, one page (16 KB) per transfer.
   path=[@"/dev/r" stringByAppendingString:t[@"device"]];partitionOffset=[t[@"offset"] unsignedLongLongValue];
  }else if([t[@"kind"] isEqual:@"image"]){
   path=t[@"path"];if(![path isKindOfClass:NSString.class]||![path isAbsolutePath])throw std::runtime_error("Invalid image path");
   if(geteuid()==0)throw std::runtime_error("Images must be opened without administrator privileges");
   if(formatting&&!same(t[@"formatConfirmation"],path))throw std::runtime_error("Missing image format confirmation");
  }else throw std::runtime_error("Unknown target kind");
  currentTarget=streaming?path:nil;
  struct stat before{};if(lstat(path.fileSystemRepresentation,&before)||(!volume&&!S_ISREG(before.st_mode))||(volume&&!S_ISCHR(before.st_mode)))throw std::runtime_error("Target is missing or has an unsupported type");
  if(volume&&streaming){
   if(cachedFD>=0&&!same(cachedRegistry,t[@"registryID"]))releaseCached();
   if(cachedFD<0){cachedFD=authorizedOpen(path,O_RDWR|O_NOFOLLOW);cachedRegistry=t[@"registryID"];}
   resourceFD=dup(cachedFD);
   if(validated){validatedTarget=t;validatedAt=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);}
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
  if(checking)return runCheck(fdpath.c_str(),checkMode);
  if(operations)return runBatch(fdpath.c_str(),operations,mutating);
  std::vector<std::string>strings={executable,action.UTF8String,fdpath};
  for(NSString*a in args)strings.push_back(a.UTF8String);
  std::vector<char*>raw;for(auto&s:strings)raw.push_back(s.data());raw.push_back(nullptr);
  return runOperation((int)strings.size(),raw.data());
 }catch(const std::exception&e){json(@{@"error":[NSString stringWithUTF8String:e.what()]});return 1;}
}}

int main(int argc,char**argv){struct rlimit noCore{0,0};setrlimit(RLIMIT_CORE,&noCore);@autoreleasepool{
 if(argc!=2||(strcmp(argv[1],"request")&&strcmp(argv[1],"serve"))){json(@{@"error":@"Use the application to send a JSON request"});return 2;}
 streaming=!strcmp(argv[1],"serve");
 // If the app disappears mid-operation the response write must not kill the worker before the
 // NTFS session is flushed and closed; EOF on stdin then ends the serve loop cleanly.
 signal(SIGPIPE,SIG_IGN);
 struct sigaction cancel{};cancel.sa_handler=onCancelSignal;cancel.sa_flags=SA_RESTART;sigemptyset(&cancel.sa_mask);sigaction(SIGUSR1,&cancel,nullptr);
 if(!streaming)return processRequest([NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile],argv[0]);
 char*line=nullptr;size_t capacity=0;ssize_t length;
 while((length=getline(&line,&capacity,stdin))>=0){@autoreleasepool{NSData*data=[NSData dataWithBytes:line length:length];processRequest(data,argv[0]);}}
 free(line);releaseCached();return 0;
}}
