// Worker session on top of the NTFS implementation (Sources/NTFS,
// C interface in CInterface.swift). Included by NTFSWorker.mm.
extern "C" {
void*ntfs_open(int fd,uint64_t bytes,int32_t alignment,int32_t writable,char*message,long size);
int32_t ntfs_close(void*h,int32_t commit,char*message,long size);
int32_t ntfs_flush(void*h,char*message,long size);
int32_t ntfs_was_dirty(void*h);
int32_t ntfs_journal_clean(void*h);
char*ntfs_list(void*h,const char*path,char*message,long size);
char*ntfs_entry(void*h,const char*path,char*message,long size);
int32_t ntfs_same_name(void*h,const char*a,const char*b);
int32_t ntfs_free_bytes(void*h,uint64_t*bytes);
int32_t ntfs_create_file(void*h,const char*path,uint64_t size,uint64_t*file,char*message,long msize);
int32_t ntfs_write_file(void*h,uint64_t file,uint64_t offset,const void*buffer,long length,char*message,long size);
int32_t ntfs_finish_file(void*h,uint64_t file,char*message,long size);
int32_t ntfs_open_file(void*h,const char*path,uint64_t*file,uint64_t*size,char*message,long msize);
int32_t ntfs_read_file(void*h,uint64_t file,uint64_t offset,void*buffer,long length,long*got,char*message,long size);
void ntfs_close_file(void*h,uint64_t file);
int32_t ntfs_mkdir(void*h,const char*path,char*message,long size);
int32_t ntfs_remove(void*h,const char*path,int32_t directory,char*message,long size);
int32_t ntfs_rename(void*h,const char*a,const char*b,char*message,long size);
int32_t ntfs_repair_security(void*h,const char*path,uint32_t*checked,uint32_t*fixed,char*message,long size);
int32_t ntfs_format(int fd,uint64_t bytes,int32_t sector,uint32_t hidden,const char*label,char*message,long size);
char*ntfs_check(int fd,uint64_t bytes,int32_t alignment,const char*mode,void(*progress)(int32_t,void*),void*context,char*message,long size);
}

// Size and transfer alignment of the authorized descriptor (partition device or image file).
static void descriptorGeometry(int fd,uint64_t&bytes,uint32_t&alignment,uint32_t&sector){
 struct stat st{};if(fd<0||fstat(fd,&st))throw std::runtime_error("Missing authorized file descriptor");
 sector=512;alignment=1;
 if(S_ISCHR(st.st_mode)){uint64_t blocks=0;if(ioctl(fd,DKIOCGETBLOCKSIZE,&sector)||ioctl(fd,DKIOCGETBLOCKCOUNT,&blocks)||!sector||blocks>INT64_MAX/sector)throw std::runtime_error("Cannot read USB geometry");bytes=blocks*sector;alignment=sector;}
 else if(S_ISREG(st.st_mode)){
  bytes=(uint64_t)st.st_size;
  // Tests only: make an image behave like a device that accepts whole sectors (512 or 4096).
  if(const char*forced=getenv("OPENNTFS_TEST_ALIGNMENT")){uint32_t value=(uint32_t)atoi(forced);if(value==512||value==4096)alignment=value;}
 }else throw std::runtime_error("Unsupported descriptor type");
 if(sector!=512&&sector!=4096)throw std::runtime_error("Only 512-byte and 4096-byte sectors are supported");
}

static id parseJSON(char*text){
 if(!text)return nil;
 NSData*data=[NSData dataWithBytesNoCopy:text length:strlen(text) freeWhenDone:YES];
 return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
}

