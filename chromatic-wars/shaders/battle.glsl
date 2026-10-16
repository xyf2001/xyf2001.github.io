#[compute]
#version 450
// 颜色大战：所有战场权威状态常驻主 RenderingDevice。
// std430: Particle=64B, Team=128B, Command=32B。CPU只读Team/64字统计。
// 每个dispatch之间必须插入compute barrier；9色碰撞每色单独dispatch。
layout(local_size_x=64, local_size_y=1, local_size_z=1) in;
struct Particle { vec4 pv; uvec4 info; vec4 geom; uvec4 aux; };
struct Team { uvec4 shield_gun; uvec4 storm_sniper; uvec4 life; vec4 clocks;
              uvec4 accounting; vec4 core; uvec4 misc; vec4 visual; };
struct Command { uvec4 a; uvec4 b; };
layout(set=0,binding=0,std430) restrict buffer Particles { Particle p[]; };
layout(set=0,binding=1,std430) restrict buffer Teams { Team team[]; };
layout(set=0,binding=2,std430) restrict buffer Territory { uint owner[]; };
layout(set=0,binding=3,std430) restrict buffer CellHeads { int head[]; };
layout(set=0,binding=4,std430) restrict buffer CellNext { int next_id[]; };
layout(set=0,binding=5,std430) restrict buffer Commands { Command command[]; };
layout(set=0,binding=6,std430) restrict buffer Metrics { uint stat[]; };
layout(rgba8,set=0,binding=7) uniform restrict writeonly image2D output_image;
layout(set=0,binding=8,std430) restrict buffer ParticlePixels { uint pixels[]; };
layout(set=0,binding=9,std430) readonly restrict buffer Parameters { vec4 par[]; };
layout(push_constant,std430) uniform Push { uvec4 control; vec4 clock; } pc;
// 领土计数随唯一的归属变更出口增量维护，避免周期性整图扫描。
const float TAU=6.28318530718;
uint cap() { return uint(par[0].x); }
uint balls() { return uint(par[1].w); }
uint total() { return cap()+balls(); }
uint terrain_size() { return uint(par[0].y); }
uint render_size() { return uint(par[0].z); }
uint cols() { return uint(par[1].z); }
float world() { return par[1].x; }
// GDScript整数为有符号64位：可表示的游戏能量域为0..2^63-1；超限保留输入命令并报错。
bool can_add64(uvec2 a,uvec2 b) { uint lo=a.x+b.x;uint high=a.y+b.y;uint carry=uint(lo<a.x);return high>=a.y&&high+carry>=high&&high+carry<=0x7fffffffu; }
uvec2 add64(uvec2 a,uvec2 b) { uint lo=a.x+b.x;uint high=a.y+b.y;uint result=high+uint(lo<a.x);if(high<a.y||result<high||result>0x7fffffffu){atomicOr(stat[15],1u);return uvec2(0xffffffffu,0x7fffffffu);}return uvec2(lo,result); }
bool less64(uvec2 a,uvec2 b) { return a.y<b.y || (a.y==b.y && a.x<b.x); }
bool zero64(uvec2 a) { return (a.x|a.y)==0u; }
uvec2 sub64(uvec2 a,uvec2 b) { return uvec2(a.x-b.x,a.y-b.y-uint(a.x<b.x)); }
uvec2 min64(uvec2 a,uvec2 b) { return less64(a,b)?a:b; }
float value64(uvec2 a) { return float(a.y)*4294967296.0+float(a.x); }
uvec2 energy(uint i) { return p[i].info.xy; }
void set_energy(uint i,uvec2 e) { p[i].info.xy=e; if(zero64(e)) p[i].info.w=0u; }
void spend(uint i,uvec2 amount) { set_energy(i,sub64(energy(i),amount)); }
void consumed(uvec2 e) { uvec2 v=add64(uvec2(stat[17],stat[18]),e); stat[17]=v.x;stat[18]=v.y; }
void consumed_atomic(uvec2 e) { uint old=atomicAdd(stat[17],e.x);uint high_add=e.y+uint(old+e.x<old);uint old_high=atomicAdd(stat[18],high_add);if(old_high+high_add>0x7fffffffu||old_high+high_add<old_high)atomicOr(stat[15],1u); }
uint hash32(uint x) { x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; return x^(x>>16); }
float random01(uint x) { return float(hash32(x)&0xffffffu)/16777216.0; }
vec2 normal_or(vec2 d,vec2 fallback) { float l=length(d);return l>0.00001?d/l:fallback; }
vec2 direction(float angle) { return vec2(cos(angle),sin(angle)); }
uint cell_index(vec2 pos) { ivec2 c=clamp(ivec2(pos/par[1].y),ivec2(0),ivec2(int(cols())-1));return uint(c.y)*cols()+uint(c.x); }
uint territory_index(vec2 pos) { ivec2 c=clamp(ivec2(pos/world()*float(terrain_size())),ivec2(0),ivec2(int(terrain_size())-1));return uint(c.y)*terrain_size()+uint(c.x); }
float shield_radius(uint t) { float e=value64(team[t].shield_gun.xy);return e<=0.0?0.0:min(par[12].x,par[4].z*(par[8].z+(par[8].y-par[8].z)*sqrt(e/max(par[8].w,1.0)))); }
float ball_radius(uint i) { return clamp(par[5].x+par[5].y*sqrt(max(value64(energy(i))/max(p[i].geom.y,1.0),0.0)),par[5].x,par[5].z); }
float threshold() { return mix(par[6].x,par[6].y,max(pc.clock.y,0.0)/max(par[6].z,0.001)); }
vec3 team_color(uint t) { if(t==0u)return vec3(1.0,0.22,0.32);if(t==1u)return vec3(0.18,1.0,0.51);if(t==2u)return vec3(0.22,0.5,1.0);return vec3(1.0,0.81,0.16); }
// 仅单invocation命令/事件pass调用；一次真正的归属变更同时维护两个面积计数。
void set_territory_owner(uint index,uint t) {uint previous=owner[index];if(previous==t)return;if(previous<4u)stat[8u+previous]--;owner[index]=t;if(t<4u)stat[8u+t]++;}
// invocation私有：一次prepare中只占槽、不释放槽；首次扫满后其余发射直接积压。
// 下一次dispatch重新初始化，碰撞腾出的槽会在下一子步正常重新使用。
bool normal_pool_exhausted=false;
bool big_pool_exhausted=false;
bool sniper_pool_exhausted=false;
// 仅串行pass调用，物理容量不足时调用者保留原库存/命令，绝不吞弹药。
int free_slot(bool big) { uint start=big?cap():0u;uint count=big?balls():cap()-8u;uint cursor=big?stat[21]:stat[20];
 if(big?big_pool_exhausted:normal_pool_exhausted)return -1;
 for(uint n=0u;n<count;n++){uint i=start+(cursor+n)%count;if(p[i].info.w==0u){if(big)stat[21]=(cursor+n+1u)%count;else stat[20]=(cursor+n+1u)%count;return int(i);}}
 if(big)big_pool_exhausted=true;else normal_pool_exhausted=true;return -1; }
