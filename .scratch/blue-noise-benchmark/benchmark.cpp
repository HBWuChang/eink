#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <numeric>
#include <random>
#include <vector>
struct Mask {
 int w,h,n; std::vector<unsigned char> on; std::vector<double> energy;
 struct K {int x,y; double v;}; std::vector<K> kernel;
 Mask(int W,int H):w(W),h(H),n(W*H),on(n),energy(n) {
  // Periodic Gaussian, sigma=1.5, truncated at 6 sigma.
  for(int y=-9;y<=9;y++)for(int x=-9;x<=9;x++)kernel.push_back({x,y,std::exp(-(x*x+y*y)/4.5)});
 }
 void change(int i,int sign){on[i]=sign>0; int x=i%w,y=i/w; for(auto k:kernel){int xx=(x+k.x+w)%w,yy=(y+k.y+h)%h; energy[yy*w+xx]+=sign*k.v;}}
 int pick(bool occupied,bool maximum){int best=-1; double value=maximum?-1e100:1e100; for(int i=0;i<n;i++)if(bool(on[i])==occupied && (maximum?energy[i]>value:energy[i]<value)){value=energy[i];best=i;} return best;}
};
int main(int argc,char**argv){int w=std::stoi(argv[1]),h=std::stoi(argv[2]); auto start=std::chrono::steady_clock::now(); Mask m(w,h);std::vector<int> ids(m.n);std::iota(ids.begin(),ids.end(),0);std::mt19937 rng(20261024);std::shuffle(ids.begin(),ids.end(),rng);int count=std::max(1,m.n/10);for(int j=0;j<count;j++)m.change(ids[j],1);
 int steps=0; bool converged=false;for(;steps<m.n*10;steps++){int c=m.pick(true,true);m.change(c,-1);int v=m.pick(false,false);m.change(v,1);if(c==v){converged=true;break;}}
 if(!converged){std::cerr<<"initial relaxation did not converge\n";return 2;}
 Mask base=m;std::vector<unsigned int> rank(m.n);
 for(int r=count-1;r>=0;r--){int c=m.pick(true,true);rank[c]=r;m.change(c,-1);}
 m=base;int half=(m.n+1)/2;for(int r=count;r<half;r++){int v=m.pick(false,false);rank[v]=r;m.change(v,1);}
 // Complement pattern: remove tightest clusters of remaining minority pixels.
 for(int i=0;i<m.n;i++)m.on[i]=!m.on[i];std::fill(m.energy.begin(),m.energy.end(),0);for(int i=0;i<m.n;i++)if(m.on[i])m.change(i,1);
 for(int r=half;r<m.n;r++){int c=m.pick(true,true);rank[c]=r;m.change(c,-1);}
 auto sorted=rank;std::sort(sorted.begin(),sorted.end());for(int i=0;i<m.n;i++)if(sorted[i]!=(unsigned)i)return 3;
 if(argc>3){std::ofstream out(argv[3],std::ios::binary);out<<"P5\n"<<w<<" "<<h<<"\n65535\n";for(auto r:rank){unsigned v=(uint64_t(r)*65536)/m.n;out.put(v>>8);out.put(v&255);} std::ofstream raw(std::string(argv[3])+".rank-u32",std::ios::binary);raw.write((char*)rank.data(),rank.size()*4);}
 double sec=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();std::cout<<w<<"x"<<h<<" pixels="<<m.n<<" relaxation="<<steps<<" seconds="<<sec<<" rank_permutation=PASS\n";
}