class Session{
 void*h=nullptr;
 char message[1024]{};
 void raise(int32_t code){throw std::runtime_error(message[0]?message:strerror(code));}
 void check(int32_t code){if(code)raise(code);}
 public:
 Session()=default;
 ~Session(){if(h){char m[256]{};ntfs_close(h,1,m,sizeof m);}}
 void open(const char*path,bool readOnly){
  struct stat st{};if(stat(path,&st)||(!S_ISREG(st.st_mode)&&!(resourceFD>=0&&S_ISCHR(st.st_mode))))throw std::runtime_error("Unsupported target type");
  uint64_t bytes=0;uint32_t alignment=1,sector=512;descriptorGeometry(resourceFD,bytes,alignment,sector);
  message[0]=0;h=ntfs_open(resourceFD,bytes,(int32_t)alignment,readOnly?0:1,message,sizeof message);
  if(!h)throw std::runtime_error(message[0]?message:"Cannot open the NTFS volume");
 }
 // State seen when the session opened: 2 clean, 1 marked as needing a check. A writable session
 // marks the volume itself while open, which is not a finding.
 unsigned volumeState(){return ntfs_was_dirty(h)?1:2;}
 bool journalRecoveryNeeded(){return !ntfs_journal_clean(h);}
 void requireWritableState(){
  if(volumeState()!=2)throw std::runtime_error("NTFS is marked dirty. Run a filesystem check before writing");
  if(journalRecoveryNeeded())throw std::runtime_error("Windows left unfinished changes in the NTFS journal. Open the drive on Windows and shut down normally before writing");
 }
 NSArray*list(const char*path){
  message[0]=0;id result=parseJSON(ntfs_list(h,path,message,sizeof message));
  if(![result isKindOfClass:NSArray.class])throw std::runtime_error(message[0]?message:"list directory");
  if([result count]>4000000)throw std::runtime_error("Directory too large");
  return result;
 }
 bool sameName(NSString*a,NSString*b){
  if([a caseInsensitiveCompare:b]==NSOrderedSame)return true;
  return ntfs_same_name(h,a.UTF8String,b.UTF8String)!=0;
 }
 NSDictionary*entry(NSString*path){
  message[0]=0;id result=parseJSON(ntfs_entry(h,path.UTF8String,message,sizeof message));
  if(!result)throw std::runtime_error(message[0]?message:"read directory entry");
  return [result isKindOfClass:NSDictionary.class]?result:nil;
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
 void repairSecurity(NSString*path,unsigned&checked,unsigned&fixed){
  uint32_t c=0,f=0;message[0]=0;check(ntfs_repair_security(h,path.UTF8String,&c,&f,message,sizeof message));checked=c;fixed=f;
 }
 void mkdir(const char*path){message[0]=0;check(ntfs_mkdir(h,path,message,sizeof message));}
 void rename(const char*a,const char*b){message[0]=0;check(ntfs_rename(h,a,b,message,sizeof message));}
 void remove(const char*path,bool directory){message[0]=0;check(ntfs_remove(h,path,directory?1:0,message,sizeof message));}
 // Total of a folder from the directory indexes, which hold the size of every file, so no file
 // record is read. Links are not followed. `folders` receives the total of each folder by path.
 uint64_t folderSize(NSString*path,NSMutableDictionary*folders,int depth=0){
  throwIfCancelled();
  if(depth>512)throw std::runtime_error("The folder tree is too deep");
  uint64_t total=0;
  @autoreleasepool{
   for(NSDictionary*entry in list(path.UTF8String)){
    if(![entry[@"directory"] boolValue]){total+=[entry[@"size"] unsignedLongLongValue];continue;}
    if([entry[@"attributes"] unsignedIntValue]&0x400)continue;
    NSString*child=[[path isEqual:@"/"]?@"/":[path stringByAppendingString:@"/"] stringByAppendingString:entry[@"name"]];
    total+=folderSize(child,folders,depth+1);
   }
  }
  folders[path]=@(total);
  return total;
 }
 bool freeBytes(uint64_t&bytes){
  if(currentTarget&&[freeKnownFor isEqual:currentTarget]){bytes=freeKnownBytes;return true;}
  if(ntfs_free_bytes(h,&bytes))return false;
  if(currentTarget){freeKnownFor=currentTarget;freeKnownBytes=bytes;}
  return true;
 }
 // A file that cannot fit is refused before anything is allocated.
 void requireSpace(uint64_t bytes){
  uint64_t free=0;if(ntfs_free_bytes(h,&free))return;
  uint64_t needed=(bytes+4095)/4096*4096+256*1024+bytes/256;
  if(needed>free)throw std::runtime_error("There is not enough free space on the NTFS volume.");
 }
 // Large transfers reach the raw device in one piece, which is what drives are fast at.
 static size_t transferBuffer(uint64_t size){return (size_t)std::max<uint64_t>(1,std::min<uint64_t>(size,4*1024*1024));}
 uint64_t transfer(const char*local,const char*remote,bool writing){
  uid_t previous=geteuid();if(previous==0&&callerUID>=501&&seteuid(callerUID))throw std::runtime_error("Cannot use caller permissions");
  int fd=::open(local,(writing?O_RDONLY:(O_WRONLY|O_CREAT|O_EXCL))|O_NOFOLLOW,0600);int savedErrno=errno;
  if(geteuid()!=previous&&seteuid(previous)){if(fd>=0)close(fd);throw std::runtime_error("Cannot restore worker permissions");}
  if(fd<0)throw std::runtime_error(strerror(savedErrno));
  struct stat localInfo{};if(fstat(fd,&localInfo)||!S_ISREG(localInfo.st_mode)){close(fd);throw std::runtime_error("Local transfer target must be a regular file");}
  struct Fd{int n;~Fd(){close(n);}}guard{fd};
  // An export creates its local file exclusively (O_EXCL), so a failed or cancelled export
  // removes only the partial file it created itself.
  try{
   std::vector<char>buffer;uint64_t total=0,file=0,size=0;
   reportProgress(0,true);
   if(writing){
    size=(uint64_t)localInfo.st_size;requireSpace(size);
    buffer.resize(transferBuffer(size));
    message[0]=0;check(ntfs_create_file(h,remote,size,&file,message,sizeof message));
    struct Handle{Session&s;uint64_t f;bool done=false;~Handle(){if(!done)ntfs_close_file(s.h,f);}}handle{*this,file};
    while(total<size){
     throwIfCancelled();
     ssize_t got=read(fd,buffer.data(),(size_t)std::min<uint64_t>(buffer.size(),size-total));
     if(got<0)throw std::runtime_error(strerror(errno));
     if(got==0)throw std::runtime_error("The source file changed while it was copied");
     message[0]=0;check(ntfs_write_file(h,file,total,buffer.data(),got,message,sizeof message));
     total+=(uint64_t)got;reportProgress(total,false);
    }
    char extra;if(read(fd,&extra,1)>0)throw std::runtime_error("The source file changed while it was copied");
    message[0]=0;check(ntfs_finish_file(h,file,message,sizeof message));handle.done=true;
   }else{
    message[0]=0;check(ntfs_open_file(h,remote,&file,&size,message,sizeof message));
    struct Handle{Session&s;uint64_t f;~Handle(){ntfs_close_file(s.h,f);}}handle{*this,file};
    buffer.resize(transferBuffer(size));
    while(total<size){
     throwIfCancelled();
     long got=0;message[0]=0;check(ntfs_read_file(h,file,total,buffer.data(),(long)buffer.size(),&got,message,sizeof message));
     if(got<=0)throw std::runtime_error("Unexpected end of the NTFS file");
     size_t offset=0;while(offset<(size_t)got){ssize_t w=write(fd,buffer.data()+offset,(size_t)got-offset);if(w<=0)throw std::runtime_error(strerror(errno));offset+=(size_t)w;}
     total+=(uint64_t)got;reportProgress(total,false);
    }
    if(fsync(fd))throw std::runtime_error(strerror(errno));
   }
   reportProgress(total,true);
   return total;
  }catch(...){struct stat now{};if(!writing&&!lstat(local,&now)&&now.st_dev==localInfo.st_dev&&now.st_ino==localInfo.st_ino)unlink(local);throw;}
 }
 // Commit followed by a full device barrier (see syncDevice).
 void flush(){
  message[0]=0;check(ntfs_flush(h,message,sizeof message));syncDevice(resourceFD);
  uint64_t free=0;if(currentTarget&&ntfs_free_bytes(h,&free)==0){freeKnownFor=currentTarget;freeKnownBytes=free;}
 }
};