// 为聚能弹预留8个槽，普通粒子满载时仍可发射；额外弹丸可使用空闲普通槽。
int free_sniper_slot() {if(sniper_pool_exhausted)return -1;for(uint n=0u;n<cap();n++){uint i=cap()-1u-n;if(p[i].info.w==0u)return int(i);}sniper_pool_exhausted=true;return -1;}
// 小粒子的geom.y保存出生速率；大球仍用geom.y锁定体积门槛。
// 大球的next_id尾部槽保存最近有效航向，普通粒子的链表区间不变。
vec2 fixed_particle_velocity(uint i,vec2 candidate,vec2 fallback) {
 float launch_speed=p[i].geom.y;
 if(launch_speed<=0.0||isnan(launch_speed)||isinf(launch_speed))launch_speed=p[i].info.w==2u?par[3].z:par[3].y;
 vec2 heading=normal_or(candidate,normal_or(fallback,direction(float(hash32(i)&65535u)*TAU/65536.0)));
 return heading*max(launch_speed,1.0);
}
void maintain_motion(uint i) {
 if(p[i].info.w==0u)return;
 if(p[i].info.w!=3u){p[i].pv.zw=fixed_particle_velocity(i,p[i].pv.zw,direction(float(hash32(i)&65535u)*TAU/65536.0));return;}
 float speed=length(p[i].pv.zw);float minimum_speed=clamp(par[12].z,1.0,max(par[3].w,1.0));
 if(speed>0.00001){next_id[i]=floatBitsToInt(atan(p[i].pv.w,p[i].pv.z));if(speed<minimum_speed)p[i].pv.zw*=minimum_speed/speed;}
 else {float angle=intBitsToFloat(next_id[i]);if(isnan(angle)||isinf(angle))angle=0.0;p[i].pv.zw=direction(angle)*minimum_speed;}
}
float contact_restitution(uint i);
void confine_after_contact(uint i) {
 if(p[i].info.w==0u)return;
 float radius=p[i].geom.x;float bounce=p[i].info.w==3u?contact_restitution(i):1.0;
 for(int axis=0;axis<2;axis++){
  if(p[i].pv[axis]<radius){p[i].pv[axis]=radius;if(p[i].pv[axis+2]<0.0)p[i].pv[axis+2]=-p[i].pv[axis+2]*bounce;}
  if(p[i].pv[axis]>world()-radius){p[i].pv[axis]=world()-radius;if(p[i].pv[axis+2]>0.0)p[i].pv[axis+2]=-p[i].pv[axis+2]*bounce;}
 }
}
bool spawn_timed(uint t,uint type,uvec2 e,float angle,uint seed,float first_move_dt) {
 int slot=type==2u?free_sniper_slot():free_slot(type==3u);if(slot<0)return false;uint i=uint(slot);float radius=type==3u?clamp(par[5].x+par[5].y*sqrt(value64(e)/max(threshold(),1.0)),par[5].x,par[5].z):par[4].x;
 vec2 d=direction(angle);float speed=type==3u?par[3].w:(type==2u?par[3].z:par[3].y);
 vec2 pos=team[t].core.xy+d*(max(team[t].core.z,shield_radius(t))+radius+3.0);pos=clamp(pos,vec2(radius+1.0),vec2(world()-radius-1.0));
 p[i].pv=vec4(pos,d*speed);p[i].info=uvec4(e,t,type);p[i].geom=vec4(radius,type==3u?threshold():speed,pos);p[i].aux=uvec4(0u,type==3u?0u:seed,0u,0u);
 // 机枪在子步内逐发出生；只推进出生后的实际时长，不把同批弹丸堆在同一位置。
 if(type==1u&&first_move_dt>=0.0){p[i].aux.y=floatBitsToUint(first_move_dt);p[i].aux.z|=0x80000000u;}
 if(type==3u)next_id[i]=floatBitsToInt(angle);
 stat[16]++;return true;
}
bool spawn(uint t,uint type,uvec2 e,float angle,uint seed) {return spawn_timed(t,type,e,angle,seed,-1.0);}
void update_shields() { for(uint t=0u;t<4u;t++)team[t].core.w=shield_radius(t); }
void eliminate(uint t) {team[t].life.x=2u;team[t].life.z++;team[t].storm_sniper.xy=add64(team[t].storm_sniper.xy,team[t].shield_gun.zw);team[t].shield_gun.zw=uvec2(0u);team[t].shield_gun.xy=uvec2(0u);}
void resolve_rescue(Command c) {uint t=c.a.y;if(t>=4u||team[t].life.x!=1u||team[t].life.y!=c.b.y)return;
 if(!zero64(c.a.zw)){team[t].shield_gun.xy=add64(team[t].shield_gun.xy,c.a.zw);team[t].clocks.x=pc.clock.y+par[4].w;team[t].life.x=0u;}
 else if(!zero64(team[t].shield_gun.xy))team[t].life.x=0u; // 握手期间正常充盾也必须保护核心。
 else eliminate(t);}
