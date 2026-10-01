// C twin of mb_list.bend: malloc'ed singly linked list of {col,coef}, map (alloc new cons, free old) R rounds with reversal.
//   gcc -O3 -o build/mb_list_c tools/profile/mb_list.c && ./build/mb_list_c <N> <rounds>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
typedef struct N{uint32_t c,f;struct N*n;}N;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
int main(int argc,char**argv){int n=atoi(argv[1]),r=atoi(argv[2]);double t0=now();
 N*l=0;uint32_t x=7;for(int i=0;i<n;i++){N*p=malloc(sizeof(N));p->c=x;p->f=x&255;p->n=l;l=p;x=x*1664525u+1013904223u;}
 for(int k=0;k<r;k++){N*acc=0;while(l){N*h=l;l=h->n;N*p=malloc(sizeof(N));p->c=h->c+h->f;p->f=h->f;p->n=acc;acc=p;free(h);}
  while(acc){N*h=acc;acc=h->n;h->n=l;l=h;}}
 uint32_t s=0;for(N*p=l;p;p=p->n)s=s*31+p->c+p->f;
printf("sum=%u\nC list n=%d rounds=%d ms=%.2f\n",s,n,r,now()-t0);
 // arena variant
 t0=now();N*pool[2];pool[0]=malloc(sizeof(N)*n);pool[1]=malloc(sizeof(N)*n);
 N*q=0;x=7;for(int i=0;i<n;i++){N*p=&pool[0][i];p->c=x;p->f=x&255;p->n=q;q=p;x=x*1664525u+1013904223u;}
 int cur=0;for(int k=0;k<r;k++){int nx=cur^1;N*acc=0;int idx=0;while(q){N*h=q;q=h->n;N*p=&pool[nx][idx++];p->c=h->c+h->f;p->f=h->f;p->n=acc;acc=p;}
  while(acc){N*h=acc;acc=h->n;h->n=q;q=h;}cur=nx;}
 s=0;for(N*p=q;p;p=p->n)s=s*31+p->c+p->f;
 printf("sum=%u\nC list (arena) n=%d rounds=%d ms=%.2f\n",s,n,r,now()-t0);return 0;}
// (appended) arena variant: same map, nodes taken from a ping-pong pool instead of malloc/free -- what a tuned C solver does.
