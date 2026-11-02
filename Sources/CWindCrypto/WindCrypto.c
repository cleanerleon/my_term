#include "WindCrypto.h"
#include <string.h>
#include <stdlib.h>

/* FIPS 202 SHA3-512, with a 72-byte sponge rate. All lanes are little endian. */
static const uint64_t RC[24] = {
  0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
  0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
  0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
  0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
  0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
  0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL
};
static const unsigned R[25]={0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14};
static uint64_t rol(uint64_t v,unsigned n){return n ? (v<<n)|(v>>(64-n)):v;}
static void wipe(void *p,size_t n){volatile uint8_t *b=p;while(n--)*b++=0;}
static void permute(uint64_t a[25]){
 uint64_t c[5],d[5],b[25];
 for(unsigned r=0;r<24;r++){
  for(unsigned x=0;x<5;x++)c[x]=a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20];
  for(unsigned x=0;x<5;x++)d[x]=c[(x+4)%5]^rol(c[(x+1)%5],1);
  for(unsigned y=0;y<5;y++)for(unsigned x=0;x<5;x++)a[x+5*y]^=d[x];
  for(unsigned y=0;y<5;y++)for(unsigned x=0;x<5;x++)b[y+5*((2*x+3*y)%5)]=rol(a[x+5*y],R[x+5*y]);
  for(unsigned y=0;y<5;y++)for(unsigned x=0;x<5;x++)a[x+5*y]=b[x+5*y]^((~b[(x+1)%5+5*y])&b[(x+2)%5+5*y]);
  a[0]^=RC[r];
 }
 wipe(c,sizeof c);wipe(d,sizeof d);wipe(b,sizeof b);
}
static void absorb(uint64_t state[25],const uint8_t block[72]){
 for(unsigned i=0;i<72;i++)state[i/8]^=(uint64_t)block[i]<<(8*(i%8));
 permute(state);
}
static void finish(uint64_t state[25],const uint8_t *data,size_t length,uint8_t output[64]){
 while(length>=72){absorb(state,data);data+=72;length-=72;}
 uint8_t block[72]={0};if(length)memcpy(block,data,length);block[length]=6;block[71]|=0x80;absorb(state,block);
 for(unsigned i=0;i<64;i++)output[i]=(uint8_t)(state[i/8]>>(8*(i%8)));
 wipe(block,sizeof block);wipe(state,25*sizeof(uint64_t));
}
void wind_sha3_512(const uint8_t *data,size_t length,uint8_t output[64]){uint64_t state[25]={0};finish(state,data,length,output);}
static void hmac(const uint64_t inner[25],const uint64_t outer[25],const uint8_t *message,size_t length,uint8_t output[64]){
 uint64_t state[25];uint8_t digest[64];memcpy(state,inner,sizeof state);finish(state,message,length,digest);
 memcpy(state,outer,sizeof state);finish(state,digest,64,output);wipe(digest,sizeof digest);
}
void wind_pbkdf2_sha3_512(const uint8_t *password,size_t plen,const uint8_t *salt,size_t slen,uint32_t rounds,uint8_t output[48]){
 uint8_t key[72]={0},pad[72],u[64],t[64];uint64_t inner[25]={0},outer[25]={0};
 if(plen>72)wind_sha3_512(password,plen,key);else if(plen)memcpy(key,password,plen);
 for(unsigned i=0;i<72;i++)pad[i]=key[i]^0x36;absorb(inner,pad);
 for(unsigned i=0;i<72;i++)pad[i]=key[i]^0x5c;absorb(outer,pad);
 uint8_t *message=malloc(slen+4);if(!message){memset(output,0,48);return;}
 memcpy(message,salt,slen);memset(message+slen,0,4);message[slen+3]=1;
 hmac(inner,outer,message,slen+4,u);memcpy(t,u,64);
 for(uint32_t i=1;i<rounds;i++){hmac(inner,outer,u,64,u);for(unsigned j=0;j<64;j++)t[j]^=u[j];}
 memcpy(output,t,48);wipe(message,slen+4);free(message);wipe(key,sizeof key);wipe(pad,sizeof pad);wipe(u,sizeof u);wipe(t,sizeof t);wipe(inner,sizeof inner);wipe(outer,sizeof outer);
}