bool execute_command(Command c) {uint op=c.a.x;uint t=c.a.y;if(op==0u)return true;if(op==6u){resolve_rescue(c);return true;}
 // 批内较晚落槽的武器只在对应模拟步生效；负时间保留测试/死亡余波的立即语义。
 if(op>=1u&&op<=5u){float at_time=uintBitsToFloat(c.b.w);if(at_time>=0.0&&pc.clock.y+0.00001<at_time)return false;}
 // 独立测试入口：正常UI不会提交10..16号命令。所有修改仍在GPU内完成。
 if(op==14u){for(uint i=0u;i<total();i++)p[i].info.w=0u;stat[20]=0u;stat[21]=0u;normal_pool_exhausted=false;big_pool_exhausted=false;sniper_pool_exhausted=false;return true;}
 if(op==15u){uint n=max(c.b.x,1u);for(uint k=0u;k<n&&c.a.z+k<terrain_size()*terrain_size();k++)set_territory_owner(c.a.z+k,t);return true;}
 if(op==16u){for(uint i=0u;i<terrain_size()*terrain_size();i++)owner[i]=t;for(uint k=0u;k<4u;k++)stat[8u+k]=k==t?terrain_size()*terrain_size():0u;return true;}
 if(t>=4u)return true;
 if(op==17u){uint width=uint(ceil(sqrt(float(cap()))));float spacing=world()/float(width);vec2 velocity=uintBitsToFloat(c.b.xy);if(dot(velocity,velocity)<0.00001)velocity=vec2(30.0,17.0);
  for(uint i=0u;i<cap();i++){vec2 position=(vec2(i%width,i/width)+0.5)*spacing;position=clamp(position,vec2(par[4].x),vec2(world()-par[4].x));p[i].pv=vec4(position,velocity);p[i].info=uvec4(1u,0u,t,1u);p[i].geom=vec4(par[4].x,max(length(velocity),1.0),position);p[i].aux=uvec4(0u,hash32(i),0u,0u);}stat[20]=0u;return true;}
 if(op==10u){team[t].shield_gun=uvec4(c.a.zw,c.b.xy);team[t].life.x=c.b.z;team[t].clocks.x=uintBitsToFloat(c.b.w);team[t].storm_sniper=uvec4(0u);team[t].misc.y=0u;team[t].visual=vec4(0.0);return true;}
 if(op>=11u&&op<=13u){int slot=free_slot(op==13u);if(slot<0)return false;uint i=uint(slot);uint ty=op==11u?1u:(op==12u?2u:3u);p[i].pv=uintBitsToFloat(c.b);p[i].info=uvec4(c.a.zw,t,ty);float launched_speed=length(p[i].pv.zw);if(launched_speed<0.00001)launched_speed=ty==2u?par[3].z:par[3].y;p[i].geom=vec4(ty==3u?par[5].x:par[4].x,ty==3u?threshold():launched_speed,p[i].pv.xy);p[i].aux=uvec4(0u,ty==3u?0u:hash32(i+stat[7]),0u,0u);if(ty==3u){p[i].geom.x=ball_radius(i);next_id[i]=floatBitsToInt(dot(p[i].pv.zw,p[i].pv.zw)>0.0000001?atan(p[i].pv.w,p[i].pv.z):0.0);}return true;}
 // 淘汰后只允许带明确死亡余波标记的大球；异步通知到达前的普通输出不能继续生产。
 if(op>=1u&&op<=5u&&team[t].life.x==2u&&!(op==2u&&(c.b.z&1u)!=0u)){stat[28]++;return true;}
 if(op==1u){if(team[t].life.x!=2u){if(!can_add64(team[t].shield_gun.xy,c.a.zw)){atomicOr(stat[15],1u);return false;}team[t].shield_gun.xy=add64(team[t].shield_gun.xy,c.a.zw);}return true;}
 if(op==2u)return spawn(t,3u,c.a.zw,random01(c.b.x+stat[7]+t*241u+uint(par[0].w))*TAU,c.b.x);
 if(op==3u){if(!zero64(team[t].storm_sniper.zw)||team[t].misc.y!=0u)return false;team[t].storm_sniper.zw=c.a.zw;team[t].misc.x=floatBitsToUint(random01(c.b.x+stat[7]+t*37u+uint(par[0].w))*TAU);team[t].visual.w=pc.clock.y;team[t].misc.y=1u;return true;}
 if(op==4u){uvec2 reserve=add64(team[t].storm_sniper.xy,team[t].shield_gun.zw);if(!can_add64(reserve,c.a.zw)){atomicOr(stat[15],1u);return false;}team[t].storm_sniper.xy=add64(team[t].storm_sniper.xy,c.a.zw);return true;}
 if(op==5u){if(team[t].life.x!=2u){uvec2 reserve=add64(team[t].storm_sniper.xy,team[t].shield_gun.zw);if(!can_add64(reserve,c.a.zw)){atomicOr(stat[15],1u);return false;}team[t].shield_gun.zw=add64(team[t].shield_gun.zw,c.a.zw);}return true;}
 return true;
}
// 普通粒子按出生时的模拟进程收取完整弹药成本；旧粒子的能量不追溯更新。
// 该成本仍是整数能量，绝不把库存的不足一发部分强行变成弱粒子。
uint ordinary_shot_cost_at(float at_time) {
 float cost=1.0+floor(max(at_time-max(par[13].x,0.0),0.0)*max(par[13].y,0.0));
 return uint(clamp(cost,1.0,4294967040.0));
}
uint ordinary_shot_cost() {return ordinary_shot_cost_at(pc.clock.y);}
// visual.xyz = 最近索敌模拟时间 / 当前目标角度 / 模式(0安全旋转,1补领土,2..3近身威胁)。
// misc.zw用于核心保命通知，不能拿来缓存机枪状态。
// accounting.x / life.w 保存上一子步并行归约出的偶/奇索引威胁候选；不承载弹药或死亡状态。
// 键的高12位为反向威胁评分、低20位为粒子索引（容量上限1000000），UINT_MAX表示空。
float gun_projectile_score(uint t,uint i,vec2 center,float range) {
 if(p[i].info.w==0u||p[i].info.w==3u||p[i].info.z==t)return -1.0;
 vec2 delta=p[i].pv.xy-center;
 if(any(greaterThan(abs(delta),vec2(range))))return -1.0;
 float dist_squared=dot(delta,delta);if(dist_squared>range*range)return -1.0;
 float dist=sqrt(dist_squared);
 float clearance=dist-p[i].geom.x-team[t].core.z;
 float approach=-dot(delta,p[i].pv.zw)/max(dist,1.0);
 if(approach<=0.0&&clearance>20.0)return -1.0;
 float urgency=clamp(1.0-max(clearance,0.0)/range,0.0,1.0);
 return 0.20+0.65*urgency+0.20*clamp(approach/max(par[3].y,1.0),0.0,1.0)+(p[i].info.w==2u?0.35:0.0);
}
void consider_gun_projectile(uint t,uint i,vec2 center,float range,inout float best,inout vec2 target) {
 float score=gun_projectile_score(t,i,center,range);
 if(score>best){best=score;target=p[i].pv.xy;}
}
void summarize_gun_projectile(uint i) {
 float range=min(160.0,world()*0.15625);
 for(uint t=0u;t<4u;t++){
  if(t==p[i].info.z||team[t].life.x==2u)continue;
  float score=gun_projectile_score(t,i,team[t].core.xy,range);if(score<0.0)continue;
  uint reversed_score=4095u-uint(clamp(score/1.4,0.0,1.0)*4095.0+0.5);
  uint key=(reversed_score<<20)|i;
  if((i&1u)==0u)atomicMin(team[t].accounting.x,key);else atomicMin(team[t].life.w,key);
 }
}
void refresh_gun_aim(uint t) {
 // 每个有弹药的模拟子步重新判断，不保留锁定角度的计时窗口。
 team[t].visual.x=pc.clock.y;
 vec2 center=team[t].core.xy;float best_threat=-1.0;vec2 threat_position=center;
 for(uint b=cap();b<total();b++)if(p[b].info.w==3u&&p[b].info.z!=t){
  vec2 delta=p[b].pv.xy-center;float dist=length(delta);
  float clearance=dist-p[b].geom.x-team[t].core.z;
  float approach=dot(delta,p[b].pv.zw)/max(dist,1.0);
  if(clearance>world()*0.32||(approach>=0.0&&clearance>world()*0.08))continue;
  float urgency=clamp(1.0-clearance/(world()*0.32),0.0,1.0);
  float score=urgency+0.15*clamp(-approach/200.0,0.0,1.0);
  if(score>best_threat){best_threat=score;threat_position=p[b].pv.xy+p[b].pv.zw*min(0.12,dist/max(par[3].y,1.0));}
 }
 // 空间构建时并行选出威胁，每个模拟子步只重评两个候选，不串行遍历附近链表。
 // 碰撞/占地可能已消耗候选，必须再检查当前存活与接近方向；下一子步重新归约。
 float query_radius=min(160.0,world()*0.15625);
 uint even_key=team[t].accounting.x,odd_key=team[t].life.w;
 if(even_key!=0xffffffffu){uint index=even_key&0xfffffu;if(index<cap())consider_gun_projectile(t,index,center,query_radius,best_threat,threat_position);}
 if(odd_key!=0xffffffffu){uint index=odd_key&0xfffffu;if(index<cap())consider_gun_projectile(t,index,center,query_radius,best_threat,threat_position);}
 if(best_threat>=0.0){vec2 delta=threat_position-center;team[t].visual.y=atan(delta.y,delta.x);team[t].visual.z=2.0+clamp(best_threat,0.0,1.0);return;}
 // 只查核心附近可实际发射到达的环带，不为每一发重复查询整张领土。
 float begin=max(team[t].core.z,shield_radius(t))+par[4].x+5.0;
 float best=0.0;float result=team[t].clocks.z;
 for(uint k=0u;k<16u;k++){
  float angle=team[t].clocks.z+float(k)*TAU/16.0;vec2 ray=direction(angle);float score=0.0;
  for(uint d=0u;d<5u;d++){
   vec2 q=center+ray*(begin+float(d)*world()*0.035);
   if(any(lessThan(q,vec2(0.0)))||any(greaterThanEqual(q,vec2(world()))))continue;
   if(owner[territory_index(q)]!=t)score+=1.0/(1.0+float(d));
  }
  if(score>0.0){score+=0.035*cos(angle-team[t].clocks.z);if(score>best){best=score;result=angle;}}
 }
 team[t].visual.y=result;team[t].visual.z=best>0.0?1.0:0.0;
}
// 自由射击连续旋转；补地和防守仅连续转向目标，不再把相邻子弹随机扇开。
float gun_turn(uint t,float heading,float dt) {
 float rotation=max(par[3].x,0.0);float mode=team[t].visual.z;
 if(mode<0.5)return rotation*dt;
 float difference=atan(sin(team[t].visual.y-heading),cos(team[t].visual.y-heading));
 // 转向速率为弧度/模拟秒；保持逐发平滑衔接，防守和补地更快响应。
 float slew=mode>=2.0?max(rotation*4.0,24.0):max(rotation*2.0,10.0);
 return clamp(difference,-slew*dt,slew*dt);
}
void prepare() {
 for(uint n=1028u;n<1036u;n++){Command c=command[n];if(c.a.x!=0u&&execute_command(c))command[n].a.x=0u;}
 for(uint t=0u;t<4u;t++){Command c=command[1024u+t];if(c.a.x==6u)resolve_rescue(c);command[1024u+t].a.x=0u;}
 uint command_head=stat[4];uint queued=pc.control.z-command_head;uint pending_count=0u;uvec2 pending_energy=uvec2(0u);
 // 有容量的命令可以越过等待中的大球/狙击命令；只回收已完成的连续前缀。
 for(uint n=0u;n<min(queued,1024u);n++){uint slot=(command_head+n)%1024u;Command c=command[slot];if(c.a.x!=0u){if(execute_command(c))command[slot].a.x=0u;else {pending_count++;if(c.a.x<=5u)pending_energy=add64(pending_energy,c.a.zw);}}}
 while(command_head!=pc.control.z&&command[command_head%1024u].a.x==0u)command_head++;
 stat[4]=command_head;stat[5]=pending_count;stat[25]=pending_energy.x;stat[26]=pending_energy.y;stat[27]=pc.control.z-command_head;
 update_shields();uint step_budget=max(uint(par[6].w),1u);uint budget=step_budget;uvec2 shot_energy=uvec2(ordinary_shot_cost(),0u);
 uint gun_quota=max(step_budget/8u,1u);uint ring_size=uint(clamp(par[13].z,1.0,512.0));
 for(uint order=0u;order<4u;order++){uint t=(order+stat[7])%4u;
  float dt=max(pc.clock.x,0.0);float phase=clamp(team[t].clocks.y,0.0,0.999999);
  float heading=team[t].clocks.z;
  if(team[t].life.x!=2u&&!less64(team[t].shield_gun.zw,uvec2(ordinary_shot_cost_at(max(pc.clock.y-dt,0.0)),0u)))refresh_gun_aim(t);
  float turn=gun_turn(t,heading,dt);team[t].clocks.z=mod(heading+turn+TAU,TAU);
  // 恒定基础射速，威胁加速仍保留；成本增长不再额外叠加射速增长。
  float burst=team[t].visual.z>=2.0?1.0+0.8*clamp(team[t].visual.z-2.0,0.0,1.0):1.0;
  float rate=max(par[2].z,0.0)*burst;
  float scheduled=phase+rate*dt;
  uint due=uint(floor(scheduled));
  // 无弹药/无槽时不积攒整发额度，避免解除阻塞后补发成一截一截；弹药仍全部保留。
  team[t].clocks.y=team[t].life.x!=2u&&rate>0.0?fract(scheduled):0.0;
  // 聚能狙击仍是一颗真实飞行弹丸，不改成即时激光。
  if(team[t].misc.y==1u&&pc.clock.y-team[t].visual.w>=par[12].y){
   if(spawn(t,2u,team[t].storm_sniper.zw,uintBitsToFloat(team[t].misc.x),hash32(stat[7]+t*97u))){team[t].storm_sniper.zw=uvec2(0u);team[t].misc.y=0u;}
  }
  // 极高自定义射速触及预算时，也把可发的真实子弹均匀排在整段时间内。
  uint gun_limit=min(due,min(gun_quota,budget));uint gun_shots=0u;
  while(budget>0u&&gun_shots<gun_limit&&team[t].life.x!=2u&&rate>0.0){
   float ordinal=gun_limit<due?floor((float(gun_shots)+0.5)*float(due)/float(gun_limit)):float(gun_shots);
   float shot_offset=clamp((ordinal+1.0-phase)/rate,0.0,dt);
   float age=max(dt-shot_offset,0.0);
   float shot_angle=heading+(dt>0.0?turn*shot_offset/dt:0.0);
   uvec2 e=uvec2(ordinary_shot_cost_at(max(pc.clock.y-dt+shot_offset,0.0)),0u);
   uvec2 available=team[t].shield_gun.zw;if(less64(available,e))break;
   if(!spawn_timed(t,1u,e,shot_angle,hash32(stat[7]*192u+budget+t*97u),age))break;
   team[t].shield_gun.zw=sub64(available,e);gun_shots++;budget--;
  }
 }
 // 先服务四队本步机枪，避免某队风暴抢完预算造成后续阵营的机枪断成短段。
 // 每队机枪最多使用1/8总预算，四队全速时仍为风暴保留至少一半。
 for(uint order=0u;order<4u;order++){uint t=(order+stat[7])%4u;
  // accounting.yzw = 本圈总发数 / 下一发角序 / 圈序；clocks.w = 下圈最早时间。
  // 槽位或子步预算不足时保留角序，下次接着发，绝不丢弃库存。
  if(team[t].accounting.y==0u&&pc.clock.y+0.000001>=team[t].clocks.w&&!less64(team[t].storm_sniper.xy,shot_energy)){
   uvec2 remaining=team[t].storm_sniper.xy;uint count=0u;
   while(count<ring_size&&!less64(remaining,shot_energy)){remaining=sub64(remaining,shot_energy);count++;}
   team[t].accounting.y=count;team[t].accounting.z=0u;
  }
  uint storm_shots=0u;
  while(budget>0u&&storm_shots<ring_size&&team[t].accounting.y>0u){
   uvec2 available=team[t].storm_sniper.xy;if(less64(available,shot_energy))break;
   float ring_phase=random01(hash32(team[t].accounting.w+t*0x9e3779b9u))*TAU;
   float angle=ring_phase+TAU*float(team[t].accounting.z)/float(team[t].accounting.y);
   if(!spawn(t,1u,shot_energy,angle,hash32(team[t].accounting.w*521u+team[t].accounting.z+t*97u)))break;
   team[t].storm_sniper.xy=sub64(available,shot_energy);team[t].accounting.z++;storm_shots++;budget--;
   if(team[t].accounting.z>=team[t].accounting.y){team[t].accounting.y=0u;team[t].accounting.z=0u;team[t].accounting.w++;team[t].clocks.w=pc.clock.y+max(par[13].w,0.015);break;}
  }
 }stat[7]++;stat[19]=floatBitsToUint(pc.clock.y);
}
void initialize(uint i) {
 if(i<total()){p[i].pv=vec4(0.0);p[i].info=uvec4(0u);p[i].geom=vec4(0.0);p[i].aux=uvec4(0u);}
 if(i<cols()*cols()*4u)head[i]=-1;if(i<total())next_id[i]=i<cap()?-1:floatBitsToInt(0.0);
 if(i<terrain_size()*terrain_size()){uint x=i%terrain_size(),y=i/terrain_size();owner[i]=(x>=terrain_size()/2u?1u:0u)+(y>=terrain_size()/2u?2u:0u);}
 if(i<render_size()*render_size())pixels[i]=0u;if(i<64u){stat[i]=i==30u?0xffffffffu:0u;if(i>=8u&&i<12u){uint t=i-8u;uint half_n=terrain_size()/2u;uint width=(t&1u)!=0u?terrain_size()-half_n:half_n;uint height=(t&2u)!=0u?terrain_size()-half_n:half_n;stat[i]=width*height;}}
 if(i<1036u){command[i].a=uvec4(0u);command[i].b=uvec4(0u);}
 if(i<4u){team[i].shield_gun=floatBitsToUint(par[9]);team[i].storm_sniper=uvec4(0u);team[i].life=uvec4(0u,0u,0u,0xffffffffu);team[i].clocks=vec4(0.0,0.0,float(i)*TAU/4.0,0.0);team[i].accounting=uvec4(0xffffffffu,0u,0u,0u);team[i].core=vec4((i==0u?par[10].xy:(i==1u?par[10].zw:(i==2u?par[11].xy:par[11].zw))),par[5].w,par[8].y*par[4].z);team[i].core.w=shield_radius(i);team[i].misc=uvec4(0u);team[i].visual=vec4(0u);}
}
void move_particle(uint i) {if(i>=total()||p[i].info.w==0u)return;maintain_motion(i);float r=p[i].info.w==3u?ball_radius(i):par[4].x;p[i].geom.x=r;p[i].geom.zw=p[i].pv.xy;
 float move_dt=pc.clock.x;
 if(p[i].info.w==1u&&(p[i].aux.z&0x80000000u)!=0u){move_dt=clamp(uintBitsToFloat(p[i].aux.y),0.0,max(pc.clock.x,0.0));}
 vec2 pos=p[i].pv.xy+p[i].pv.zw*move_dt;vec2 vel=p[i].pv.zw;float wall_e=p[i].info.w==3u?contact_restitution(i):1.0; // 有限步长反射，保持撞墙后真实位置在边界内。
 for(int axis=0;axis<2;axis++){if(pos[axis]<r){pos[axis]=2.0*r-pos[axis];vel[axis]=abs(vel[axis])*wall_e;}if(pos[axis]>world()-r){pos[axis]=2.0*(world()-r)-pos[axis];vel[axis]=-abs(vel[axis])*wall_e;}}
 p[i].pv=vec4(clamp(pos,vec2(r),vec2(world()-r)),vel);if(p[i].info.w==3u)maintain_motion(i);
 for(uint t=0u;t<4u;t++){float distance_core=distance(p[i].pv.xy,team[t].core.xy);if(distance_core>team[t].core.w+r+2.0)p[i].aux.x&=~(1u<<t);
  // 保命请求对应的攻击在握手期间保持接触保护，补盾后须先离开新护盾才可重新结算。
  if(team[t].life.x==2u||(team[t].life.x==0u&&distance_core>team[t].core.w+r+2.0))p[i].aux.z&=~(1u<<t);}
}
// 同色弹性碰撞可能提高单颗速度；超出3×3覆盖界限的粒子进入独立链，
// 在串行事件阶段做完整候选查询，绝不夹速或漏掉快速碰撞。aux.w锁定本步分类。
bool fast_particle(uint i) {float limit=min(4.0,(par[1].y-2.0*par[4].x)*0.5);return distance(p[i].pv.xy,p[i].geom.zw)>limit+0.00001;}
void build_space(uint i) {if(i>=cap()||p[i].info.w==0u)return;
 // AI摘要与空间链同一并行pass构建；快粒子也必须先参与，绝不影响碰撞候选。
 summarize_gun_projectile(i);
 if(fast_particle(i)){p[i].aux.w=1u;next_id[i]=int(atomicExchange(stat[30],i));return;}
 p[i].aux.w=0u;uint c=p[i].info.z*cols()*cols()+cell_index(p[i].pv.xy);next_id[i]=atomicExchange(head[c],int(i));}
