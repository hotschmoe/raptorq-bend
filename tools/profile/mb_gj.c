// C reference for the dense tail elimination: Gauss-Jordan on an n x (n+T) GF(256) matrix stored as packed words.
// Same deterministic matrix and same "skip the column when the pivot is 0" rule as mb_gj.bend (checksums must match).
//   gcc -O3 -o build/mb_gj tools/profile/mb_gj.c && ./build/mb_gj <n> <T octets> [reps]
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <arm_neon.h>
static uint8_t EXP[512], LOG[256], MUL[256][256];
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
static void init(void){int x=1;for(int i=0;i<255;i++){EXP[i]=x;LOG[x]=i;x<<=1;if(x&256)x^=0x11D;}for(int i=255;i<512;i++)EXP[i]=EXP[i-255];
 for(int a=0;a<256;a++)for(int b=0;b<256;b++)MUL[a][b]=(a&&b)?EXP[LOG[a]+LOG[b]]:0;}
static inline uint8_t inv(uint8_t a){return EXP[255-LOG[a]];}
static uint32_t lcg(uint32_t x){return x*1664525u+1013904223u;}
// scalar: 4 table lookups per word (like the Bend kernel)
static void muladd_tab(uint32_t*d,const uint32_t*s,int w,uint8_t c){const uint8_t*r=MUL[c];for(int j=0;j<w;j++){uint32_t x=s[j];d[j]^=(uint32_t)r[x&255]|((uint32_t)r[(x>>8)&255]<<8)|((uint32_t)r[(x>>16)&255]<<16)|((uint32_t)r[x>>24]<<24);}}
static void scale_tab(uint32_t*d,int w,uint8_t c){const uint8_t*r=MUL[c];for(int j=0;j<w;j++){uint32_t x=d[j];d[j]=(uint32_t)r[x&255]|((uint32_t)r[(x>>8)&255]<<8)|((uint32_t)r[(x>>16)&255]<<16)|((uint32_t)r[x>>24]<<24);}}
static void muladd_neon(uint32_t*d,const uint32_t*s,int w,uint8_t c){uint8_t lo[16],hi[16];for(int i=0;i<16;i++){lo[i]=MUL[c][i];hi[i]=MUL[c][i<<4];}
 uint8x16_t L=vld1q_u8(lo),H=vld1q_u8(hi),m=vdupq_n_u8(15);int j=0;
 for(;j+4<=w;j+=4){uint8x16_t v=vld1q_u8((const uint8_t*)(s+j));uint8x16_t p=veorq_u8(vqtbl1q_u8(L,vandq_u8(v,m)),vqtbl1q_u8(H,vshrq_n_u8(v,4)));vst1q_u8((uint8_t*)(d+j),veorq_u8(vld1q_u8((uint8_t*)(d+j)),p));}
 for(;j<w;j++){uint32_t x=s[j];const uint8_t*r=MUL[c];d[j]^=(uint32_t)r[x&255]|((uint32_t)r[(x>>8)&255]<<8)|((uint32_t)r[(x>>16)&255]<<16)|((uint32_t)r[x>>24]<<24);}}
static void scale_neon(uint32_t*d,int w,uint8_t c){uint8_t lo[16],hi[16];for(int i=0;i<16;i++){lo[i]=MUL[c][i];hi[i]=MUL[c][i<<4];}
 uint8x16_t L=vld1q_u8(lo),H=vld1q_u8(hi),m=vdupq_n_u8(15);int j=0;
 for(;j+4<=w;j+=4){uint8x16_t v=vld1q_u8((uint8_t*)(d+j));vst1q_u8((uint8_t*)(d+j),veorq_u8(vqtbl1q_u8(L,vandq_u8(v,m)),vqtbl1q_u8(H,vshrq_n_u8(v,4))));}
 for(;j<w;j++)scale_tab(d+j,1,c);}
int main(int argc,char**argv){init();int n=atoi(argv[1]),T=atoi(argv[2]),reps=argc>3?atoi(argv[3]):3;
 int rw=(n+T+3)/4; /* words per row: n coefficient octets then T rhs octets, 4 per word */
 /* Bend pads the coefficient part to whole words: coefficient words = ceil(n/4), rhs words = T/4 */
 int cw=(n+3)/4; rw=cw+T/4;
 uint32_t*A0=malloc((size_t)n*rw*4),*A=malloc((size_t)n*rw*4);
 uint32_t x=12345;for(size_t i=0;i<(size_t)n*rw;i++){x=lcg(x);A0[i]=x;}
 for(int mode=0;mode<2;mode++){double best=1e9;uint32_t cs=0;
  for(int r=0;r<reps;r++){memcpy(A,A0,(size_t)n*rw*4);double t0=now();
   for(int c=0;c<n;c++){uint8_t piv=(A[(size_t)c*rw+(c>>2)]>>(8*(c&3)))&255;if(!piv)continue;
    uint8_t iv=inv(piv);if(mode==0)scale_tab(A+(size_t)c*rw,rw,iv);else scale_neon(A+(size_t)c*rw,rw,iv);
    for(int i=0;i<n;i++){if(i==c)continue;uint8_t f=(A[(size_t)i*rw+(c>>2)]>>(8*(c&3)))&255;if(!f)continue;
     if(mode==0)muladd_tab(A+(size_t)i*rw,A+(size_t)c*rw,rw,f);else muladd_neon(A+(size_t)i*rw,A+(size_t)c*rw,rw,f);}}
   double ms=now()-t0;if(ms<best)best=ms;}
  cs=7;for(size_t i=0;i<(size_t)n*rw;i++)cs=cs*31+A[i];
  printf("C GJ n=%d T=%d %-6s %8.2f ms  checksum %u  (%d words/row)\n",n,T,mode?"neon":"table",best,cs,rw);}
 return 0;}
