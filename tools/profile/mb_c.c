// C baseline for GF(256) symbol ops on flat byte arrays (compare with mb_vec.bend).
//   gcc -O3 -o build/mb_c tools/profile/mb_c.c && ./build/mb_c        (xor_scalar is auto-vectorised by gcc -O3;
//   gcc -O3 -fno-tree-vectorize -o build/mb_c_novec tools/profile/mb_c.c gives the truly scalar xor)
// last section: repair generation = N symbols, each the XOR of 7 random intermediate symbols out of L=1071 (T octets each)
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
static void xor_scalar(uint8_t*d,const uint8_t*s,int n){for(int i=0;i<n;i++)d[i]^=s[i];}
static void xor_neon(uint8_t*d,const uint8_t*s,int n){for(int i=0;i<n;i+=16)vst1q_u8(d+i,veorq_u8(vld1q_u8(d+i),vld1q_u8(s+i)));}
static void mul_table(uint8_t*d,const uint8_t*s,int n,uint8_t c){const uint8_t*row=MUL[c];for(int i=0;i<n;i++)d[i]^=row[s[i]];}
static inline uint32_t xt4(uint32_t w){return ((w&0x7f7f7f7f)<<1)^(((w>>7)&0x01010101)*0x1d);}
static void mul_swar(uint8_t*d,const uint8_t*s,int n,uint8_t c){for(int i=0;i<n;i+=4){uint32_t w,x;memcpy(&w,s+i,4);memcpy(&x,d+i,4);uint32_t acc=0;for(int b=0;b<8;b++){acc^=(0u-((c>>b)&1))&w;w=xt4(w);}x^=acc;memcpy(d+i,&x,4);}}
static void mul_neon(uint8_t*d,const uint8_t*s,int n,uint8_t c){uint8_t lo[16],hi[16];for(int i=0;i<16;i++){lo[i]=MUL[c][i];hi[i]=MUL[c][i<<4];}
 uint8x16_t L=vld1q_u8(lo),H=vld1q_u8(hi),m=vdupq_n_u8(15);
 for(int i=0;i<n;i+=16){uint8x16_t v=vld1q_u8(s+i);uint8x16_t p=veorq_u8(vqtbl1q_u8(L,vandq_u8(v,m)),vqtbl1q_u8(H,vshrq_n_u8(v,4)));vst1q_u8(d+i,veorq_u8(vld1q_u8(d+i),p));}}
typedef void (*xf)(uint8_t*,const uint8_t*,int);
typedef void (*mf)(uint8_t*,const uint8_t*,int,uint8_t);
int main(void){init();
 int Ts[2]={1024,16};
 for(int k=0;k<2;k++){int T=Ts[k];long total=1L<<27; long ops=total/T; // 128 MiB of symbol data per test
  uint8_t*d=calloc(T,1),*s=malloc(T);for(int i=0;i<T;i++)s[i]=i*7+3;
  struct{const char*n;xf f;}X[]={{"xor_scalar",xor_scalar},{"xor_neon",xor_neon}};
  struct{const char*n;mf f;}M[]={{"mul_table",mul_table},{"mul_swar",mul_swar},{"mul_neon",mul_neon}};
  for(int j=0;j<2;j++){double t0=now();for(long o=0;o<ops;o++){X[j].f(d,s,T);__asm__ volatile(""::"r"(d):"memory");}double ms=now()-t0;
   printf("C T=%d %-10s %8.2f ms  %7.3f GB/s  %6.2f ns/op  %5.2f ns/word(4B)\n",T,X[j].n,ms,total/ms/1e6,ms*1e6/ops,ms*1e6/ops/(T/4));}
  for(int j=0;j<3;j++){double t0=now();for(long o=0;o<ops;o++){M[j].f(d,s,T,(uint8_t)((o&0xfd)|2));__asm__ volatile(""::"r"(d):"memory");}double ms=now()-t0;
   printf("C T=%d %-10s %8.2f ms  %7.3f GB/s  %6.2f ns/op  %5.2f ns/word(4B)\n",T,M[j].n,ms,total/ms/1e6,ms*1e6/ops,ms*1e6/ops/(T/4));}
  free(d);free(s);}

 // repair-generation model (neon xor): 7016 xors per 1000 symbols (the real LT/PI term count at K=1000), random columns
 for(int k=0;k<2;k++){int T=Ts[k];int L=1071,N=1000;uint8_t*big=malloc((size_t)L*T);for(size_t i=0;i<(size_t)L*T;i++)big[i]=i*31+7;
  uint8_t*acc=malloc(T);uint32_t x=1;double best=1e9;
  for(int r=0;r<5;r++){double t0=now();for(int n=0;n<N;n++){memset(acc,0,T);int terms=n%1000<16?8:7;for(int t=0;t<terms;t++){x=x*1664525u+1013904223u;xor_neon(acc,big+(size_t)(x>>16)%L*T,T);}__asm__ volatile(""::"r"(acc):"memory");}double ms=now()-t0;if(ms<best)best=ms;}
  printf("C repair-gen model T=%d N=1000 (7 xors each, neon): %.3f ms\n",T,best);free(big);free(acc);}
 return 0;}
