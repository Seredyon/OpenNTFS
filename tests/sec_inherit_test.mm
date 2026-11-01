// Unit test for Windows ACL inheritance used for new NTFS objects (no engine, no disk access).
#define main worker_main
#include "../Sources/NTFSWorker.mm"
#undef main
static std::vector<uint8_t> parentSD(){
 using namespace sec;Descriptor d;d.owner=admins;d.group=systemSid;d.daclPresent=true;
 auto add=[&](uint8_t type,uint8_t flags,uint32_t mask,std::vector<uint8_t>s){Ace a;a.type=type;a.flags=flags;a.mask=mask;a.sid=s;d.dacl.push_back(a);};
 add(1,OI|CI,0x40000,sid(5,{21,1,2,3,1005}));          // explicit deny WRITE_DAC to a user
 add(0,OI|CI,0x1f01ff,admins);                          // Administrators full
 add(0,OI|CI,0x1f01ff,systemSid);                       // SYSTEM full
 add(0,OI|CI|IO,0x10000000,creatorOwner);               // CREATOR OWNER generic all (inherit only)
 add(0,OI|CI,0x1301bf,authenticated);                   // Authenticated Users modify
 add(0,OI|CI,0x1200a9,users);                           // Users read & execute
 add(0,CI,0x100004,sid(5,{21,1,2,3,1006}));             // folders only
 add(0,OI|NP,0x120089,sid(5,{21,1,2,3,1007}));          // files directly inside only
 add(0,0,0x1f01ff,everyone);                            // not inheritable
 return build(d,0x1000);
}
static void dump(const char*label,const std::vector<uint8_t>&b){
 auto d=sec::parse(b);printf("%s control=0x%04x aces=%zu\n",label,u16(b.data()+2),d.dacl.size());
 for(auto&a:d.dacl){printf("  type=%u flags=0x%02x mask=0x%08x sid=",a.type,a.flags,a.mask);
  printf("S-%u-%u",a.sid[0],a.sid[7]);for(unsigned i=0;i<a.sid[1];i++)printf("-%u",u32(a.sid.data()+8+4*i));printf("\n");}
}
int main(){
 auto p=parentSD();dump("parent",p);
 auto f=sec::inherit(p,false);dump("file",f);
 auto d=sec::inherit(p,true);dump("folder",d);
 auto ff=sec::inherit(d,false);dump("file-in-folder",ff);
 auto fallback=sec::inherit(std::vector<uint8_t>{1,2,3},false);dump("fallback-file",fallback);
 // Round trip and validity
 if(sec::build(sec::parse(f),0x0400)!=f){puts("ROUNDTRIP FAIL");return 1;}
 puts("OK");return 0;
}