// 9色中心格的3×3邻域互不相交，单线程负责一个中心格，故没有两个线程修改同一粒子。
// 链表遍历直到-1，不存在32/64粒子截断。pair按索引排序只结算一次。
// 机械质量与弹药账本分离：几何面积及对数能量只提供有界的机械修正。
// 子步内出生的机枪弹与旧粒子相遇时，扫掠轨迹从双方都已出生的时刻开始。
float motion_start(uint i) {return p[i].info.w==1u&&(p[i].aux.z&0x80000000u)!=0u?max(pc.clock.x-uintBitsToFloat(p[i].aux.y),0.0):0.0;}
vec2 motion_from(uint i,float at_time) {
 float start=motion_start(i);float duration=pc.clock.x-start;
 float fraction=duration>0.0000001?clamp((at_time-start)/duration,0.0,1.0):1.0;
 return mix(p[i].geom.zw,p[i].pv.xy,fraction);
}
// 普通粒子之间始终等质量，出生弹药成本不会令己方粒子碰撞产生额外能量。
float contact_mass(uint i) {
 if(p[i].info.w!=3u)return 1.0;
 float radius_ratio=p[i].geom.x/max(par[5].x,1.0);
 float logarithm=log2(1.0+value64(energy(i)));
 return 8.0*clamp(radius_ratio*radius_ratio,1.0,144.0)+24.0*logarithm/(12.0+logarithm);
}
float contact_hardness(uint i) {
 if(p[i].info.w!=3u)return 1.0;
 float size=clamp((p[i].geom.x-par[5].x)/max(par[5].z-par[5].x,1.0),0.0,1.0);
 float logarithm=log2(1.0+value64(energy(i)));
 return clamp(1.0-0.55*size-0.25*logarithm/(12.0+logarithm),0.20,1.0);
}
float contact_restitution(uint i) {return p[i].info.w==3u?0.26+0.62*contact_hardness(i):1.0;}
// floor(E*n/1024)，全程整数运算，浮点参数只选择比例，绝不重构弹药值。
uvec2 bounded_energy_fraction(uvec2 e,float fraction) {
 uint numerator=uint(clamp(fraction,0.0,1.0)*1024.0);
 uvec2 quotient=uvec2((e.x>>10u)|(e.y<<22u),e.y>>10u);
 uint high,low;umulExtended(quotient.x,numerator,high,low);
 uint remainder=((e.x&1023u)*numerator)>>10u;
 uint result_low=low+remainder;
 return uvec2(result_low,quotient.y*numerator+high+uint(result_low<low));
}
uvec2 impact_wear(uvec2 available,float fraction) {
 if(zero64(available))return uvec2(0u);
 uvec2 portion=bounded_energy_fraction(available,fraction);
 return zero64(portion)?uvec2(1u,0u):min64(available,portion);
}
void resolve_pair(uint a,uint b) {
 if(p[a].info.w==0u||p[b].info.w==0u)return;
 // 狙击不参与粒子的实体碰撞：己方直接穿过，敌方仅结算能量。
 if(p[a].info.z==p[b].info.z&&(p[a].info.w==2u||p[b].info.w==2u||par[12].w<0.5))return;
 vec2 d=p[b].pv.xy-p[a].pv.xy;float rr=p[a].geom.x+p[b].geom.x;float d2=dot(d,d);
 if(d2>=rr*rr){
  // 候选来自邻格或高速回退；先排除扫掠包围盒不相交的远距离对象。
  if(any(lessThan(max(p[a].geom.zw,p[a].pv.xy)+vec2(rr),min(p[b].geom.zw,p[b].pv.xy)))||any(lessThan(max(p[b].geom.zw,p[b].pv.xy)+vec2(rr),min(p[a].geom.zw,p[a].pv.xy))))return;
  float common_start=max(motion_start(a),motion_start(b));vec2 old=motion_from(b,common_start)-motion_from(a,common_start);vec2 rel=d-old;float dd=dot(rel,rel);float time=dd>0.00001?clamp(-dot(old,rel)/dd,0.0,1.0):1.0;vec2 near=old+rel*time;if(dot(near,near)>=rr*rr)return;
  d=dot(near,near)>0.000001?near:normal_or(old,vec2(1,0))*0.0001;d2=dot(d,d);
 }
 atomicAdd(stat[2],1u);
 if(p[a].info.z==p[b].info.z){
  vec2 n=normal_or(d,direction(float((a*31u+b*17u)%628u)*0.01));
  float separation=max(rr-dot(p[b].pv.xy-p[a].pv.xy,n),0.0)*0.5+0.001;
  p[a].pv.xy-=n*separation;p[b].pv.xy+=n*separation;
  vec2 original_a=p[a].pv.zw,original_b=p[b].pv.zw;
  vec2 outgoing_a=original_a,outgoing_b=original_b;
  float approaching=dot(original_b-original_a,n);
  if(approaching<0.0){outgoing_a+=approaching*n;outgoing_b-=approaching*n;}
  // 碰撞只改变航向，逐颗保持出生速度；正交等质量碰撞的零速度解改为沿接触面向外离开。
  if(dot(outgoing_a,outgoing_a)<0.00000001)outgoing_a=-n;
  if(dot(outgoing_b,outgoing_b)<0.00000001)outgoing_b=n;
  p[a].pv.zw=fixed_particle_velocity(a,outgoing_a,original_a);
  p[b].pv.zw=fixed_particle_velocity(b,outgoing_b,original_b);
  confine_after_contact(a);confine_after_contact(b);
  return;
 }
 if(p[a].info.w==1u&&p[b].info.w==1u){
  // 新经济规则：一颗普通粒子对应一次交战/占地机会，不比较出生年代的成本。
  uvec2 ea=energy(a),eb=energy(b);set_energy(a,uvec2(0u));set_energy(b,uvec2(0u));consumed_atomic(ea);consumed_atomic(eb);return;
 }
 // 狙击仍是真实飞行的聚能弹：等量抵消后，剩余能量沿原方向继续飞行。
 uvec2 cancel=min64(energy(a),energy(b));spend(a,cancel);spend(b,cancel);consumed_atomic(cancel);consumed_atomic(cancel);
}
void collision_cell(uint index) {uvec2 offset=uvec2(pc.control.y%3u,pc.control.y/3u);uint phase_width=(cols()-offset.x+2u)/3u;
 uint cx=(index%phase_width)*3u+offset.x,cy=(index/phase_width)*3u+offset.y;if(cx>=cols()||cy>=cols())return;uint c=cy*cols()+cx;uint occupancy=0u;
 // 四条阵营链均参与，己方做真实弹性碰撞；索引排序使同一对子步内只处理一次。
 for(uint own=0u;own<4u;own++){int a=head[own*cols()*cols()+c];while(a>=0){occupancy++;uint ai=uint(a);if(p[ai].info.w==0u){a=next_id[ai];continue;}
  for(int dy=-1;dy<=1&&p[ai].info.w!=0u;dy++)for(int dx=-1;dx<=1&&p[ai].info.w!=0u;dx++){ivec2 q=ivec2(cx,cy)+ivec2(dx,dy);if(any(lessThan(q,ivec2(0)))||any(greaterThanEqual(q,ivec2(cols()))))continue;
   uint cell=uint(q.y)*cols()+uint(q.x);for(uint faction=0u;faction<4u&&p[ai].info.w!=0u;faction++){if(faction==own&&par[12].w<0.5)continue;int b=head[faction*cols()*cols()+cell];while(b>=0&&p[ai].info.w!=0u){if(uint(b)>ai)resolve_pair(ai,uint(b));b=next_id[uint(b)];}}
  }a=next_id[ai];
 }}atomicMax(stat[6],occupancy);
}
// 以下事件由单GPU invocation顺序处理。它是显式性能取舍，不是CPU物理；避免领土/护盾多写竞态。
bool swept_hit(vec2 from,vec2 to,vec2 center,float radius,out float hit_t,out vec2 hit_normal) {vec2 d=to-from;vec2 m=from-center;float c=dot(m,m)-radius*radius;
 if(c<=0.0){hit_t=0.0;hit_normal=normal_or(m,vec2(1,0));return true;}float a=dot(d,d);if(a<1e-9)return false;float b=dot(m,d);float disc=b*b-a*c;if(disc<0.0)return false;float t=(-b-sqrt(disc))/a;if(t<0.0||t>1.0)return false;hit_t=t;hit_normal=normal_or(from+d*t-center,vec2(1,0));return true;}
void reflect_contact(uint i,vec2 center,float radius,vec2 n) {p[i].pv.xy=center+n*(radius+0.08);float inward=dot(p[i].pv.zw,n);if(inward<0.0)p[i].pv.zw-=(1.0+contact_restitution(i))*inward*n;}
void terrain_events(uint i);
void shield_core_events(uint i) {if(p[i].info.w==0u)return;uint own=p[i].info.z;int target=-1;float first_time=2.0;vec2 normal=vec2(1,0);float target_radius=0.0;bool target_shield=false;
 // 先找到整条运动段最早的实体接触，再把领土扫描截断至接触点。
 // 路上已经耗尽的粒子绝不可能隔空伤盾或触发核心事件。
 for(uint t=0u;t<4u;t++){if(t==own||team[t].life.x==2u)continue;bool shield=!zero64(team[t].shield_gun.xy);float radius=shield?shield_radius(t):team[t].core.z;float hit_t;vec2 hit_normal;
  if(swept_hit(p[i].geom.zw,p[i].pv.xy,team[t].core.xy,radius+p[i].geom.x,hit_t,hit_normal)&&hit_t<first_time){target=int(t);first_time=hit_t;normal=hit_normal;target_radius=radius;target_shield=shield;}}
 if(target>=0)p[i].pv.xy=mix(p[i].geom.zw,p[i].pv.xy,first_time);
 terrain_events(i);if(target<0||p[i].info.w==0u)return;
 uint t=uint(target);float approaching=max(-dot(p[i].pv.zw,normal),0.0);bool big=p[i].info.w==3u;
 reflect_contact(i,team[t].core.xy,target_radius+p[i].geom.x,normal);
 if(target_shield){if((p[i].aux.z&(1u<<t))!=0u){p[i].aux.z&=~(1u<<t);p[i].aux.x|=1u<<t;return;}
  if((p[i].aux.x&(1u<<t))==0u){
   uvec2 available=min64(energy(i),team[t].shield_gun.xy);uvec2 cancel=available;
   if(big){
    // 软大球撞盾只在一次新接近时磨损，持续贴住不会逐子步重复扣光能量。
    float impact=clamp(approaching/max(par[3].w,40.0),0.0,1.0);
    cancel=approaching>1.0?impact_wear(available,0.16+0.50*impact+0.12*(1.0-contact_hardness(i))):uvec2(0u);
   }
   team[t].shield_gun.xy=sub64(team[t].shield_gun.xy,cancel);spend(i,cancel);consumed(cancel);consumed(cancel);p[i].aux.x|=1u<<t;
  }return;}
 // 同一接触只走盾或核心中的一条出口；PENDING_RESCUE提供事件保护。
 if(team[t].life.x==0u){if(pc.clock.y+0.000001<team[t].clocks.x)eliminate(t);else {team[t].life.x=1u;team[t].life.y++;team[t].misc.z=p[i].info.x;team[t].misc.w=p[i].info.y;}}
 if(team[t].life.x==1u)p[i].aux.z|=1u<<t;
}
bool ball_contact_mask(uint a,uint b) {uint slot=b-cap();uint mask=1u<<(slot&31u);return slot<32u?(p[a].aux.y&mask)!=0u:(p[a].aux.w&mask)!=0u;}
void set_ball_contact_mask(uint a,uint b,bool touching) {uint slot=b-cap();uint mask=1u<<(slot&31u);if(slot<32u){if(touching)p[a].aux.y|=mask;else p[a].aux.y&=~mask;}else {if(touching)p[a].aux.w|=mask;else p[a].aux.w&=~mask;}}
// 事件invocation私有；先按实际能量累积全部冲量，再对每球的整步加速度平滑限幅。
// 不对单颗弹丸限幅，因此相同总弹药/方向不会仅因粒子成本变化而失去推动力。
vec2 pending_ball_push[64];
// 4×4粗网格，每格两uint涵盖64个大球；复用未用于统计的stat[32..63]。
// 单事件线程写入，无额外GPU缓冲/同步。旧掩码不移除，增长只增加候选，绝不漏碰撞。
bool coarse_balls_ready=false;
void index_coarse_ball(uint i) {
 if(!coarse_balls_ready||p[i].info.w!=3u)return;
 float cell_width=world()*0.25;float radius=p[i].geom.x;
 ivec2 low=clamp(ivec2(floor((min(p[i].geom.zw,p[i].pv.xy)-vec2(radius))/cell_width)),ivec2(0),ivec2(3));
 ivec2 high=clamp(ivec2(floor((max(p[i].geom.zw,p[i].pv.xy)+vec2(radius))/cell_width)),ivec2(0),ivec2(3));
 uint slot=i-cap();uint word=slot/32u;uint bit=1u<<(slot&31u);
 for(int y=low.y;y<=high.y;y++)for(int x=low.x;x<=high.x;x++)stat[32u+(uint(y)*4u+uint(x))*2u+word]|=bit;
}
uvec2 coarse_ball_candidates(uint i) {
 float cell_width=world()*0.25;float radius=p[i].geom.x;
 ivec2 low=clamp(ivec2(floor((min(p[i].geom.zw,p[i].pv.xy)-vec2(radius))/cell_width)),ivec2(0),ivec2(3));
 ivec2 high=clamp(ivec2(floor((max(p[i].geom.zw,p[i].pv.xy)+vec2(radius))/cell_width)),ivec2(0),ivec2(3));
 uvec2 result=uvec2(0u);
 for(int y=low.y;y<=high.y;y++)for(int x=low.x;x<=high.x;x++){uint index=32u+(uint(y)*4u+uint(x))*2u;result|=uvec2(stat[index],stat[index+1u]);}
 return result;
}
void projectile_ball_impulse(uint projectile,uint ball,vec2 normal,float approaching) {
 if(approaching<=0.0)return;
 float transfer=p[projectile].info.z==p[ball].info.z?0.22:0.35;
 vec2 relative_velocity=p[projectile].pv.zw-p[ball].pv.zw;
 pending_ball_push[ball-cap()]+=transfer*value64(energy(projectile))*relative_velocity;
}
bool swept_ball_contact(uint a,uint b,out float time,out vec2 normal) {
 float r=p[a].geom.x+p[b].geom.x;
 // 包围盒拒绝后才计算精确TOI；不依赖碰撞修正后可能过期的空间网格。
 if(any(lessThan(max(p[a].geom.zw,p[a].pv.xy)+vec2(r),min(p[b].geom.zw,p[b].pv.xy)))||any(lessThan(max(p[b].geom.zw,p[b].pv.xy)+vec2(r),min(p[a].geom.zw,p[a].pv.xy))))return false;
 float start=max(motion_start(a),motion_start(b));
 bool hit=swept_hit(motion_from(a,start)-motion_from(b,start),p[a].pv.xy-p[b].pv.xy,vec2(0),r,time,normal);
 if(hit){float duration=max(pc.clock.x-motion_start(a),0.0000001);time=clamp((start-motion_start(a)+time*(pc.clock.x-start))/duration,0.0,1.0);}
 return hit;
}
float first_nonfriendly_cell_time(uint i,float stop_time) {
 uint n=terrain_size();float unit=world()/float(n);vec2 a=p[i].geom.zw,b=p[i].pv.xy;vec2 ray=b-a;
 ivec2 cell=clamp(ivec2(floor(a/unit)),ivec2(0),ivec2(int(n)-1));
 ivec2 last=clamp(ivec2(floor(mix(a,b,stop_time)/unit)),ivec2(0),ivec2(int(n)-1));
 if(owner[uint(cell.y)*n+uint(cell.x)]!=p[i].info.z)return 0.0;
 ivec2 step_dir=ivec2(sign(ray));vec2 t_delta=vec2(1e30),t_max=vec2(1e30);
 for(int axis=0;axis<2;axis++)if(abs(ray[axis])>0.0000001){t_delta[axis]=abs(unit/ray[axis]);float boundary=float(cell[axis]+(step_dir[axis]>0?1:0))*unit;t_max[axis]=(boundary-a[axis])/ray[axis];}
 while(any(notEqual(cell,last))){float crossing=min(t_max.x,t_max.y);if(crossing>stop_time+0.000001)break;
  bool step_x=t_max.x<=t_max.y;bool step_y=t_max.y<=t_max.x;
  if(step_x){cell.x+=step_dir.x;t_max.x+=t_delta.x;}if(step_y){cell.y+=step_dir.y;t_max.y+=t_delta.y;}
  if(any(lessThan(cell,ivec2(0)))||any(greaterThanEqual(cell,ivec2(n))))break;
  if(owner[uint(cell.y)*n+uint(cell.x)]!=p[i].info.z)return max(crossing,0.0);
 }
 return 2.0;
}
float first_shield_core_time(uint i) {
 float first=2.0;
 for(uint t=0u;t<4u;t++){if(t==p[i].info.z||team[t].life.x==2u)continue;
  float radius=zero64(team[t].shield_gun.xy)?team[t].core.z:shield_radius(t);float hit_time;vec2 normal;
  if(swept_hit(p[i].geom.zw,p[i].pv.xy,team[t].core.xy,radius+p[i].geom.x,hit_time,normal))first=min(first,hit_time);
 }
 return first;
}
void particle_ball_pair(uint a,uint b) {
 if(p[a].info.w==0u||p[b].info.w==0u)return;
 bool both_big=p[a].info.w==3u&&p[b].info.w==3u;
 float r=p[a].geom.x+p[b].geom.x;
 float time;vec2 n;bool hit=swept_ball_contact(a,b,time,n);
 if(!hit){if(both_big){set_ball_contact_mask(a,b,false);set_ball_contact_mask(b,a,false);}return;}
 stat[2]++;float relative=dot(p[a].pv.zw-p[b].pv.zw,n);float approaching=max(-relative,0.0);
 if(!both_big){
  // 事件调用顺序保证a是普通/狙击粒子，b是大球。
  if(p[a].info.z==p[b].info.z){
   uvec2 incoming=energy(a);if(!can_add64(energy(b),incoming)){atomicOr(stat[15],1u);return;}
   projectile_ball_impulse(a,b,n,approaching);set_energy(b,add64(energy(b),incoming));set_energy(a,uvec2(0u));p[b].geom.x=ball_radius(b);index_coarse_ball(b);return;
  }
  projectile_ball_impulse(a,b,n,approaching);uvec2 incoming=energy(a);uvec2 cancel=min64(incoming,energy(b));
  spend(b,cancel);consumed(cancel);
  if(p[a].info.w==1u){set_energy(a,uvec2(0u));consumed(incoming);}
  else {spend(a,cancel);consumed(cancel);if(p[a].info.w!=0u)reflect_contact(a,p[b].pv.xy,r,n);}
  if(p[b].info.w!=0u){p[b].geom.x=ball_radius(b);index_coarse_ball(b);}return;
 }
 bool fresh=!(ball_contact_mask(a,b)&&ball_contact_mask(b,a));set_ball_contact_mask(a,b,true);set_ball_contact_mask(b,a,true);
 float ma=contact_mass(a),mb=contact_mass(b);float restitution=min(contact_restitution(a),contact_restitution(b));
 if(approaching>0.0){float impulse=(1.0+restitution)*approaching/(1.0/ma+1.0/mb);p[a].pv.zw+=impulse/ma*n;p[b].pv.zw-=impulse/mb*n;}
 float overlap=max(r-dot(p[a].pv.xy-p[b].pv.xy,n),0.0)+0.02;p[a].pv.xy+=n*overlap*mb/(ma+mb);p[b].pv.xy-=n*overlap*ma/(ma+mb);
 confine_after_contact(a);confine_after_contact(b);
 if(p[a].info.z!=p[b].info.z&&fresh&&approaching>1.0){
  float impact=clamp(approaching/max(par[3].w,40.0),0.0,1.0);float disparity=1.0-min(ma,mb)/max(ma,mb);
  float softness_difference=abs(contact_hardness(a)-contact_hardness(b));
  float fraction=clamp(0.14+0.44*impact+0.32*disparity+0.08*softness_difference,0.08,0.96);
  uvec2 cancel=impact_wear(min64(energy(a),energy(b)),fraction);spend(a,cancel);spend(b,cancel);consumed(cancel);consumed(cancel);
 }
 if(p[a].info.w!=0u){p[a].geom.x=ball_radius(a);index_coarse_ball(a);}if(p[b].info.w!=0u){p[b].geom.x=ball_radius(b);index_coarse_ball(b);}
}
void claim(uint i,uint index) {if(p[i].info.w==0u||owner[index]==p[i].info.z)return;
 // 普通粒子仍仅染一格；狙击和大球按占领当时的普通粒子成本逐格扣能。
 uvec2 remaining=energy(i);uvec2 cost=p[i].info.w==1u?remaining:uvec2(ordinary_shot_cost(),0u);
 if(less64(remaining,cost)){set_energy(i,uvec2(0u));consumed(remaining);return;}
 set_territory_owner(index,p[i].info.z);spend(i,cost);stat[3]++;consumed(cost);
}
void terrain_events(uint i) {if(p[i].info.w==0u)return;uint n=terrain_size();float unit=world()/float(n);vec2 a=p[i].geom.zw,b=p[i].pv.xy;
 if(p[i].info.w!=3u){
  // Amanatides/Woo DDA：精确遍历中心轨迹真正经过的每一格，无采样跳格或固定次数截断。
  ivec2 cell=clamp(ivec2(floor(a/unit)),ivec2(0),ivec2(int(n)-1));ivec2 last=clamp(ivec2(floor(b/unit)),ivec2(0),ivec2(int(n)-1));vec2 ray=b-a;ivec2 step_dir=ivec2(sign(ray));vec2 t_delta=vec2(1e30),t_max=vec2(1e30);
  for(int axis=0;axis<2;axis++)if(abs(ray[axis])>0.0000001){t_delta[axis]=abs(unit/ray[axis]);float boundary=float(cell[axis]+(step_dir[axis]>0?1:0))*unit;t_max[axis]=(boundary-a[axis])/ray[axis];}
  claim(i,uint(cell.y)*n+uint(cell.x));if(p[i].info.w==0u){p[i].pv.xy=a;return;}
  while(any(notEqual(cell,last))&&p[i].info.w!=0u){float crossing=min(t_max.x,t_max.y);bool step_x=t_max.x<=t_max.y;bool step_y=t_max.y<=t_max.x;
   if(step_x){cell.x+=step_dir.x;t_max.x+=t_delta.x;}if(step_y){cell.y+=step_dir.y;t_max.y+=t_delta.y;}
   if(any(lessThan(cell,ivec2(0)))||any(greaterThanEqual(cell,ivec2(n))))break;claim(i,uint(cell.y)*n+uint(cell.x));if(p[i].info.w==0u)p[i].pv.xy=mix(a,b,clamp(crossing+0.000001,0.0,1.0));
  }return;
 }
 // 大球扫掠胶囊逐格占领；真实归属变更按当前成本扣能，重叠扫掠不会重复扣。
 float radius=p[i].geom.x;ivec2 low=clamp(ivec2(floor((min(a,b)-vec2(radius))/unit)),ivec2(0),ivec2(int(n)-1));ivec2 high=clamp(ivec2(ceil((max(a,b)+vec2(radius))/unit)),ivec2(0),ivec2(int(n)-1));vec2 d=b-a;float dd=dot(d,d);
 for(int y=low.y;y<=high.y&&p[i].info.w!=0u;y++)for(int x=low.x;x<=high.x&&p[i].info.w!=0u;x++){vec2 point=(vec2(x,y)+0.5)*unit;float t=dd>0.000001?clamp(dot(point-a,d)/dd,0.0,1.0):0.0;if(distance(point,a+d*t)<=radius)claim(i,uint(y)*n+uint(x));}
 if(p[i].info.w!=0u)p[i].geom.x=ball_radius(i);
}
void events() {
 coarse_balls_ready=false;
 for(uint b=0u;b<64u;b++)pending_ball_push[b]=vec2(0.0);
 // 超出九色网格安全位移的少量粒子单独串行回退，不限速、不丢步、不截断候选。
 // aux.w由build_space锁定本子步分类；不能在碰撞位置修正后重新推断分类。
 uint fast=stat[30];while(fast!=0xffffffffu){uint following=uint(next_id[fast]);if(p[fast].info.w!=0u){for(uint b=0u;b<cap()&&p[fast].info.w!=0u;b++)if(b!=fast&&p[b].info.w!=0u&&(p[b].aux.w==0u||b>fast))resolve_pair(fast,b);}fast=following;}
 // ID升序快照保留原结算顺序。这里不会新生大球；被前一接触消灭的球仍由pair检查跳过。
 uvec2 active_balls=uvec2(0u);
 for(uint b=0u;b<balls();b++)if(p[cap()+b].info.w==3u)active_balls[b/32u]|=1u<<(b%32u);
 for(uint aw=0u;aw<2u;aw++){uint remaining_a=active_balls[aw];while(remaining_a!=0u){uint a=cap()+aw*32u+uint(findLSB(remaining_a));remaining_a&=remaining_a-1u;
  if(p[a].info.w==3u)for(uint bw=aw;bw<2u;bw++){uint remaining_b=bw==aw?remaining_a:active_balls[bw];while(remaining_b!=0u){uint b=cap()+bw*32u+uint(findLSB(remaining_b));remaining_b&=remaining_b-1u;if(p[b].info.w==3u)particle_ball_pair(a,b);}}
 }}
 // 大球相互位置修正完成后才建粗网格；用整个扫掠范围覆盖高速与投影修正。
 for(uint word=32u;word<64u;word++)stat[word]=0u;
 coarse_balls_ready=true;
 for(uint b=0u;b<balls();b++)if(p[cap()+b].info.w==3u)index_coarse_ball(cap()+b);
 for(uint a=0u;a<cap();a++)if(p[a].info.w!=0u){
  if(p[a].info.w==1u){
   // 普通粒子只能在第一次真实事件消耗：先比较大球TOI、领土与盾/核心的先后。
   // 因而不能越过本应染色耗尽的敌方格子，隔空为后方己方大球补充能量。
   int first_ball=-1;float first_time=2.0;uvec2 candidates=any(notEqual(active_balls,uvec2(0u)))?coarse_ball_candidates(a):uvec2(0u);
   for(uint bw=0u;bw<2u;bw++){uint remaining_b=candidates[bw];while(remaining_b!=0u){uint b=cap()+bw*32u+uint(findLSB(remaining_b));remaining_b&=remaining_b-1u;
    if(p[b].info.w==3u){float hit_time;vec2 normal;if(swept_ball_contact(a,b,hit_time,normal)&&hit_time<first_time){first_ball=int(b);first_time=hit_time;}}
   }}
   if(first_ball>=0){float blocker=min(first_nonfriendly_cell_time(a,first_time),first_shield_core_time(a));
    if(first_time+0.000001<blocker)particle_ball_pair(a,uint(first_ball));
   }
   // 立即落地真正的领土/盾事件，使后续粒子读取最新归属，不缓存失效的查询结果。
   if(p[a].info.w!=0u){shield_core_events(a);confine_after_contact(a);maintain_motion(a);}
   p[a].aux.z&=0x7fffffffu;
  }else if(any(notEqual(active_balls,uvec2(0u)))){
   // 狙击保留原有多接触及剩余能量结算方式。
   for(uint bw=0u;bw<2u&&p[a].info.w!=0u;bw++){uint remaining_b=active_balls[bw];while(remaining_b!=0u&&p[a].info.w!=0u){uint b=cap()+bw*32u+uint(findLSB(remaining_b));remaining_b&=remaining_b-1u;if(p[b].info.w==3u)particle_ball_pair(a,b);}}
  }
 }
 for(uint i=0u;i<total();i++)if(p[i].info.w!=0u&&p[i].info.w!=1u){shield_core_events(i);if(p[i].info.w!=3u){confine_after_contact(i);maintain_motion(i);}}
 for(uint b=0u;b<balls();b++){uint i=cap()+b;if(p[i].info.w!=3u)continue;
  p[i].geom.x=ball_radius(i);vec2 delta=pending_ball_push[b]/contact_mass(i);
  // 使用最大分量归一化，避免trillion级输入令length(delta)的平方溢出。
  float component=max(abs(delta.x),abs(delta.y));if(component>0.0){vec2 scaled=delta/component;float normalized_length=length(scaled);
   float maximum_change=300.0*pc.clock.x;float change=maximum_change/(1.0+(maximum_change/component)/normalized_length);
   p[i].pv.zw+=scaled*(change/normalized_length);
  }
  // 墙、盾、大球碰撞和整步机枪冲量全部结束后再补基础速度，不改变弹药账本。
  maintain_motion(i);confine_after_contact(i);maintain_motion(i);
 }
 update_shields();
}
void statistics() {
 stat[0]=0u;stat[1]=0u;stat[12]=0u;stat[13]=0u;stat[22]=0u;uvec2 normal_energy=uvec2(0u);
 for(uint i=0u;i<total();i++)if(p[i].info.w!=0u){if(p[i].info.w==3u)stat[1]++;else {stat[0]++;normal_energy=add64(normal_energy,energy(i));}}
 stat[23]=normal_energy.x;stat[24]=normal_energy.y;
 for(uint t=0u;t<4u;t++){if(team[t].life.x==1u)stat[12]|=1u<<t;if(team[t].life.x==2u)stat[13]|=1u<<t;}
 // stat[8..11]由初始化/claim/显式调试染色精确维护；这里不再扫描512²地图。
}
void splat(uint i) {if(i>=total()||p[i].info.w==0u)return;if(p[i].info.w!=3u&&random01(i)>par[7].z)return;
 uint n=render_size();float scale=float(n)/world();vec2 a=p[i].geom.zw*scale,b=p[i].pv.xy*scale;float r=max(p[i].info.w==3u?p[i].geom.x*scale:par[7].x*scale,0.8);vec2 d=b-a;float dd=dot(d,d);
 if(p[i].info.w==2u){a=b-normal_or(p[i].pv.zw,vec2(1,0))*min(22.0,length(p[i].pv.zw)*0.03)*scale;r=max(r*1.8,1.6);}else a=mix(b,a,clamp(par[7].y,0.0,1.0));
 d=b-a;dd=dot(d,d);
 ivec2 lo=max(ivec2(0),ivec2(floor(min(a,b)-r-1.0)));ivec2 hi=min(ivec2(int(n)-1),ivec2(ceil(max(a,b)+r+1.0)));uint color=p[i].info.z+1u;
 for(int y=lo.y;y<=hi.y;y++)for(int x=lo.x;x<=hi.x;x++){vec2 q=vec2(x,y)+0.5;float t=dd>0.0001?clamp(dot(q-a,b-a)/max(dot(b-a,b-a),0.0001),0.0,1.0):1.0;float dist=distance(q,mix(a,b,t));if(dist<=r){uint bright=uint(clamp(1.0-dist/max(r,0.1),0.0,1.0)*255.0);uint packed=(p[i].info.w==3u?0x1000000u:(p[i].info.w==2u?0x2000000u:0u))|(bright<<8)|color;atomicMax(pixels[uint(y)*n+uint(x)],packed);}}
}
void render(uint i) {uint n=render_size();if(i>=n*n)return;uint x=i%n,y=i/n;vec2 q=(vec2(x,y)+0.5)/float(n)*world();uint t=owner[territory_index(q)];vec3 c=t<4u?team_color(t)*0.22:vec3(0.07,0.09,0.13);
 uint tn=terrain_size();ivec2 tp=clamp(ivec2(q/world()*float(tn)),ivec2(0),ivec2(int(tn)-1));if(tp.x<int(tn)-1&&owner[uint(tp.y)*tn+uint(tp.x)+1u]!=t)c*=1.35;if(tp.y<int(tn)-1&&owner[(uint(tp.y)+1u)*tn+uint(tp.x)]!=t)c*=1.35;
 for(uint k=0u;k<4u;k++){if(team[k].life.x==2u)continue;float distance_core=distance(q,team[k].core.xy);float shield=team[k].core.w;
 if(shield>0.0){float ring=1.0-smoothstep(0.6,2.0,abs(distance_core-shield));c=mix(c,team_color(k)*0.9,ring*0.8);if(distance_core<shield)c+=team_color(k)*0.018;}
 if(distance_core<team[k].core.z){float glow=1.0-distance_core/team[k].core.z;c=team_color(k)*(0.75+0.5*glow);if(team[k].life.x==1u)c=mix(c,vec3(1),0.35+0.25*sin(pc.clock.y*15.0));}
 vec2 gun=team[k].core.xy+direction(team[k].clocks.z)*(team[k].core.z+4.0);if(distance(q,gun)<3.0)c=vec3(1.0);
 }
 uint packed=pixels[i];if(packed!=0u){uint color=(packed&255u)-1u;float bright=float((packed>>8)&255u)/255.0;bool big=(packed&0x1000000u)!=0u;vec3 tint=team_color(color);if((packed&0x2000000u)!=0u)tint=mix(tint,vec3(1.0),0.45);c=big?mix(tint*0.45,vec3(1),bright*0.60):mix(tint,vec3(1),bright*0.65);}
 for(uint k=0u;k<4u;k++){
  if(team[k].misc.y==1u&&team[k].life.x!=2u){float charge=clamp((pc.clock.y-team[k].visual.w)/max(par[12].y,0.001),0.0,1.0);vec2 emitter=team[k].core.xy+direction(uintBitsToFloat(team[k].misc.x))*(team[k].core.z+3.0);float dist=distance(q,emitter);
   float glow=exp(-dist*dist/(12.0+charge*80.0));c+=mix(team_color(k),vec3(1.0),charge*0.7)*glow*(0.25+charge*0.9);}

 }
 float edge=min(min(q.x,q.y),min(world()-q.x,world()-q.y));if(edge<2.0)c=vec3(0.43,0.58,0.73);imageStore(output_image,ivec2(x,y),vec4(clamp(c,0.0,1.0),1.0));
}
void main(){uint i=gl_GlobalInvocationID.x;uint mode=pc.control.x;
 if(mode==0u)initialize(i);else if(mode==1u){if(i==0u)prepare();}else if(mode==2u)move_particle(i);else if(mode==3u){if(i<cols()*cols()*4u)head[i]=-1;if(i==0u)stat[30]=0xffffffffu;if(i<4u){team[i].accounting.x=0xffffffffu;team[i].life.w=0xffffffffu;}}else if(mode==4u)build_space(i);else if(mode==5u)collision_cell(i);else if(mode==6u){if(i==0u)events();}else if(mode==7u){if(i==0u)statistics();}else if(mode==8u){if(i<render_size()*render_size())pixels[i]=0u;}else if(mode==9u)splat(i);else if(mode==10u)render(i);
}
