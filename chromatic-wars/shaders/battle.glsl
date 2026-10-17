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
// 每队160B，和host binding10一致；原128B字段offset保持不变。
// gun.xy=u64计划商；gun_plan=N/下一时间槽/余数/carry；gun_clock=起点/名义截止/锁定射频/时长。
struct WeaponState { uvec4 gun; vec4 aim; uvec4 storm; uvec4 storm_energy;
                     vec4 storm_clock; vec4 shield; uvec4 shield_cursor; uvec4 reserved;
                     uvec4 gun_plan; vec4 gun_clock; };
layout(set=0,binding=10,std430) restrict buffer Weapons { WeaponState weapon[]; };
// GPU-resident live IDs and free stacks. Physical IDs never move when compacting.
layout(set=0,binding=11,std430) restrict buffer ParticlePool { uint pool[]; };
// First two uvec3 are VkDispatchIndirectCommand records. The remaining words are
// optional diagnostics; they are never used as authoritative game state.
layout(set=0,binding=12,std430) restrict buffer DispatchDiagnostics { uint dispatch_data[]; };
// 每个存活槽本子步已付费的首接触前缀，单位为模拟秒；不改Particle64B布局。
layout(set=0,binding=13,std430) restrict buffer TerrainPrefixes { float terrain_paid_until[]; };
// 宽狙击弹使用独立32单位粗格；不扩大普通粒子的九色并行邻域。
layout(set=0,binding=14,std430) restrict buffer WideProjectileSpace { uint wide_space[]; };
layout(push_constant,std430) uniform Push { uvec4 control; vec4 clock; } pc;
// 领土计数随唯一的归属变更出口增量维护，避免周期性整图扫描。
const float TAU=6.28318530718;
const uint WIDE_COLUMNS=32u,WIDE_HEADS=4096u;
const float SNIPER_MAX_RADIUS=10.0;
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
// 除数最多1200000（10000发/秒×120秒）：逐位长除，中间余数<2400000，
// 不依赖shaderInt64或float舍入；风暴和机枪共用精确64位商余。
uvec2 divide64_small(uvec2 dividend,uint divisor,out uint remainder) {
 uvec2 quotient=uvec2(0u);remainder=0u;
 for(int bit=63;bit>=0;bit--){uint word=bit>=32?dividend.y:dividend.x;uint incoming=(word>>uint(bit&31))&1u;remainder=remainder*2u+incoming;
  if(remainder>=divisor){remainder-=divisor;if(bit>=32)quotient.y|=1u<<uint(bit-32);else quotient.x|=1u<<uint(bit);}}
 return quotient;
}
float value64(uvec2 a) { return float(a.y)*4294967296.0+float(a.x); }
// 狙击宽度随真实能量单调、有界增长；只映射几何，绝不反算或改写整数能量。
float sniper_radius_for_energy(uvec2 e) {
 float base=max(1.8,par[4].x*1.5),power=log2(max(value64(e),1.0));
 return min(SNIPER_MAX_RADIUS,base+6.0*power/(12.0+power));
}
uvec2 energy(uint i) { return p[i].info.xy; }
// aux.x低4位保留护盾接触；高28位是每物理槽出生代数，0只表示从未出生。
// 所有出生/分裂均由串行prepare/events写入，无跨线程generation竞争。
uint particle_generation(uint i) {return p[i].aux.x>>4u;}
uint next_particle_generation(uint i) {
 uint previous=particle_generation(i);if(previous<0x0fffffffu)return previous+1u;
 // 极罕见的每槽代数回绕也不能复活旧锁：只在wrap分支清理四队该物理ID。
 // 此helper仅在初始化结束后的串行出生/分裂pass调用，不与并行目标更新竞争。
 for(uint t=0u;t<4u;t++)if(weapon[t].gun.z==i){weapon[t].gun.z=0xffffffffu;weapon[t].gun.w=0u;}
 return 1u;
}
void set_particle_generation(uint i,uint generation) {p[i].aux.x=(p[i].aux.x&15u)|((generation&0x0fffffffu)<<4u);}
void set_energy(uint i,uvec2 e) {
 p[i].info.xy=e;
 if(zero64(e)){if(i<cap()&&p[i].info.w!=0u)atomicOr(pool[4],1u);p[i].info.w=0u;}
}
void spend(uint i,uvec2 amount) { set_energy(i,sub64(energy(i),amount)); }
void consumed(uvec2 e) { uvec2 v=add64(uvec2(stat[17],stat[18]),e); stat[17]=v.x;stat[18]=v.y; }
void consumed_atomic(uvec2 e) { uint old=atomicAdd(stat[17],e.x);uint high_add=e.y+uint(old+e.x<old);uint old_high=atomicAdd(stat[18],high_add);if(old_high+high_add>0x7fffffffu||old_high+high_add<old_high)atomicOr(stat[15],1u); }
uint hash32(uint x) { x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; return x^(x>>16); }
float random01(uint x) { return float(hash32(x)&0xffffffu)/16777216.0; }
vec2 normal_or(vec2 d,vec2 fallback) { float l=length(d);return l>0.00001?d/l:fallback; }
vec2 direction(float angle) { return vec2(cos(angle),sin(angle)); }
uint cell_index(vec2 pos) { ivec2 c=clamp(ivec2(pos/par[1].y),ivec2(0),ivec2(int(cols())-1));return uint(c.y)*cols()+uint(c.x); }
uint territory_index(vec2 pos) { ivec2 c=clamp(ivec2(pos/world()*float(terrain_size())),ivec2(0),ivec2(int(terrain_size())-1));return uint(c.y)*terrain_size()+uint(c.x); }
float shield_radius(uint t) { float e=value64(team[t].shield_gun.xy);return e<=0.0?0.0:min(par[12].x,par[4].z*(par[8].z+(par[8].y-par[8].z)*sqrt(e/max(weapon[t].shield.x,1.0)))); }
float ball_radius(uint i) { return clamp(par[5].x+par[5].y*sqrt(max(value64(energy(i))/max(p[i].geom.y,1.0),0.0)),par[5].x,par[5].z); }
float threshold() {float tau=max(par[14].y,1.0);float progress=(sqrt(1.0+max(pc.clock.y,0.0)/tau)-1.0)/max(sqrt(1.0+max(par[6].z,1.0)/tau)-1.0,0.000001);return exp(min(log(max(par[6].x,1.0))+log(max(par[6].y,par[6].x)/max(par[6].x,1.0))*progress,69.07755279));}
vec3 team_color(uint t) { if(t==0u)return vec3(1.0,0.22,0.32);if(t==1u)return vec3(0.18,1.0,0.51);if(t==2u)return vec3(0.22,0.5,1.0);return vec3(1.0,0.81,0.16); }
// 仅单invocation命令/事件pass调用；一次真正的归属变更同时维护两个面积计数。
void set_territory_owner(uint index,uint t) {uint previous=owner[index];if(previous==t)return;if(previous<4u)stat[8u+previous]--;owner[index]=t;if(t<4u)stat[8u+t]++;}
// pool[0..2] = live IDs / ordinary free slots / eight reserved sniper slots.
// active IDs start at 16; free IDs start at 16+cap(). Only serial passes mutate
// either list. Death merely marks the particle; a post-event pass reclaims once.
uint active_count() { return pool[0]; }
uint active_id(uint ordinal) { return pool[16u+ordinal]; }
void append_active(uint i) {pool[16u+pool[0]]=i;pool[0]++;}
void record_candidate() {if((pc.control.w&2u)!=0u)atomicAdd(dispatch_data[8],1u);}
void record_contact() {if((pc.control.w&2u)!=0u)atomicAdd(dispatch_data[9],1u);}
bool big_pool_exhausted=false;
// 仅串行pass调用，物理容量不足时调用者保留原库存/命令，绝不吞弹药。
int free_slot(bool big) {
 if(!big){if(pool[1]==0u)return -1;uint i=pool[16u+cap()+--pool[1]];append_active(i);return int(i);}
 if(big_pool_exhausted)return -1;uint cursor=stat[21];
 for(uint n=0u;n<balls();n++){uint i=cap()+(cursor+n)%balls();if(p[i].info.w==0u){stat[21]=(cursor+n+1u)%balls();return int(i);}}
 big_pool_exhausted=true;return -1; }
// 为聚能弹预留8个槽，普通粒子满载时仍可发射；额外弹丸可使用空闲普通槽。
int free_sniper_slot() {if(pool[2]>0u){uint i=pool[16u+cap()+cap()-8u+--pool[2]];append_active(i);return int(i);}return free_slot(false);}
void refresh_indirect() {
 dispatch_data[0]=max((active_count()+63u)/64u,1u);dispatch_data[1]=1u;dispatch_data[2]=1u;
 dispatch_data[3]=max((active_count()+balls()+63u)/64u,1u);dispatch_data[4]=1u;dispatch_data[5]=1u;
 dispatch_data[10]=active_count();dispatch_data[11]=pool[1];dispatch_data[12]=pool[2];
}
void compact_pool() {
 // No pooled particle died: preserve the list and update newborn dispatch counts only.
 if(pool[4]==0u){refresh_indirect();return;}
 uint count=active_count(),write_index=0u;
 for(uint k=0u;k<count;k++){uint i=active_id(k);if(p[i].info.w!=0u){pool[16u+write_index++]=i;continue;}
  uint base=16u+cap();if(i<cap()-8u)pool[base+pool[1]++]=i;else pool[base+cap()-8u+pool[2]++]=i;
  pool[3]++;
 }
 pool[0]=write_index;pool[4]=0u;refresh_indirect();
}
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
 // 大球碰撞后的实际速度保持不变；这里只记住航向。
 // 基础移速由移动前独立的有限加速度驱动补充，不将能量损耗换成瞬时速度。
 float speed=length(p[i].pv.zw);
 if(speed>0.00001)next_id[i]=floatBitsToInt(atan(p[i].pv.w,p[i].pv.z));
}
void drive_big_ball(uint i,float dt) {
 if(p[i].info.w!=3u||dt<=0.0)return;
 float speed=length(p[i].pv.zw);float minimum_speed=clamp(par[12].z,1.0,max(par[3].w,1.0));
 if(speed>=minimum_speed)return;
 float angle=intBitsToFloat(next_id[i]);if(isnan(angle)||isinf(angle))angle=0.0;
 vec2 heading=normal_or(p[i].pv.zw,direction(angle));
 // 单独的基础推进器，300游戏单位/模拟秒²；只补不足部分，不推高已经足够快的大球。
 p[i].pv.zw=heading*(speed+min(minimum_speed-speed,300.0*dt));
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
 if(zero64(e))return false;
 int slot=type==2u?free_sniper_slot():free_slot(type==3u);if(slot<0)return false;uint i=uint(slot);uint generation=next_particle_generation(i);float radius=type==3u?clamp(par[5].x+par[5].y*sqrt(value64(e)/max(threshold(),1.0)),par[5].x,par[5].z):(type==2u?sniper_radius_for_energy(e):par[4].x);
 vec2 d=direction(angle);float speed=type==3u?par[3].w:(type==2u?par[3].z:par[3].y);
 vec2 pos=team[t].core.xy+d*(max(team[t].core.z,shield_radius(t))+radius+3.0);pos=clamp(pos,vec2(radius+1.0),vec2(world()-radius-1.0));
 p[i].pv=vec4(pos,d*speed);p[i].info=uvec4(e,t,type);p[i].geom=vec4(radius,type==3u?threshold():speed,pos);p[i].aux=uvec4(0u,type==3u?0u:(type==2u?1u:seed),0u,0u);set_particle_generation(i,generation);
 // 机枪在子步内逐发出生；只推进出生后的实际时长，不把同批弹丸堆在同一位置。
 if(type==1u&&first_move_dt>=0.0){p[i].aux.y=floatBitsToUint(first_move_dt);p[i].aux.z|=0x80000000u;}
 if(type==3u)next_id[i]=floatBitsToInt(angle);
 stat[16]++;return true;
}
bool spawn(uint t,uint type,uvec2 e,float angle,uint seed) {return spawn_timed(t,type,e,angle,seed,-1.0);}
void update_shields() { for(uint t=0u;t<4u;t++)team[t].core.w=shield_radius(t); }
void initialize_weapons(uint t) {
 if(t>=4u)return;
 weapon[t].gun=uvec4(0u,0u,0xffffffffu,0u);weapon[t].aim=vec4(0.0);
 weapon[t].storm=uvec4(0u);weapon[t].storm_energy=uvec4(0u);weapon[t].storm_clock=vec4(0.0);
 weapon[t].shield=vec4(max(par[8].w,1.0),0.0,0.0,0.0);weapon[t].shield_cursor=uvec4(0u);
 weapon[t].reserved=uvec4(0u);weapon[t].gun_plan=uvec4(0u);weapon[t].gun_clock=vec4(0.0);
}
// 只有真实补弹（或初始库存）重建计划；E全来自权威剩余库存，不凭空定价。
// 正射频和时长锁到下次补弹；人工rate=0可暂停，恢复后继续原计划，名义截止允许延后。
void plan_gun_inventory(uint t,float start_time) {
 float rate=clamp(par[2].z,0.0,10000.0),duration=clamp(par[14].w,0.1,120.0);
 uint slots=rate>0.0?max(uint(floor(clamp(team[t].clocks.y,0.0,0.999999)+rate*duration)),1u):0u;
 uint remainder=0u;uvec2 quotient=uvec2(0u);
 if(slots>0u)quotient=divide64_small(team[t].shield_gun.zw,slots,remainder);
 weapon[t].gun.xy=quotient;weapon[t].gun_plan=uvec4(slots,0u,remainder,0u);
 weapon[t].gun_clock=vec4(start_time,start_time+duration,rate,duration);weapon[t].reserved.w=0u;
}
void request_shield_expansion(uint t) {
 float target=shield_radius(t);if(target<=0.0)return;
 weapon[t].shield.y=max(weapon[t].shield.y,target);
 // 同一未完成扩张只增目标，不重置游标；后续独立充能可重新补回内圈丢失的格子。
 if(weapon[t].shield_cursor.w==0u)weapon[t].shield_cursor=uvec4(0u,0u,0u,1u);
}
// 单格宽同心环，由核心向外扫描。每行跳过内圆，只访问新环，不做整圆重复扫描。
// 唯一串行prepare写领土；256个候选/子步限的是工作量，未完成游标和能量不会丢失。
void expand_shield_territory(uint t) {
 if(weapon[t].shield_cursor.w==0u||team[t].life.x==2u)return;
 float unit=world()/float(terrain_size());vec2 center=team[t].core.xy;
 ivec2 center_cell=ivec2(floor(center/unit));uvec4 cursor=weapon[t].shield_cursor;
 for(uint work=0u;work<256u;work++) {
  if(zero64(team[t].shield_gun.xy)){cursor.w=0u;break;}
  float target=min(weapon[t].shield.y,shield_radius(t));uint shell=cursor.x;
  if(float(shell)*unit>target+unit){cursor.w=0u;weapon[t].shield.y=0.0;break;}
  int extent=int(shell)+1;int side=extent*2+1;
  if(cursor.y>=uint(side)){cursor.x++;cursor.y=0u;cursor.z=0u;continue;}
  int y=center_cell.y+int(cursor.y)-extent;float dy=(float(y)+0.5)*unit-center.y;
  float outer=min(float(shell+1u)*unit,target);float inner=float(shell)*unit;
  if(abs(dy)>outer||y<0||y>=int(terrain_size())){cursor.y++;cursor.z=0u;continue;}
  float outer_x=sqrt(max(outer*outer-dy*dy,0.0));
  int left=int(ceil((center.x-outer_x)/unit-0.5));int right=int(floor((center.x+outer_x)/unit-0.5));
  int x=left+int(cursor.z);
  if(x>right){cursor.y++;cursor.z=0u;continue;}
  // 内圆已在前环处理；越过整段内部，不重复逐格访问。
  if(inner>0.0&&abs(dy)<=inner){float inner_x=sqrt(max(inner*inner-dy*dy,0.0));int first_inner=int(ceil((center.x-inner_x)/unit-0.5));int last_inner=int(floor((center.x+inner_x)/unit-0.5));
   if(x>=first_inner&&x<=last_inner){x=last_inner+1;cursor.z=uint(max(x-left,0));if(x>right){cursor.y++;cursor.z=0u;continue;}}}
  cursor.z++;
  if(x<0||x>=int(terrain_size()))continue;
  uint index=uint(y)*terrain_size()+uint(x);if(owner[index]==t)continue;
  team[t].shield_gun.xy=sub64(team[t].shield_gun.xy,uvec2(1u,0u));consumed(uvec2(1u,0u));set_territory_owner(index,t);stat[3]++;
 }
 weapon[t].shield_cursor=cursor;
}
void begin_storm_event(uint t,uvec2 event_energy,uint seed) {
 // 每颗至少1真实能量；最多三整圈，E不足360时只发一圈内的E颗。
 uint count=event_energy.y>0u?1080u:min(event_energy.x,1080u);
 count=count>=360u?(count/360u)*360u:max(count,1u);
 uint remainder;uvec2 base=divide64_small(event_energy,count,remainder);
 weapon[t].storm=uvec4(count,0u,(count+359u)/360u,0u);weapon[t].storm_energy=uvec4(base,remainder,0u);
 weapon[t].storm_clock=vec4(pc.clock.y,random01(seed+stat[7]+t*173u)*TAU,0.0,0.0);
}
void eliminate(uint t) {team[t].life.x=2u;team[t].life.z++;team[t].storm_sniper.xy=add64(team[t].storm_sniper.xy,team[t].shield_gun.zw);team[t].shield_gun.zw=uvec2(0u);team[t].shield_gun.xy=uvec2(0u);}
void resolve_rescue(Command c) {uint t=c.a.y;if(t>=4u||team[t].life.x!=1u||team[t].life.y!=c.b.y)return;
 if(!zero64(c.a.zw)){
  team[t].shield_gun.xy=add64(team[t].shield_gun.xy,c.a.zw);
  // 救援能量先成为可挡伤护盾。不能在同一prepare先把它全部花在夺回核心格子，
  // 然后以“已用过保命、冷却中”立即淘汰；旧扩张也必须在此停止。
  weapon[t].shield.y=0.0;weapon[t].shield_cursor=uvec4(0u);
  team[t].clocks.x=pc.clock.y+par[4].w;team[t].life.x=0u;
 }
 else if(!zero64(team[t].shield_gun.xy))team[t].life.x=0u; // 握手期间正常充盾也必须保护核心。
 else eliminate(t);}
bool execute_command(Command c) {uint op=c.a.x;uint t=c.a.y;if(op==0u)return true;if(op==6u){resolve_rescue(c);return true;}
 // 批内较晚落槽的武器只在对应模拟步生效；负时间保留测试/死亡余波的立即语义。
 if(op>=1u&&op<=5u){float at_time=uintBitsToFloat(c.b.w);if(at_time>=0.0&&pc.clock.y+0.00001<at_time)return false;}
 // 独立测试入口：正常UI不会提交10..16号命令。所有修改仍在GPU内完成。
 if(op==14u){for(uint k=0u;k<active_count();k++)p[active_id(k)].info.w=0u;for(uint i=cap();i<total();i++)p[i].info.w=0u;pool[4]=1u;compact_pool();stat[20]=0u;stat[21]=0u;big_pool_exhausted=false;return true;}
 if(op==15u){uint n=max(c.b.x,1u);for(uint k=0u;k<n&&c.a.z+k<terrain_size()*terrain_size();k++)set_territory_owner(c.a.z+k,t);return true;}
 if(op==16u){for(uint i=0u;i<terrain_size()*terrain_size();i++)owner[i]=t;for(uint k=0u;k<4u;k++)stat[8u+k]=k==t?terrain_size()*terrain_size():0u;return true;}
 if(t>=4u)return true;
 if(op==17u){uint count=c.b.z==0u?cap():min(c.b.z,cap());uint width=uint(ceil(sqrt(float(count))));float spacing=world()/float(width);vec2 velocity=uintBitsToFloat(c.b.xy);if(dot(velocity,velocity)<0.00001)velocity=vec2(30.0,17.0);
  for(uint k=0u;k<active_count();k++)p[active_id(k)].info.w=0u;
  for(uint i=0u;i<count;i++){uint generation=next_particle_generation(i);vec2 position=(vec2(i%width,i/width)+0.5)*spacing;position=clamp(position,vec2(par[4].x),vec2(world()-par[4].x));p[i].pv=vec4(position,velocity);p[i].info=uvec4(zero64(c.a.zw)?uvec2(1u,0u):c.a.zw,t,1u);p[i].geom=vec4(par[4].x,max(length(velocity),1.0),position);p[i].aux=uvec4(0u,hash32(i),0u,0u);set_particle_generation(i,generation);pool[16u+i]=i;}
  pool[0]=count;pool[1]=0u;pool[2]=0u;pool[4]=0u;
  for(uint i=count;i<cap();i++){uint base=16u+cap();if(i<cap()-8u)pool[base+pool[1]++]=i;else pool[base+cap()-8u+pool[2]++]=i;}
  refresh_indirect();stat[20]=0u;return true;}
 if(op==10u){team[t].shield_gun=uvec4(c.a.zw,c.b.xy);team[t].life.x=c.b.z;team[t].clocks.x=uintBitsToFloat(c.b.w);team[t].storm_sniper=uvec4(0u);team[t].misc.y=0u;team[t].visual=vec4(0.0);initialize_weapons(t);if(!zero64(team[t].shield_gun.zw))weapon[t].reserved.w=1u;return true;}
 if(op>=11u&&op<=13u){if(zero64(c.a.zw))return true;int slot=op==12u?free_sniper_slot():free_slot(op==13u);if(slot<0)return false;uint i=uint(slot);uint generation=next_particle_generation(i);uint ty=op==11u?1u:(op==12u?2u:3u);p[i].pv=uintBitsToFloat(c.b);p[i].info=uvec4(c.a.zw,t,ty);float launched_speed=length(p[i].pv.zw);if(launched_speed<0.00001)launched_speed=ty==2u?par[3].z:par[3].y;p[i].geom=vec4(ty==3u?par[5].x:par[4].x,ty==3u?threshold():launched_speed,p[i].pv.xy);p[i].aux=uvec4(0u,ty==3u?0u:(ty==2u?1u:hash32(i+stat[7])),0u,0u);set_particle_generation(i,generation);if(ty==3u){p[i].geom.x=ball_radius(i);next_id[i]=floatBitsToInt(dot(p[i].pv.zw,p[i].pv.zw)>0.0000001?atan(p[i].pv.w,p[i].pv.z):0.0);}return true;}
 // 淘汰后只允许带明确死亡余波标记的大球；异步通知到达前的普通输出不能继续生产。
 if(op>=1u&&op<=5u&&team[t].life.x==2u&&!(op==2u&&(c.b.z&1u)!=0u)){
  // CPU淘汰通知异步期间，左侧可能已真实输出并移除该能量。
  // 过期攻击仍禁止生产，但必须记为显式损耗；命令成功清槽后不再重复收费。
  consumed(c.a.zw);stat[28]++;return true;
 }
 if(op==1u){if(team[t].life.x!=2u){if(!can_add64(team[t].shield_gun.xy,c.a.zw)){atomicOr(stat[15],1u);return false;}team[t].shield_gun.xy=add64(team[t].shield_gun.xy,c.a.zw);if(!zero64(c.a.zw))request_shield_expansion(t);}return true;}
 if(op==2u){if(zero64(c.a.zw))return true;return spawn(t,3u,c.a.zw,random01(c.b.x+stat[7]+t*241u+uint(par[0].w))*TAU,c.b.x);}
 if(op==3u){if(zero64(c.a.zw))return true;if(!zero64(team[t].storm_sniper.zw)||team[t].misc.y!=0u)return false;team[t].storm_sniper.zw=c.a.zw;team[t].misc.x=floatBitsToUint(random01(c.b.x+stat[7]+t*37u+uint(par[0].w))*TAU);team[t].visual.w=pc.clock.y;team[t].misc.y=1u;return true;}
 if(op==4u){if(zero64(c.a.zw))return true;if(weapon[t].storm.x!=0u||!zero64(team[t].storm_sniper.xy))return false;
  team[t].storm_sniper.xy=c.a.zw;begin_storm_event(t,c.a.zw,c.b.x);return true;}
 if(op==5u){if(team[t].life.x!=2u){uvec2 reserve=add64(team[t].storm_sniper.xy,team[t].shield_gun.zw);if(!can_add64(reserve,c.a.zw)){atomicOr(stat[15],1u);return false;}team[t].shield_gun.zw=add64(team[t].shield_gun.zw,c.a.zw);if(!zero64(c.a.zw))weapon[t].reserved.w=1u;}return true;}
 return true;
}
// visual.xyz = 补地方向停留截止(正)/巡转截止(负) / 当前目标角度 / 模式(0旋转,1补地,2..3威胁)。
// misc.zw用于核心保命通知，不能拿来缓存机枪状态。
// accounting.x / life.w 保存上一子步并行归约出的偶/奇索引威胁候选；不承载弹药或死亡状态。
// 键的高12位为反向威胁评分、低20位为粒子索引（容量上限1000000），UINT_MAX表示空。
float gun_projectile_score(uint t,uint i,vec2 center,float range) {
 if(p[i].info.w==0u||p[i].info.w==3u||zero64(energy(i))||p[i].info.z==t)return -1.0;
 vec2 delta=p[i].pv.xy-center;
 if(any(greaterThan(abs(delta),vec2(range))))return -1.0;
 float dist_squared=dot(delta,delta);if(dist_squared>range*range)return -1.0;
 float dist=sqrt(dist_squared);
 float clearance=dist-p[i].geom.x-team[t].core.z;
 float approach=-dot(delta,p[i].pv.zw)/max(dist,1.0);
 // 已离开/掠过核心的粒子不再是锁定威胁，距离很近也不能保留旧锁。
 if(approach<=0.0001)return -1.0;
 float urgency=clamp(1.0-max(clearance,0.0)/range,0.0,1.0);
 return 0.20+0.65*urgency+0.20*clamp(approach/max(par[3].y,1.0),0.0,1.0)+(p[i].info.w==2u?0.35:0.0);
}
void consider_gun_projectile(uint t,uint i,vec2 center,float range,inout float best,inout vec2 target,inout uint target_id) {
 float score=gun_projectile_score(t,i,center,range);
 if(score>best){best=score;target=p[i].pv.xy;target_id=i;}
}
float gun_ball_score(uint t,uint b,out vec2 target) {
 target=team[t].core.xy;if(b<cap()||b>=total()||p[b].info.w!=3u||zero64(energy(b))||p[b].info.z==t)return -1.0;
 vec2 delta=p[b].pv.xy-target;float dist=length(delta);float clearance=dist-p[b].geom.x-team[t].core.z;
 float approach=dot(delta,p[b].pv.zw)/max(dist,1.0);
 if(clearance>world()*0.32||approach>=-0.0001)return -1.0;
 target=p[b].pv.xy+p[b].pv.zw*min(0.12,dist/max(par[3].y,1.0));
 return clamp(1.0-clearance/(world()*0.32),0.0,1.0)+0.15*clamp(-approach/200.0,0.0,1.0);
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
 vec2 center=team[t].core.xy;float best_threat=-1.0;vec2 threat_position=center;uint target_id=0xffffffffu;
 for(uint b=cap();b<total();b++)if(p[b].info.w==3u&&p[b].info.z!=t){
  vec2 candidate_position;float score=gun_ball_score(t,b,candidate_position);
  if(score>best_threat){best_threat=score;threat_position=candidate_position;target_id=b;}
 }
 // 空间构建时并行选出威胁，每个模拟子步只重评两个候选，不串行遍历附近链表。
 // 碰撞/占地可能已消耗候选，必须再检查当前存活与接近方向；下一子步重新归约。
 float query_radius=min(160.0,world()*0.15625);
 uint even_key=team[t].accounting.x,odd_key=team[t].life.w;
 if(even_key!=0xffffffffu){uint index=even_key&0xfffffu;if(index<cap())consider_gun_projectile(t,index,center,query_radius,best_threat,threat_position,target_id);}
 if(odd_key!=0xffffffffu){uint index=odd_key&0xfffffu;if(index<cap())consider_gun_projectile(t,index,center,query_radius,best_threat,threat_position,target_id);}
 uint previous=weapon[t].gun.z,previous_generation=weapon[t].gun.w;vec2 previous_position=center;float previous_score=-1.0;
 // 物理槽会重用：只有ID和出生代数均匹配才是此前锁定的同一个实体。
 if(previous<total()&&particle_generation(previous)==previous_generation){
  if(previous<cap()){previous_score=gun_projectile_score(t,previous,center,query_radius);previous_position=p[previous].pv.xy;}
  else previous_score=gun_ball_score(t,previous,previous_position);
 }
 if(previous_score>best_threat){target_id=previous;best_threat=previous_score;threat_position=previous_position;}
 // 冷却锁目标身份而不锁角度；有效原目标持续逐步追踪，不因新目标评分高而抢占。
 // 原目标死亡、换代、变己方或脱离有效威胁范围时，previous_score<0立即重新选择。
 if(previous_score>=0.0&&target_id!=previous&&pc.clock.y<weapon[t].aim.x){target_id=previous;best_threat=previous_score;threat_position=previous_position;}
 uint selected_generation=target_id<total()?particle_generation(target_id):0u;
 if(target_id!=previous||selected_generation!=previous_generation){weapon[t].gun.z=target_id;weapon[t].gun.w=selected_generation;weapon[t].aim.x=target_id!=0xffffffffu?pc.clock.y+max(par[14].x,0.0):0.0;}
 if(best_threat>=0.0){vec2 delta=threat_position-center;team[t].visual.x=0.0;team[t].visual.y=atan(delta.y,delta.x);team[t].visual.z=2.0+clamp(best_threat,0.0,1.0);return;}
 if(previous!=0xffffffffu&&previous_score<0.0){
  // 威胁消失立即解除身份和角度锁；先从当前朝向连续巡转，不沿旧角度继续长串。
  weapon[t].gun.z=0xffffffffu;weapon[t].gun.w=0u;weapon[t].aim.x=0.0;
  team[t].visual.x=-(pc.clock.y+0.20);team[t].visual.y=team[t].clocks.z;team[t].visual.z=0.0;return;
 }
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
 // 离散射线仅提供快速方向，不能据此认定整圈安全。逐子步滚动扫描真实格，
 // 缓存补地目标只有限停留，之后从当前朝向巡转；滚动游标不清零，避免固定格长串。
 float outer=begin+world()*0.14;uint n=terrain_size();float unit=world()/float(n);
 uint cached=uint(max(weapon[t].aim.y,0.0));bool cached_valid=false;
 if(cached>0u&&cached<=n*n){uint index=cached-1u;vec2 point=(vec2(index%n,index/n)+0.5)*unit;float d=distance(point,center);
  if(owner[index]!=t&&d>=begin&&d<=outer){vec2 delta=point-center;result=atan(delta.y,delta.x);cached_valid=true;}}
 if(!cached_valid){weapon[t].aim.y=0.0;
  ivec2 low=clamp(ivec2(floor((center-vec2(outer))/unit)),ivec2(0),ivec2(int(n)-1));
  ivec2 high=clamp(ivec2(floor((center+vec2(outer))/unit)),ivec2(0),ivec2(int(n)-1));
  uint width=uint(high.x-low.x+1),count=width*uint(high.y-low.y+1);uint cursor=uint(max(weapon[t].aim.z,0.0))%max(count,1u);
  for(uint work=0u;work<min(count,256u);work++){
   uint offset=cursor;cursor=(cursor+1u)%count;ivec2 cell=low+ivec2(int(offset%width),int(offset/width));
   uint index=uint(cell.y)*n+uint(cell.x);if(owner[index]==t)continue;
   vec2 delta=(vec2(cell)+0.5)*unit-center;float d2=dot(delta,delta);if(d2<begin*begin||d2>outer*outer)continue;
   weapon[t].aim.y=float(index+1u);result=atan(delta.y,delta.x);cached_valid=true;break;
  }
  weapon[t].aim.z=float(cursor);weapon[t].aim.w=float(count);
 }
 team[t].visual.y=result;
 if(best<=0.0&&!cached_valid){team[t].visual.x=0.0;team[t].visual.z=0.0;return;}
 float dwell=team[t].visual.x;
 if(dwell<0.0&&pc.clock.y<-dwell){team[t].visual.z=0.0;return;}
 if(dwell<=0.0){team[t].visual.x=pc.clock.y+0.15;team[t].visual.z=1.0;return;}
 if(pc.clock.y>=dwell){team[t].visual.x=-(pc.clock.y+0.20);weapon[t].aim.y=0.0;team[t].visual.z=0.0;return;}
 team[t].visual.z=1.0;
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
float gun_shot_sweep(uint t,float at_time) {
 if(team[t].visual.z<0.5)return 0.0;
 // 锁敌/短暂补地时±2度、6Hz连续扫射；按每颗真实出生模拟时刻取值，补弹不重置。
 float phase=mod(max(at_time,0.0),1.0/6.0)*TAU*6.0+float(t)*TAU*0.25;
 return (TAU/180.0)*sin(phase);
}
void prepare() {
 for(uint n=1028u;n<1036u;n++){Command c=command[n];if(c.a.x!=0u&&execute_command(c))command[n].a.x=0u;}
 for(uint t=0u;t<4u;t++){Command c=command[1024u+t];if(c.a.x==6u)resolve_rescue(c);command[1024u+t].a.x=0u;}
 uint command_head=stat[4];uint queued=pc.control.z-command_head;uint pending_count=0u;uvec2 pending_energy=uvec2(0u);
 // 有容量的命令可以越过等待中的大球/狙击命令；只回收已完成的连续前缀。
 for(uint n=0u;n<min(queued,1024u);n++){uint slot=(command_head+n)%1024u;Command c=command[slot];if(c.a.x!=0u){if(execute_command(c))command[slot].a.x=0u;else {pending_count++;if(c.a.x<=5u)pending_energy=add64(pending_energy,c.a.zw);}}}
 while(command_head!=pc.control.z&&command[command_head%1024u].a.x==0u)command_head++;
 stat[4]=command_head;stat[5]=pending_count;stat[25]=pending_energy.x;stat[26]=pending_energy.y;stat[27]=pc.control.z-command_head;
 for(uint t=0u;t<4u;t++)expand_shield_territory(t);
 update_shields();uint step_budget=max(uint(par[6].w),1u);uint budget=step_budget;
 // 有空槽/库存时不能因风暴的性能预算漏掉已到时的机枪弹；基础预算只限制额外风暴工作。
 float maximum_gun_rate=max(par[2].z,0.0);
 if(maximum_gun_rate>0.0)for(uint t=0u;t<4u;t++)maximum_gun_rate=max(maximum_gun_rate,weapon[t].gun_clock.z);
 uint gun_quota=max(uint(ceil(maximum_gun_rate*max(pc.clock.x,0.0)))+1u,1u);budget=max(budget,gun_quota*4u);
 for(uint order=0u;order<4u;order++){uint t=(order+stat[7])%4u;
  float dt=max(pc.clock.x,0.0);float phase=clamp(team[t].clocks.y,0.0,0.999999);
  float heading=team[t].clocks.z;
  if(team[t].life.x!=2u&&!zero64(team[t].shield_gun.zw))refresh_gun_aim(t);
  float turn=gun_turn(t,heading,dt);team[t].clocks.z=mod(heading+turn+TAU,TAU);
  // 所有模式使用同一固定射速；防守优先级只影响目标和炮口，不暗中改变射频。
  float configured_rate=max(par[2].z,0.0);
  float rate=configured_rate>0.0?(weapon[t].gun_clock.z>0.0?weapon[t].gun_clock.z:configured_rate):0.0;
  float scheduled=phase+rate*dt;
  uint due=uint(floor(scheduled));
  // 无弹药/无槽时不积攒整发额度，避免解除阻塞后补发成一截一截；弹药仍全部保留。
  team[t].clocks.y=team[t].life.x==2u?0.0:(rate>0.0?fract(scheduled):phase);
  // 聚能狙击仍是一颗真实飞行弹丸，不改成即时激光。
  if(team[t].misc.y==1u&&pc.clock.y-team[t].visual.w>=par[12].y){
   if(spawn(t,2u,team[t].storm_sniper.zw,uintBitsToFloat(team[t].misc.x),hash32(stat[7]+t*97u))){team[t].storm_sniper.zw=uvec2(0u);team[t].misc.y=0u;}
  }
  // 固定射频的每个时间槽推进整数商余分摊；低库存的空槽不生零能实体。
  uint gun_limit=min(due,min(gun_quota,budget));uint gun_slots=0u;
  while(budget>0u&&gun_slots<gun_limit&&team[t].life.x!=2u&&rate>0.0&&weapon[t].gun_plan.y<weapon[t].gun_plan.x){
   uvec2 available=team[t].shield_gun.zw;if(zero64(available))break;
   uint next_carry=weapon[t].gun_plan.w+weapon[t].gun_plan.z;
   bool extra=next_carry>=weapon[t].gun_plan.x;
   if(extra)next_carry-=weapon[t].gun_plan.x;
   uvec2 e=weapon[t].gun.xy;if(extra)e=add64(e,uvec2(1u,0u));
   if(!zero64(e)){
    if(less64(available,e)){atomicOr(stat[15],1u);break;}
    float ordinal=gun_limit<due?floor((float(gun_slots)+0.5)*float(due)/float(gun_limit)):float(gun_slots);
    float shot_offset=clamp((ordinal+1.0-phase)/rate,0.0,dt);
    float age=max(dt-shot_offset,0.0);
    float shot_time=max(pc.clock.y-dt+shot_offset,0.0);
    float shot_angle=heading+(dt>0.0?turn*shot_offset/dt:0.0)+gun_shot_sweep(t,shot_time);
    // 满池时不提交计划carry/ordinal、不扣能；以后按真实槽位继续，绝不补发一束积压弹。
    if(!spawn_timed(t,1u,e,shot_angle,hash32(stat[7]*192u+budget+t*97u),age))break;
    team[t].shield_gun.zw=sub64(available,e);budget--;
   }
   weapon[t].gun_plan.w=next_carry;weapon[t].gun_plan.y++;gun_slots++;
  }
  // 本步末到达的补给不能倒流成步初子弹：先服务旧计划，再将当前剩余全量分摊到新的T窗。
  // 不改连续射击phase、枪口、目标身份或切换CD。rate0只挂起库存；首次恢复正射频再建计划。
  if(team[t].life.x!=2u&&(weapon[t].reserved.w!=0u||(weapon[t].gun_plan.x==0u&&!zero64(team[t].shield_gun.zw)&&configured_rate>0.0)))plan_gun_inventory(t,pc.clock.y);
 }
 // 先服务四队本步机枪，避免某队风暴抢完预算造成后续阵营的机枪断成短段。
 // 先满足固定射速，再把剩余发射预算分给风暴；容量不足只积压弹药，不吞库存。
 for(uint order=0u;order<4u;order++){uint t=(order+stat[7])%4u;
  // 每事件最多1080颗，分成最多3圈；输入增大只提高每颗能量，不无限加圈。
  // 核心死亡追加的未发机枪库存是独立余波事件；已有事件必须先精确发完。
  if(weapon[t].storm.x==0u&&!zero64(team[t].storm_sniper.xy))begin_storm_event(t,team[t].storm_sniper.xy,hash32(stat[7]+t));
  while(budget>0u&&weapon[t].storm.x>0u&&pc.clock.y+0.000001>=weapon[t].storm_clock.x){
   uint ordinal=weapon[t].storm.y;uint circle=ordinal/360u;uint first=circle*360u;uint count=min(360u,weapon[t].storm.x-first);
   uvec2 e=weapon[t].storm_energy.xy;if(ordinal<weapon[t].storm_energy.z)e=add64(e,uvec2(1u,0u));
   float angle=weapon[t].storm_clock.y+float(circle)*0.137+TAU*float(ordinal-first)/float(count);
   if(!spawn(t,1u,e,angle,hash32(ordinal+t*97u+stat[7]*521u)))break;
   team[t].storm_sniper.xy=sub64(team[t].storm_sniper.xy,e);weapon[t].storm.y++;budget--;
   if(weapon[t].storm.y>=weapon[t].storm.x){weapon[t].storm_clock.z=pc.clock.y;weapon[t].reserved.x++;weapon[t].reserved.y+=weapon[t].storm.z;weapon[t].storm=uvec4(0u);break;}
   if(weapon[t].storm.y%360u==0u){weapon[t].storm.w++;weapon[t].storm_clock.z=pc.clock.y;weapon[t].storm_clock.x=pc.clock.y+max(par[13].w,0.02);break;}
  }
 }stat[7]++;stat[19]=floatBitsToUint(pc.clock.y);
}
void initialize(uint i) {
 if(i<4u)initialize_weapons(i);
 if(i<cap()){pool[16u+i]=0u;pool[16u+cap()+i]=i<cap()-8u?cap()-9u-i:i;}
 if(i<16u)pool[i]=i==1u?cap()-8u:(i==2u?8u:0u);
 if(i<32u)dispatch_data[i]=0u;
 if(i<total()){p[i].pv=vec4(0.0);p[i].info=uvec4(0u);p[i].geom=vec4(0.0);p[i].aux=uvec4(0u);}
 if(i<cols()*cols()*4u)head[i]=-1;if(i<total())next_id[i]=i<cap()?-1:floatBitsToInt(0.0);
 if(i<terrain_size()*terrain_size()){uint x=i%terrain_size(),y=i/terrain_size();owner[i]=(x>=terrain_size()/2u?1u:0u)+(y>=terrain_size()/2u?2u:0u);}
 if(i<render_size()*render_size())pixels[i]=0u;if(i<64u){stat[i]=i==30u?0xffffffffu:0u;if(i>=8u&&i<12u){uint t=i-8u;uint half_n=terrain_size()/2u;uint width=(t&1u)!=0u?terrain_size()-half_n:half_n;uint height=(t&2u)!=0u?terrain_size()-half_n:half_n;stat[i]=width*height;}}
 if(i<1036u){command[i].a=uvec4(0u);command[i].b=uvec4(0u);}
 if(i<4u){team[i].shield_gun=floatBitsToUint(par[9]);team[i].storm_sniper=uvec4(0u);team[i].life=uvec4(0u,0u,0u,0xffffffffu);team[i].clocks=vec4(0.0,0.0,float(i)*TAU/4.0,0.0);team[i].accounting=uvec4(0xffffffffu,0u,0u,0u);team[i].core=vec4((i==0u?par[10].xy:(i==1u?par[10].zw:(i==2u?par[11].xy:par[11].zw))),par[5].w,par[8].y*par[4].z);team[i].core.w=shield_radius(i);team[i].misc=uvec4(0u);team[i].visual=vec4(0u);plan_gun_inventory(i,0.0);}
}
void move_particle(uint i) {if(i>=total()||p[i].info.w==0u)return;maintain_motion(i);drive_big_ball(i,pc.clock.x);float r=p[i].info.w==3u?ball_radius(i):(p[i].info.w==2u?sniper_radius_for_energy(energy(i)):par[4].x);p[i].geom.x=r;p[i].geom.zw=p[i].pv.xy;
 float move_dt=pc.clock.x;
 if(p[i].info.w==1u&&(p[i].aux.z&0x80000000u)!=0u){move_dt=clamp(uintBitsToFloat(p[i].aux.y),0.0,max(pc.clock.x,0.0));}
 vec2 pos=p[i].pv.xy+p[i].pv.zw*move_dt;vec2 vel=p[i].pv.zw;
 if(p[i].info.w==3u){
  // 大球保留原有有界软反弹；小弹丸的墙由事件TOI统一结算，不能在这里先折回路径。
  float wall_e=contact_restitution(i);
  for(int axis=0;axis<2;axis++){if(pos[axis]<r){pos[axis]=2.0*r-pos[axis];vel[axis]=abs(vel[axis])*wall_e;}if(pos[axis]>world()-r){pos[axis]=2.0*(world()-r)-pos[axis];vel[axis]=-abs(vel[axis])*wall_e;}}
  p[i].pv=vec4(clamp(pos,vec2(r),vec2(world()-r)),vel);maintain_motion(i);
 }else p[i].pv=vec4(pos,vel);
 for(uint t=0u;t<4u;t++){float distance_core=distance(p[i].pv.xy,team[t].core.xy);if(distance_core>team[t].core.w+r+2.0)p[i].aux.x&=~(1u<<t);
  // 保命请求对应的攻击在握手期间保持接触保护，补盾后须先离开新护盾才可重新结算。
  if(team[t].life.x==2u||(team[t].life.x==0u&&distance_core>team[t].core.w+r+2.0))p[i].aux.z&=~(1u<<t);}
}
// 小弹丸保留未折返坐标直到串行实体事件；邻域与粒子对使用同一真实镜像墙轨迹。
vec2 folded_position(vec2 raw,float radius) {
 float span=world()-2.0*radius;vec2 phase=mod(raw-vec2(radius),vec2(2.0*span));
 vec2 result=vec2(radius)+min(phase,vec2(2.0*span)-phase);
 for(int axis=0;axis<2;axis++)if(raw[axis]>=radius&&raw[axis]<=world()-radius)result[axis]=raw[axis];
 return result;
}
bool wall_motion(uint i) {
 float radius=p[i].geom.x;vec2 lo=min(p[i].geom.zw,p[i].pv.xy),hi=max(p[i].geom.zw,p[i].pv.xy);
 return any(lessThanEqual(lo,vec2(radius)))||any(greaterThanEqual(hi,vec2(world()-radius)));
}
vec2 folded_sign(vec2 raw,vec2 ray,float radius) {
 float span=world()-2.0*radius;vec2 phase=mod(raw-vec2(radius),vec2(2.0*span));vec2 result=vec2(1.0);
 for(int axis=0;axis<2;axis++){
  if(phase[axis]>span||(phase[axis]==span&&ray[axis]>=0.0)||(phase[axis]==0.0&&ray[axis]<0.0))result[axis]=-1.0;
 }
 return result;
}
vec2 pair_endpoint(uint i) {return wall_motion(i)?folded_position(p[i].pv.xy,p[i].geom.x):p[i].pv.xy;}
uint wide_cell(vec2 point) {ivec2 c=clamp(ivec2(floor(point/32.0)),ivec2(0),ivec2(int(WIDE_COLUMNS)-1));return uint(c.y)*WIDE_COLUMNS+uint(c.x);}
ivec4 projectile_query_bounds(uint i,float other_radius,float unit,uint columns) {
 // 非fast弹单步位移<=4；补足另一弹的端点到接触点距离，以及本弹墙折返的外沿。
 vec2 finish=pair_endpoint(i);float margin=p[i].geom.x+other_radius+8.0;
 ivec2 low=clamp(ivec2(floor((min(p[i].geom.zw,finish)-vec2(margin))/unit)),ivec2(0),ivec2(int(columns)-1));
 ivec2 high=clamp(ivec2(floor((max(p[i].geom.zw,finish)+vec2(margin))/unit)),ivec2(0),ivec2(int(columns)-1));
 return ivec4(low,high);
}
float wall_direction_room(vec2 position,vec2 heading,float radius) {
 float room=1e30;
 for(int axis=0;axis<2;axis++)if(abs(heading[axis])>0.000001){float boundary=heading[axis]>0.0?world()-radius:radius;room=min(room,max((boundary-position[axis])/heading[axis],0.0));}
 return room;
}
// 同色弹性碰撞可能提高单颗速度；超出3×3覆盖界限的粒子进入独立链，
// 在串行事件阶段做完整候选查询，绝不夹速或漏掉快速碰撞。aux.w锁定本步分类。
bool fast_particle(uint i) {float limit=min(4.0,(par[1].y-2.0*par[4].x)*0.5);return distance(p[i].pv.xy,p[i].geom.zw)>limit+0.00001;}
void build_space(uint i) {if(i>=cap()||p[i].info.w==0u)return;
 // AI摘要与空间链同一并行pass构建；快粒子也必须先参与，绝不影响碰撞候选。
 summarize_gun_projectile(i);
 if(fast_particle(i)){p[i].aux.w=1u;next_id[i]=int(atomicExchange(stat[30],i));return;}
 if(p[i].info.w==2u){p[i].aux.w=2u;uint c=p[i].info.z*WIDE_COLUMNS*WIDE_COLUMNS+wide_cell(pair_endpoint(i));wide_space[WIDE_HEADS+i]=atomicExchange(wide_space[c],i);return;}
 p[i].aux.w=0u;uint c=p[i].info.z*cols()*cols()+cell_index(pair_endpoint(i));next_id[i]=atomicExchange(head[c],int(i));}
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
// 真实圆接触entry，而不是最近点法线：最近点的相对速度恰好相切，会漏掉擦边反弹。
// c/(-b+sqrt(discriminant))与较小二次根等价，避免近接触时两大数相减。
bool linear_contact_entry(vec2 start_delta,vec2 relative,float radius,out float entry) {
 float c=dot(start_delta,start_delta)-radius*radius;
 if(c<=0.0){entry=0.0;return true;}
 float a=dot(relative,relative);if(a<=0.000000000001)return false;
 float b=dot(start_delta,relative);if(b>=0.0)return false;
 float discriminant=b*b-a*c;if(discriminant<=0.0)return false;
 entry=c/(-b+sqrt(discriminant));return entry>=0.0&&entry<=1.0;
}
// 合并两弹丸的全部墙到达时刻，每段相对运动都线性；不固定截断高速多墙折返。
// 此查询仍只在原唯一pair归属中调用，不能通过另一次碰撞pass重复扣能。
bool folded_pair_contact(uint a,uint b,float radius,bool mechanical,out vec2 contact_delta,out vec2 contact_sign_a,out vec2 contact_sign_b,out float contact_time) {
 float common_start=max(motion_start(a),motion_start(b));
 vec2 from_a=motion_from(a,common_start),from_b=motion_from(b,common_start);
 vec2 ray_a=p[a].pv.xy-from_a,ray_b=p[b].pv.xy-from_b;
 vec4 origins=vec4(from_a,from_b),rays=vec4(ray_a,ray_b),next_wall=vec4(1e30),wall_stride=vec4(0.0);
 vec4 radii=vec4(p[a].geom.x,p[a].geom.x,p[b].geom.x,p[b].geom.x);
 for(int axis=0;axis<4;axis++)if(abs(rays[axis])>0.0000001){
  float span=world()-2.0*radii[axis],coordinate=(origins[axis]-radii[axis])/span;
  float plane=radii[axis]+(rays[axis]>0.0?floor(coordinate)+1.0:ceil(coordinate)-1.0)*span;
  next_wall[axis]=(plane-origins[axis])/rays[axis];wall_stride[axis]=span/abs(rays[axis]);
 }
 float cursor=0.0;
 while(cursor<1.0){
  float stop=min(1.0,min(min(next_wall.x,next_wall.y),min(next_wall.z,next_wall.w)));
  // 墙面恰好落在上段端点时只推进该面的下一时刻，避免零TOI循环。
  if(stop<=cursor){for(int axis=0;axis<4;axis++)if(next_wall[axis]<=cursor)next_wall[axis]+=wall_stride[axis];continue;}
  vec2 start_delta=folded_position(from_b+ray_b*cursor,p[b].geom.x)-folded_position(from_a+ray_a*cursor,p[a].geom.x);
  vec2 end_delta=folded_position(from_b+ray_b*stop,p[b].geom.x)-folded_position(from_a+ray_a*stop,p[a].geom.x);
  vec2 relative=end_delta-start_delta;float dd=dot(relative,relative);
  float hit=dd>0.0000001?clamp(-dot(start_delta,relative)/dd,0.0,1.0):0.0;
  bool collided=mechanical?linear_contact_entry(start_delta,relative,radius,hit):dot(start_delta+relative*hit,start_delta+relative*hit)<radius*radius;
  if(collided){
   vec2 contact=start_delta+relative*hit;
   contact_delta=dot(contact,contact)>0.000001?contact:normal_or(start_delta,normal_or(-relative,vec2(1,0)))*0.0001;
   // 此开区间内镜像符号恒定；不能在恰好到墙的端点偷用墙后的符号。
   float middle=(cursor+stop)*0.5;
   contact_sign_a=folded_sign(from_a+ray_a*middle,ray_a,p[a].geom.x);
   contact_sign_b=folded_sign(from_b+ray_b*middle,ray_b,p[b].geom.x);
   contact_time=mix(common_start,max(pc.clock.x,common_start),cursor+(stop-cursor)*hit);return true;
  }
  cursor=stop;for(int axis=0;axis<4;axis++)if(next_wall[axis]<=cursor)next_wall[axis]+=wall_stride[axis];
 }
 return false;
}
// 普通粒子之间始终等机械质量；携带能量不会令己方碰撞凭空加速。
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
 record_candidate();
 bool wall_a=wall_motion(a),wall_b=wall_motion(b),mechanical=p[a].info.z==p[b].info.z;
 vec2 end_a=pair_endpoint(a),end_b=pair_endpoint(b);
 vec2 d=end_b-end_a;float rr=p[a].geom.x+p[b].geom.x;float d2=dot(d,d);
 vec2 contact_sign_a=vec2(1.0),contact_sign_b=vec2(1.0);
 if(wall_a||wall_b){
  // 友方即使末端仍重叠，也必须用最早接触段的入射速度和法线求冲量。
  float contact_time;
  if(mechanical||d2>=rr*rr)if(!folded_pair_contact(a,b,rr,mechanical,d,contact_sign_a,contact_sign_b,contact_time))return;
 }else {
  vec2 old=vec2(0.0),relative=vec2(0.0);
  if(mechanical||d2>=rr*rr){
   // 无墙保留包围盒和closest快速拒绝；仅真实友方命中再解entry二次根。
   if(any(lessThan(max(p[a].geom.zw,p[a].pv.xy)+vec2(rr),min(p[b].geom.zw,p[b].pv.xy)))||any(lessThan(max(p[b].geom.zw,p[b].pv.xy)+vec2(rr),min(p[a].geom.zw,p[a].pv.xy))))return;
   float common_start=max(motion_start(a),motion_start(b));old=motion_from(b,common_start)-motion_from(a,common_start);relative=d-old;
   float dd=dot(relative,relative);float time=dd>0.00001?clamp(-dot(old,relative)/dd,0.0,1.0):1.0;vec2 near=old+relative*time;
   if(d2>=rr*rr&&dot(near,near)>=rr*rr)return;
   if(mechanical){float entry;if(!linear_contact_entry(old,relative,rr,entry))return;near=old+relative*entry;}
   d=dot(near,near)>0.000001?near:normal_or(old,normal_or(-relative,vec2(1,0)))*0.0001;
  }
 }
 atomicAdd(stat[2],1u);record_contact();
 if(p[a].info.z==p[b].info.z){
  vec2 n=normal_or(d,direction(float((a*31u+b*17u)%628u)*0.01));
  vec2 sign_a=wall_a?folded_sign(p[a].pv.xy,p[a].pv.xy-p[a].geom.zw,p[a].geom.x):vec2(1.0);
  vec2 sign_b=wall_b?folded_sign(p[b].pv.xy,p[b].pv.xy-p[b].geom.zw,p[b].geom.x):vec2(1.0);
  vec2 corrected_a=end_a,corrected_b=end_b,end_delta=end_b-end_a;
  float end_distance=length(end_delta);
  // 只纠正真实末端穿透；早已分离的CCD擦边不能因entry法线再被远距离推位。
  if(end_distance<rr){
   vec2 separation_normal=normal_or(end_delta,n);float separation=(rr-end_distance)*0.5+0.001;
   corrected_a=clamp(end_a-separation_normal*separation,vec2(p[a].geom.x),vec2(world()-p[a].geom.x));
   corrected_b=clamp(end_b+separation_normal*separation,vec2(p[b].geom.x),vec2(world()-p[b].geom.x));
   // 靠墙一侧不能承担的分离量交给另一侧，避免投影回墙后重新重叠。
   float residual=max(rr+0.002-dot(corrected_b-corrected_a,separation_normal),0.0);
   if(residual>0.0){float move_a=min(residual,wall_direction_room(corrected_a,-separation_normal,p[a].geom.x));corrected_a-=separation_normal*move_a;residual-=move_a;
    corrected_b+=separation_normal*min(residual,wall_direction_room(corrected_b,separation_normal,p[b].geom.x));}
  }
  vec2 original_a=p[a].pv.zw*contact_sign_a,original_b=p[b].pv.zw*contact_sign_b;
  vec2 outgoing_a=original_a,outgoing_b=original_b;
  float approaching=dot(original_b-original_a,n);
  if(approaching<0.0){outgoing_a+=approaching*n;outgoing_b-=approaching*n;}
  // 碰撞只改变航向，逐颗保持出生速度；零速度解沿接触面向外离开。
  if(dot(outgoing_a,outgoing_a)<0.00000001)outgoing_a=-n;
  if(dot(outgoing_b,outgoing_b)<0.00000001)outgoing_b=n;
  outgoing_a=fixed_particle_velocity(a,outgoing_a,original_a);
  outgoing_b=fixed_particle_velocity(b,outgoing_b,original_b);
  // 接触段响应先沿原几何的剩余墙奇偶传播到世界末端，再映回纠正后的同一镜像tile。
  vec2 end_velocity_a=outgoing_a*contact_sign_a*sign_a,end_velocity_b=outgoing_b*contact_sign_b*sign_b;
  p[a].pv.xy+=sign_a*(corrected_a-end_a);p[b].pv.xy+=sign_b*(corrected_b-end_b);
  sign_a=folded_sign(p[a].pv.xy,p[a].pv.xy-p[a].geom.zw,p[a].geom.x);
  sign_b=folded_sign(p[b].pv.xy,p[b].pv.xy-p[b].geom.zw,p[b].geom.x);
  p[a].pv.zw=end_velocity_a*sign_a;p[b].pv.zw=end_velocity_b*sign_b;
  // 墙事件在随后统一TOI中处理，不能先折回端点而丢失真实到墙轨迹。
  return;
 }
 // 异阵营的普通/聚能弹全部按实际64位整数能量等量抵消。
 // 只消耗较小能量；幸存者保留原来的位置、方向与出生速度，不给高能量额外转向。
 // consumed_atomic累计双方各自的损耗，九色格内多线程只在该账本使用原子加法。
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
void apply_core_contact(uint i,uint t,vec2 normal,float target_radius,bool target_shield) {
 if(p[i].info.w==0u)return;
 float approaching=max(-dot(p[i].pv.zw,normal),0.0);bool big=p[i].info.w==3u;
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
   if(p[i].info.w==2u&&approaching>0.0)p[i].aux.z|=0x40000000u;
  }return;}
 // 同一接触只走盾或核心中的一条出口；PENDING_RESCUE提供事件保护。
 if(team[t].life.x==0u){if(pc.clock.y+0.000001<team[t].clocks.x)eliminate(t);else {team[t].life.x=1u;team[t].life.y++;team[t].misc.z=p[i].info.x;team[t].misc.w=p[i].info.y;}}
 if(team[t].life.x==1u)p[i].aux.z|=1u<<t;

}
void shield_core_events(uint i) {if(p[i].info.w==0u)return;uint own=p[i].info.z;int target=-1;float first_time=2.0;vec2 normal=vec2(1,0);float target_radius=0.0;bool target_shield=false;
 // 先找到整条运动段最早的实体接触，再把领土扫描截断至接触点。
 // 路上已经耗尽的粒子绝不可能隔空伤盾或触发核心事件。
 for(uint t=0u;t<4u;t++){if(t==own||team[t].life.x==2u)continue;bool shield=!zero64(team[t].shield_gun.xy);float radius=shield?shield_radius(t):team[t].core.z;float hit_t;vec2 hit_normal;
  if(swept_hit(p[i].geom.zw,p[i].pv.xy,team[t].core.xy,radius+p[i].geom.x,hit_t,hit_normal)&&hit_t<first_time){target=int(t);first_time=hit_t;normal=hit_normal;target_radius=radius;target_shield=shield;}}
 if(target>=0)p[i].pv.xy=mix(p[i].geom.zw,p[i].pv.xy,first_time);
 terrain_events(i);if(target<0||p[i].info.w==0u)return;
 apply_core_contact(i,uint(target),normal,target_radius,target_shield);
}

bool ball_contact_mask(uint a,uint b) {uint slot=b-cap();uint mask=1u<<(slot&31u);return slot<32u?(p[a].aux.y&mask)!=0u:(p[a].aux.w&mask)!=0u;}
void set_ball_contact_mask(uint a,uint b,bool touching) {uint slot=b-cap();uint mask=1u<<(slot&31u);if(slot<32u){if(touching)p[a].aux.y|=mask;else p[a].aux.y&=~mask;}else {if(touching)p[a].aux.w|=mask;else p[a].aux.w&=~mask;}}
// 事件invocation私有；先按实际能量累积全部冲量，再对每球的整步加速度平滑限幅。
// 不对单颗弹丸限幅，因此相同总能量和方向不会仅因弹丸分组变化而失去推动力。
vec2 pending_ball_push[64];
float pending_ball_mass[64]; // 子步接触前的机械质量快照，损耗后不重新放大冲量。
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
void projectile_ball_impulse(uint projectile,uint ball,float approaching,uvec2 exchanged) {
 if(approaching<=0.0||zero64(exchanged))return;
 float transfer=p[projectile].info.z==p[ball].info.z?0.22:0.35;
 vec2 relative_velocity=p[projectile].pv.zw-p[ball].pv.zw;
 // 推动力只来自实际吸收/抵消的入射能量，超额继续飞行的能量不重复产生冲量。
 pending_ball_push[ball-cap()]+=transfer*value64(exchanged)*relative_velocity;
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
void apply_ball_contact(uint a,uint b,vec2 n) {
 if(p[a].info.w==0u||p[b].info.w==0u)return;
 bool both_big=p[a].info.w==3u&&p[b].info.w==3u;
 float r=p[a].geom.x+p[b].geom.x;
 stat[2]++;record_contact();float relative=dot(p[a].pv.zw-p[b].pv.zw,n);float approaching=max(-relative,0.0);
 if(!both_big){
  // 事件调用顺序保证a是普通/狙击粒子，b是大球。
  if(p[a].info.z==p[b].info.z){
   uvec2 incoming=energy(a);if(!can_add64(energy(b),incoming)){atomicOr(stat[15],1u);return;}
   projectile_ball_impulse(a,b,approaching,incoming);set_energy(b,add64(energy(b),incoming));set_energy(a,uvec2(0u));p[b].geom.x=ball_radius(b);index_coarse_ball(b);return;
  }
  if(p[a].info.w==2u&&approaching>0.0)p[a].aux.z|=0x40000000u; // 实体大球接触，末尾按剩余能量执行狙击分裂。
  uvec2 cancel=min64(energy(a),energy(b));projectile_ball_impulse(a,b,approaching,cancel);
  spend(b,cancel);spend(a,cancel);consumed(cancel);consumed(cancel);
  // 余能继续前进。只有仍存在的大球才能形成实体反射，消失的球不留下空气碰撞。
  if(p[a].info.w!=0u&&p[b].info.w!=0u)reflect_contact(a,p[b].pv.xy,r,n);
  if(p[b].info.w!=0u){p[b].geom.x=ball_radius(b);index_coarse_ball(b);}return;
 }
 bool fresh=!(ball_contact_mask(a,b)&&ball_contact_mask(b,a));set_ball_contact_mask(a,b,true);set_ball_contact_mask(b,a,true);
 // 整个接触固定使用碰撞前的质量、硬度、能量和法向速度快照。
 // 先求机械冲量，再记账损耗；质量变小绝不反推或放大已经求出的碰撞速度。
 float ma=contact_mass(a),mb=contact_mass(b);
 float hardness_a=contact_hardness(a),hardness_b=contact_hardness(b);
 uvec2 energy_a=energy(a),energy_b=energy(b);
 float restitution=min(contact_restitution(a),contact_restitution(b));
 if(approaching>0.0){float impulse=(1.0+restitution)*approaching/(1.0/ma+1.0/mb);p[a].pv.zw+=impulse/ma*n;p[b].pv.zw-=impulse/mb*n;}
 float overlap=max(r-dot(p[a].pv.xy-p[b].pv.xy,n),0.0)+0.02;p[a].pv.xy+=n*overlap*mb/(ma+mb);p[b].pv.xy-=n*overlap*ma/(ma+mb);
 confine_after_contact(a);confine_after_contact(b);
 if(p[a].info.z!=p[b].info.z&&fresh&&approaching>1.0){
  float impact=clamp(approaching/max(par[3].w,40.0),0.0,1.0);float disparity=1.0-min(ma,mb)/max(ma,mb);
  float softness_difference=abs(hardness_a-hardness_b);
  float fraction=clamp(0.14+0.44*impact+0.32*disparity+0.08*softness_difference,0.08,0.96);
  uvec2 cancel=impact_wear(min64(energy_a,energy_b),fraction);spend(a,cancel);spend(b,cancel);consumed(cancel);consumed(cancel);
 }
 if(p[a].info.w!=0u){p[a].geom.x=ball_radius(a);index_coarse_ball(a);}if(p[b].info.w!=0u){p[b].geom.x=ball_radius(b);index_coarse_ball(b);}

}
void particle_ball_pair(uint a,uint b) {
 if(p[a].info.w==0u||p[b].info.w==0u)return;
 record_candidate();
 bool both_big=p[a].info.w==3u&&p[b].info.w==3u;
 float r=p[a].geom.x+p[b].geom.x;
 float time;vec2 n;bool hit=swept_ball_contact(a,b,time,n);
 if(!hit){if(both_big){set_ball_contact_mask(a,b,false);set_ball_contact_mask(b,a,false);}return;}
 apply_ball_contact(a,b,n);
}

void claim(uint i,uint index) {if(p[i].info.w==0u||owner[index]==p[i].info.z)return;
 // 所有实体每个实际变更的格子恰扣1真实能量；高能弹丸保留余能继续移动。
 uvec2 remaining=energy(i);uvec2 cost=uvec2(1u,0u);
 if(less64(remaining,cost)){set_energy(i,uvec2(0u));consumed(remaining);return;}
 set_territory_owner(index,p[i].info.z);spend(i,cost);stat[3]++;consumed(cost);
}
// 圆与格子有正面积重叠才染色；沿边擦过、只碰到一个角不凭空增加覆盖。
// 圆角扩张矩形是两条开矩形与四个开圆的并集，返回真实最早进入时刻。
bool terrain_open_box_entry(vec2 a,vec2 ray,vec2 low,vec2 high,out float entry) {
 float first=0.0,last=1.0;
 for(int axis=0;axis<2;axis++){
  if(ray[axis]==0.0){if(a[axis]<=low[axis]||a[axis]>=high[axis])return false;}
  else {float t0=(low[axis]-a[axis])/ray[axis],t1=(high[axis]-a[axis])/ray[axis];first=max(first,min(t0,t1));last=min(last,max(t0,t1));}
 }
 entry=first;return first<last;
}
bool terrain_open_circle_entry(vec2 a,vec2 ray,vec2 center,float radius,out float entry) {
 vec2 offset=a-center;float c=dot(offset,offset)-radius*radius;
 if(c<0.0){entry=0.0;return true;}
 float aa=dot(ray,ray),bb=dot(offset,ray);if(aa==0.0||bb>=0.0)return false;
 float perpendicular=offset.x*ray.y-offset.y*ray.x;
 float discriminant=aa*radius*radius-perpendicular*perpendicular;if(discriminant<=0.0)return false;
 // c/(-b+sqrt(D))避免从远处接近时两个接近的大浮点数相减。
 float denominator=-bb+sqrt(discriminant);float first=c/denominator,last=denominator/aa;
 entry=max(first,0.0);return entry<min(last,1.0);
}
bool terrain_cell_entry(vec2 a,vec2 ray,float radius,vec2 low,vec2 high,out float entry) {
 vec2 separation=max(max(low-a,a-high),vec2(0.0));entry=2.0;
 if(dot(separation,separation)<radius*radius){entry=0.0;return true;}
 float hit;
 if(terrain_open_box_entry(a,ray,low-vec2(radius,0.0),high+vec2(radius,0.0),hit))entry=min(entry,hit);
 if(terrain_open_box_entry(a,ray,low-vec2(0.0,radius),high+vec2(0.0,radius),hit))entry=min(entry,hit);
 for(int corner=0;corner<4;corner++){
  vec2 center=vec2((corner&1)==0?low.x:high.x,(corner&2)==0?low.y:high.y);
  if(terrain_open_circle_entry(a,ray,center,radius,hit))entry=min(entry,hit);
 }
 return entry<=1.0;
}
struct TerrainCandidate {float time;uint index;};
bool terrain_earlier(TerrainCandidate a,TerrainCandidate b) {return a.time<b.time||(a.time==b.time&&a.index<b.index);}
void terrain_heap_sift(inout TerrainCandidate heap[32],uint count,uint root) {
 while(root*2u+1u<count){uint child=root*2u+1u;if(child+1u<count&&terrain_earlier(heap[child],heap[child+1u]))child++;
  if(!terrain_earlier(heap[root],heap[child]))break;TerrainCandidate swap=heap[root];heap[root]=heap[child];heap[child]=swap;root=child;
 }
}
bool terrain_skip_start_overlap=false;
void terrain_events(uint i) {if(p[i].info.w==0u)return;uint n=terrain_size(),own=p[i].info.z;
 // 每颗实体读取当下权威面积，不跨实体缓存；保留全图己色捷径与大球半径刷新。
 if(own<4u&&stat[8u+own]==n*n){if(p[i].info.w==3u)p[i].geom.x=ball_radius(i);return;}
 float unit=world()/float(n),radius=p[i].geom.x;vec2 a=p[i].geom.zw,b=p[i].pv.xy,ray=b-a;
 if(radius<=0.0)return;
 int low_y=max(0,int(floor((min(a.y,b.y)-radius)/unit)));
 int high_y=min(int(n)-1,int(floor((max(a.y,b.y)+radius)/unit)));
 // 32仅是局部排序工作区，不是路径/候选上限；长轨迹与大球继续分批直到全部结算。
 // 已改色格自然从后续批次退出，避免额外GPU缓冲及每实体清空整张地图。
 TerrainCandidate heap[32];
 while(p[i].info.w!=0u){uint count=0u;uvec2 available=energy(i);uint limit=available.y==0u?min(available.x,32u):32u;if(limit==0u)break;
  for(int y=low_y;y<=high_y;y++){
   float row_low=float(y)*unit,row_high=row_low+unit,first=0.0,last=1.0;
   if(ray.y==0.0){if(a.y<=row_low-radius||a.y>=row_high+radius)continue;}
   else {float t0=(row_low-radius-a.y)/ray.y,t1=(row_high+radius-a.y)/ray.y;first=max(first,min(t0,t1));last=min(last,max(t0,t1));if(first>=last)continue;}
   // 逐行收紧候选到扫掠窄带，不遍历长对角轨迹的整块包围盒。
   float x0=a.x+ray.x*first,x1=a.x+ray.x*last;
   int low_x=max(0,int(floor((min(x0,x1)-radius)/unit)));
   int high_x=min(int(n)-1,int(floor((max(x0,x1)+radius)/unit)));
   for(int x=low_x;x<=high_x;x++){uint index=uint(y)*n+uint(x);if(owner[index]==own)continue;
    float hit;vec2 low=vec2(float(x)*unit,row_low);
    // 前缀已结算过起始圆帽；仅跳过严格重叠，边界相切后新进入的格仍须扣账。
    if(terrain_skip_start_overlap&&terrain_cell_entry(a,vec2(0.0),radius,low,low+vec2(unit),hit))continue;
    if(!terrain_cell_entry(a,ray,radius,low,low+vec2(unit),hit))continue;
    // t=0的所有格都最早，直接结算以免大球的初始足迹被重复排序扫描。
    if(hit==0.0){claim(i,index);if(p[i].info.w==0u){p[i].pv.xy=a;return;}continue;}
    TerrainCandidate candidate=TerrainCandidate(hit,index);
    if(count<limit){uint cursor=count++;heap[cursor]=candidate;
     while(cursor>0u){uint parent=(cursor-1u)/2u;if(!terrain_earlier(heap[parent],heap[cursor]))break;TerrainCandidate swap=heap[parent];heap[parent]=heap[cursor];heap[cursor]=swap;cursor=parent;}
    }else if(terrain_earlier(candidate,heap[0])){heap[0]=candidate;terrain_heap_sift(heap,count,0u);}
   }
  }
  if(count==0u)break;
  // 最大堆原地排序为真实进入时刻升序；同一时刻用格子ID稳定打破平局。
  for(uint end=count;end>1u;end--){TerrainCandidate swap=heap[0];heap[0]=heap[end-1u];heap[end-1u]=swap;terrain_heap_sift(heap,end-1u,0u);}
  for(uint k=0u;k<count;k++){claim(i,heap[k].index);if(p[i].info.w==0u){p[i].pv.xy=mix(a,b,heap[k].time);return;}}
 }
 if(p[i].info.w==3u)p[i].geom.x=ball_radius(i);
}
// 首接触前缀只读几何，不在这里提前执行碰撞、反弹或死亡余波。
float prefix_pair_time(uint a,uint b,float stop) {
 if(a==b||p[b].info.w==0u||stop<=motion_start(a))return stop;
 if(p[a].info.z==p[b].info.z&&(p[a].info.w==2u||p[b].info.w==2u||par[12].w<0.5))return stop;
 float radius=p[a].geom.x+p[b].geom.x;
 if(!wall_motion(a)&&!wall_motion(b)){
  if(any(lessThan(max(p[a].geom.zw,p[a].pv.xy)+vec2(radius),min(p[b].geom.zw,p[b].pv.xy)))||any(lessThan(max(p[b].geom.zw,p[b].pv.xy)+vec2(radius),min(p[a].geom.zw,p[a].pv.xy))))return stop;
  float common_time=max(motion_start(a),motion_start(b)),fraction;
  vec2 delta=motion_from(b,common_time)-motion_from(a,common_time),relative=p[b].pv.xy-p[a].pv.xy-delta;
  if(linear_contact_entry(delta,relative,radius,fraction))return min(stop,mix(common_time,max(pc.clock.x,common_time),fraction));
  return stop;
 }
 vec2 delta,sign_a,sign_b;float hit_time;
 if(folded_pair_contact(a,b,radius,true,delta,sign_a,sign_b,hit_time))return min(stop,hit_time);
 return stop;
}
void preclaim_contact_prefixes() {
 uint count=active_count();float duration=max(pc.clock.x,0.0);
 uvec2 prefix_balls=uvec2(0u);for(uint k=0u;k<balls();k++)if(p[cap()+k].info.w==3u)prefix_balls[k/32u]|=1u<<(k%32u);
 bool has_wide=false;
 for(uint ordinal=0u;ordinal<count;ordinal++){uint i=active_id(ordinal);terrain_paid_until[i]=-1.0;has_wide=has_wide||(p[i].info.w==2u&&p[i].aux.w==2u);}
 for(uint ordinal=0u;ordinal<count;ordinal++){
  uint a=active_id(ordinal);if(p[a].info.w!=1u&&p[a].info.w!=2u)continue;
  float start=clamp(motion_start(a),0.0,duration),stop=duration,travel=duration-start;
  vec2 from=p[a].geom.zw,to=p[a].pv.xy,ray=to-from;float radius=p[a].geom.x;
  // 只处理首面墙之前的真实直线；反射之后仍由原实体事件循环逐段处理。
  for(int axis=0;axis<2;axis++)if(abs(ray[axis])>0.0000001){
   float boundary=ray[axis]>0.0?world()-radius:radius;float fraction=(boundary-from[axis])/ray[axis];
   if(fraction>=0.0&&fraction<=1.0)stop=min(stop,start+travel*fraction);
  }
  for(uint t=0u;t<4u;t++)if(t!=p[a].info.z&&team[t].life.x!=2u){
   float r=zero64(team[t].shield_gun.xy)?team[t].core.z:shield_radius(t);float hit;vec2 normal;
   if(swept_hit(from,to,team[t].core.xy,r+radius,hit,normal))stop=min(stop,start+travel*hit);
  }
  for(uint word=0u;word<2u;word++){uint bits=prefix_balls[word];while(bits!=0u){uint b=cap()+word*32u+uint(findLSB(bits));bits&=bits-1u;
    vec2 ball_from=mix(p[b].geom.zw,p[b].pv.xy,duration>0.0?start/duration:0.0);float hit;vec2 normal;
    if(swept_hit(from-ball_from,to-p[b].pv.xy,vec2(0),radius+p[b].geom.x,hit,normal))stop=min(stop,start+travel*hit);
  }}
  if(p[a].aux.w==1u){
   for(uint k=0u;k<count&&stop>start;k++)stop=prefix_pair_time(a,active_id(k),stop);
  }else{
   uint cell=cell_index(pair_endpoint(a));ivec2 center=ivec2(int(cell%cols()),int(cell/cols()));
   ivec4 query=p[a].aux.w==2u?projectile_query_bounds(a,par[4].x,par[1].y,cols()):ivec4(center-ivec2(1),center+ivec2(1));
   for(int y=query.y;y<=query.w&&stop>start;y++)for(int x=query.x;x<=query.z&&stop>start;x++){ivec2 q=ivec2(x,y);
    if(any(lessThan(q,ivec2(0)))||any(greaterThanEqual(q,ivec2(cols()))))continue;
    uint bucket=uint(q.y)*cols()+uint(q.x);
    for(uint t=0u;t<4u&&stop>start;t++){int b=head[t*cols()*cols()+bucket];while(b>=0&&stop>start){stop=prefix_pair_time(a,uint(b),stop);b=next_id[b];}}
   }
   if(has_wide){ivec4 wide_query=projectile_query_bounds(a,SNIPER_MAX_RADIUS,32.0,WIDE_COLUMNS);
    for(int y=wide_query.y;y<=wide_query.w&&stop>start;y++)for(int x=wide_query.x;x<=wide_query.z&&stop>start;x++){
     uint bucket=uint(y)*WIDE_COLUMNS+uint(x);
     for(uint t=0u;t<4u&&stop>start;t++){uint b=wide_space[t*WIDE_COLUMNS*WIDE_COLUMNS+bucket];while(b!=0xffffffffu&&stop>start){stop=prefix_pair_time(a,b,stop);b=wide_space[WIDE_HEADS+b];}}
    }
   }
   uint fast=stat[30];while(fast!=0xffffffffu&&stop>start){stop=prefix_pair_time(a,fast,stop);fast=uint(next_id[fast]);}
  }
  stop=clamp(stop,start,duration);float fraction=travel>0.0000001?(stop-start)/travel:0.0;
  p[a].pv.xy=mix(from,to,fraction);terrain_events(a);terrain_paid_until[a]=stop;
  // 耗尽者保留真实最后染色位置；存活者恢复整段几何供原有碰撞pass使用。
  if(p[a].info.w!=0u)p[a].pv.xy=to;
  p[a].geom.zw=from;
 }
}
void terrain_events_after_prefix(uint i,float begin,float end) {
 float paid=terrain_paid_until[i];if(paid>=0.0&&paid>=end)return;
 vec2 original=p[i].geom.zw;
 bool clipped=paid>=0.0&&paid>=begin;
 if(clipped&&end>begin)p[i].geom.zw=mix(original,p[i].pv.xy,clamp((paid-begin)/(end-begin),0.0,1.0));
 terrain_skip_start_overlap=clipped;
 terrain_events(i);
 terrain_skip_start_overlap=false;p[i].geom.zw=original;
}
void resolve_wide_projectiles(uint count) {
 for(uint ordinal=0u;ordinal<count;ordinal++){uint a=active_id(ordinal);if(p[a].info.w!=2u||p[a].aux.w!=2u)continue;
  ivec4 normal_query=projectile_query_bounds(a,par[4].x,par[1].y,cols());
  for(int y=normal_query.y;y<=normal_query.w&&p[a].info.w!=0u;y++)for(int x=normal_query.x;x<=normal_query.z&&p[a].info.w!=0u;x++){
   uint bucket=uint(y)*cols()+uint(x);
   for(uint t=0u;t<4u&&p[a].info.w!=0u;t++){int b=head[t*cols()*cols()+bucket];while(b>=0&&p[a].info.w!=0u){resolve_pair(a,uint(b));b=next_id[b];}}
  }
  ivec4 wide_query=projectile_query_bounds(a,SNIPER_MAX_RADIUS,32.0,WIDE_COLUMNS);
  for(int y=wide_query.y;y<=wide_query.w&&p[a].info.w!=0u;y++)for(int x=wide_query.x;x<=wide_query.z&&p[a].info.w!=0u;x++){
   uint bucket=uint(y)*WIDE_COLUMNS+uint(x);
   for(uint t=0u;t<4u&&p[a].info.w!=0u;t++){uint b=wide_space[t*WIDE_COLUMNS*WIDE_COLUMNS+bucket];while(b!=0xffffffffu&&p[a].info.w!=0u){if(b>a)resolve_pair(a,b);b=wide_space[WIDE_HEADS+b];}}
  }
  uint fast=stat[30];while(fast!=0xffffffffu&&p[a].info.w!=0u){resolve_pair(a,fast);fast=uint(next_id[fast]);}
 }
}
// 只有真实墙/敌盾/敌大球新接触设置bit30；普通粒子与领土消耗不触发分裂。
// 此函数在事件末调用，入口活跃ID快照之外的新子弹从下一子步才参加物理。
// 普通高能弹与狙击均先逐段每格扣1能，再处理该段最早实体；余能和反射余时继续移动。
// 大球位置按本子步已过去的比例插值；机枪新生弹从真实出生时刻开始，不能倒流碰撞。
void projectile_entity_events(uint i,bool has_balls) {
 float duration=max(pc.clock.x,0.0),start=clamp(motion_start(i),0.0,duration);
 float remaining_time=duration-start,elapsed_fraction=duration>0.0000001?start/duration:0.0;
 uint contacts=0u;bool first_segment=true;
 // 零时长也处理当前点；墙段不占实体重叠预算，实际高速折返次数不截断。
 while((p[i].info.w==1u||p[i].info.w==2u)&&(remaining_time>0.0000001||first_segment)&&contacts<72u){
  first_segment=false;
  vec2 from=p[i].geom.zw,to=p[i].pv.xy;float first_time=2.0;vec2 normal=vec2(1,0);
  int target=-1;uint kind=0u;float target_radius=0.0;bool target_shield=false;
  uvec2 candidates=has_balls?coarse_ball_candidates(i):uvec2(0u);
  for(uint word=0u;word<2u;word++){uint bits=candidates[word];while(bits!=0u){uint b=cap()+word*32u+uint(findLSB(bits));bits&=bits-1u;
   if(p[b].info.w!=3u)continue;float hit_t;vec2 hit_normal;
   vec2 ball_from=mix(p[b].geom.zw,p[b].pv.xy,elapsed_fraction);
   if(swept_hit(from-ball_from,to-p[b].pv.xy,vec2(0),p[i].geom.x+p[b].geom.x,hit_t,hit_normal)&&hit_t<first_time){target=int(b);kind=1u;first_time=hit_t;normal=hit_normal;}
  }}
  for(uint t=0u;t<4u;t++){if(t==p[i].info.z||team[t].life.x==2u)continue;
   bool shield=!zero64(team[t].shield_gun.xy);float radius=shield?shield_radius(t):team[t].core.z;float hit_t;vec2 hit_normal;
   if(swept_hit(from,to,team[t].core.xy,radius+p[i].geom.x,hit_t,hit_normal)&&hit_t<first_time){target=int(t);kind=2u;first_time=hit_t;normal=hit_normal;target_radius=radius;target_shield=shield;}
  }
  // 首段与反射后的余程都按真实到墙时刻排序，避免预先折回终点的虚假弦轨迹。
  {float radius=p[i].geom.x;vec2 ray=to-from;
   for(int axis=0;axis<2;axis++){if(abs(ray[axis])<0.0000001)continue;
    float boundary=ray[axis]>0.0?world()-radius:radius;float hit_t=(boundary-from[axis])/ray[axis];
    if(hit_t>=0.0&&hit_t<=1.0&&hit_t<first_time){target=axis;kind=3u;first_time=hit_t;normal=vec2(0);normal[axis]=ray[axis]>0.0?-1.0:1.0;}
   }
  }
  if(target<0){terrain_events_after_prefix(i,elapsed_fraction*duration,duration);return;}
  vec2 geometry_velocity=remaining_time>0.0000001?(to-from)/remaining_time:vec2(0.0);
  p[i].pv.xy=mix(from,to,first_time);
  if(kind==3u)p[i].pv[target]=normal[target]>0.0?p[i].geom.x:world()-p[i].geom.x;
  float contact_time=(elapsed_fraction+(1.0-elapsed_fraction)*first_time)*duration;
  terrain_events_after_prefix(i,elapsed_fraction*duration,contact_time);if(p[i].info.w==0u)return;
  if(kind==1u){record_candidate();apply_ball_contact(i,uint(target),normal);}
  else if(kind==2u)apply_core_contact(i,uint(target),normal,target_radius,target_shield);
  else {p[i].pv.zw=reflect(p[i].pv.zw,normal);if(p[i].info.w==2u)p[i].aux.z|=0x40000000u;}
  if(p[i].info.w==0u)return;
  // 只重新推进碰撞后未使用的时间，不会重新走完已结算的整条旧轨迹。
  elapsed_fraction+=(1.0-elapsed_fraction)*clamp(first_time,0.0,1.0);
  remaining_time*=1.0-clamp(first_time,0.0,1.0);
  p[i].geom.zw=p[i].pv.xy;
  p[i].pv.xy+=(kind==3u?reflect(geometry_velocity,normal):p[i].pv.zw)*remaining_time;
  if(kind!=3u)contacts++;
 }
 // 不可解的重叠实体几何只允许停在最后一个合法接触点，避免无限零TOI循环。
 // 正常运动没有此预算截断；72高于一子步全部64大球+4核心的独立接触数。
 if(p[i].info.w!=0u&&contacts>=72u)p[i].pv.xy=p[i].geom.zw;
}
void resolve_sniper_splits(uint event_count) {
 for(uint ordinal=0u;ordinal<event_count;ordinal++) {
  uint i=active_id(ordinal);if(p[i].info.w!=2u||(p[i].aux.z&0x40000000u)==0u)continue;
  uint level=clamp(p[i].aux.y&3u,1u,3u);if(level>=3u){p[i].aux.z&=~0x40000000u;continue;}
  uvec2 before=energy(i);uint remainder;uvec2 quotient=divide64_small(before,10u,remainder);
  uvec2 child_energy=add64(add64(quotient,quotient),quotient);child_energy=add64(child_energy,uvec2((remainder*3u)/10u,0u));
  if(zero64(child_energy)){p[i].aux.y=(p[i].aux.y&~3u)|(level+1u);p[i].aux.z&=~0x40000000u;continue;}
  int slot=free_sniper_slot();if(slot<0)continue; // 不消耗、不改方向；保留bit30稍后重试。
  uint child=uint(slot);uint child_generation=next_particle_generation(child);p[child]=p[i];set_particle_generation(child,child_generation);uvec2 parent_energy=sub64(before,child_energy);
  float angle=clamp(par[14].z,0.0,30.0)*TAU/360.0;float c=cos(angle),s=sin(angle);vec2 velocity=p[i].pv.zw;
  p[i].pv.zw=vec2(c*velocity.x-s*velocity.y,s*velocity.x+c*velocity.y);
  p[child].pv.zw=vec2(c*velocity.x+s*velocity.y,-s*velocity.x+c*velocity.y);
  p[i].info.xy=parent_energy;p[child].info.xy=child_energy;
  p[i].aux.y=(p[i].aux.y&~3u)|(level+1u);p[child].aux.y=(p[child].aux.y&~3u)|4u|(level+1u);p[i].aux.z&=~0x40000000u;p[child].aux.z&=~0x40000000u;
  p[i].geom.x=sniper_radius_for_energy(parent_energy);p[child].geom.x=sniper_radius_for_energy(child_energy);
  p[i].geom.zw=p[i].pv.xy;p[child].geom.zw=p[child].pv.xy;
  weapon[p[i].info.z].reserved.z++;stat[16]++;
 }
}
void events() {
 bool pending_sniper_split=false;
 coarse_balls_ready=false;
 for(uint b=0u;b<64u;b++){pending_ball_push[b]=vec2(0.0);uint i=cap()+b;pending_ball_mass[b]=b<balls()&&p[i].info.w==3u?contact_mass(i):1.0;}
 // 超出九色网格安全位移的少量粒子单独串行回退，不限速、不丢步、不截断候选。
 // aux.w由build_space锁定本子步分类；不能在碰撞位置修正后重新推断分类。
 uint event_count=active_count();
 uint fast=stat[30];while(fast!=0xffffffffu){uint following=uint(next_id[fast]);if(p[fast].info.w!=0u){for(uint k=0u;k<event_count&&p[fast].info.w!=0u;k++){uint b=active_id(k);if(b!=fast&&p[b].info.w!=0u&&p[b].aux.w!=2u&&(p[b].aux.w==0u||b>fast))resolve_pair(fast,b);}}fast=following;}
 resolve_wide_projectiles(event_count);
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
 bool has_balls=any(notEqual(active_balls,uvec2(0u)));
 for(uint ordinal=0u;ordinal<event_count;ordinal++){uint a=active_id(ordinal);
  if(p[a].info.w==1u||p[a].info.w==2u){
   uint type=p[a].info.w;
   // 地形消耗与实体使用同一TOI顺序；前方一格不再吞光高能弹，也不能跳过其真实1能损耗。
   projectile_entity_events(a,has_balls);confine_after_contact(a);maintain_motion(a);
   if(type==1u)p[a].aux.z&=0x7fffffffu;
   else if(p[a].info.w==2u&&(p[a].aux.z&0x40000000u)!=0u)pending_sniper_split=true;
  }
 }
 for(uint b=0u;b<balls();b++){uint i=cap()+b;if(p[i].info.w==3u)shield_core_events(i);}
 for(uint b=0u;b<balls();b++){uint i=cap()+b;if(p[i].info.w!=3u)continue;
  p[i].geom.x=ball_radius(i);vec2 delta=pending_ball_push[b]/pending_ball_mass[b];
  // 使用最大分量归一化，避免trillion级输入令length(delta)的平方溢出。
  float component=max(abs(delta.x),abs(delta.y));if(component>0.0){vec2 scaled=delta/component;float normalized_length=length(scaled);
   float maximum_change=300.0*pc.clock.x;float change=maximum_change/(1.0+(maximum_change/component)/normalized_length);
   p[i].pv.zw+=scaled*(change/normalized_length);
  }
  // 碰撞/整步机枪冲量结束只缓存航向并约束位置；基础推进留到下一子步移动前。
  maintain_motion(i);confine_after_contact(i);maintain_motion(i);
 }
 if(pending_sniper_split)resolve_sniper_splits(event_count);
 update_shields();
}
void statistics() {
 stat[0]=0u;stat[1]=0u;stat[12]=0u;stat[13]=0u;stat[22]=0u;uvec2 normal_energy=uvec2(0u);
 for(uint t=0u;t<4u;t++)dispatch_data[16u+t]=0u;
 for(uint ordinal=0u;ordinal<active_count()+balls();ordinal++){uint i=ordinal<active_count()?active_id(ordinal):cap()+ordinal-active_count();if(p[i].info.w!=0u){if(p[i].info.z<4u)dispatch_data[16u+p[i].info.z]++;if(p[i].info.w==3u)stat[1]++;else {stat[0]++;normal_energy=add64(normal_energy,energy(i));}}}
 stat[23]=normal_energy.x;stat[24]=normal_energy.y;
 for(uint t=0u;t<4u;t++){if(team[t].life.x==1u)stat[12]|=1u<<t;if(team[t].life.x==2u)stat[13]|=1u<<t;}
 // stat[8..11]由初始化/claim/显式调试染色精确维护；这里不再扫描512²地图。
}
void splat(uint i) {if(i>=total()||p[i].info.w==0u)return;bool sniper=p[i].info.w==2u,secondary=sniper&&(p[i].aux.y&4u)!=0u;if(p[i].info.w!=3u&&!sniper&&random01(i)>par[7].z)return;
 uint n=render_size();float scale=float(n)/world();vec2 a=p[i].geom.zw*scale,b=p[i].pv.xy*scale;float r=max((p[i].info.w==3u||sniper)?p[i].geom.x*scale:par[7].x*scale,0.8);vec2 d=b-a;float dd=dot(d,d);
 // 有界的移动弹身，宽度跟随实际半径；尾迹只负责显示，不延长碰撞或染色路径。
 if(sniper){float tail=secondary?clamp(p[i].geom.x*1.7+3.0,6.0,18.0):clamp(p[i].geom.x*3.0+6.0,10.0,32.0);a=b-normal_or(p[i].pv.zw,vec2(1,0))*tail*scale;r=max(r,1.0);}else a=mix(b,a,clamp(par[7].y,0.0,1.0));
 d=b-a;dd=dot(d,d);
 ivec2 lo=max(ivec2(0),ivec2(floor(min(a,b)-r-1.0)));ivec2 hi=min(ivec2(int(n)-1),ivec2(ceil(max(a,b)+r+1.0)));uint color=p[i].info.z+1u;
 for(int y=lo.y;y<=hi.y;y++)for(int x=lo.x;x<=hi.x;x++){vec2 q=vec2(x,y)+0.5;float t=dd>0.0001?clamp(dot(q-a,b-a)/max(dot(b-a,b-a),0.0001),0.0,1.0):1.0;float dist=distance(q,mix(a,b,t));float width=sniper?r*mix(secondary?0.30:0.18,1.0,smoothstep(0.0,0.9,t)):r;if(dist<=width){float intensity=clamp(1.0-dist/max(width,0.1),0.0,1.0);if(sniper)intensity*=mix(0.35,1.0,t);uint bright=uint(intensity*255.0);
  // bit16主弹优先级低于类型位，高于亮度：主弹不会被子弹尾迹覆盖。
  uint packed=(p[i].info.w==3u?0x1000000u:(sniper?(0x2000000u|(secondary?0u:0x10000u)):0u))|(bright<<8)|color;atomicMax(pixels[uint(y)*n+uint(x)],packed);}}
}
void render(uint i) {uint n=render_size();if(i>=n*n)return;uint x=i%n,y=i/n;vec2 q=(vec2(x,y)+0.5)/float(n)*world();uint t=owner[territory_index(q)];vec3 c=t<4u?team_color(t)*0.22:vec3(0.07,0.09,0.13);
 uint tn=terrain_size();ivec2 tp=clamp(ivec2(q/world()*float(tn)),ivec2(0),ivec2(int(tn)-1));if(tp.x<int(tn)-1&&owner[uint(tp.y)*tn+uint(tp.x)+1u]!=t)c*=1.35;if(tp.y<int(tn)-1&&owner[(uint(tp.y)+1u)*tn+uint(tp.x)]!=t)c*=1.35;
 for(uint k=0u;k<4u;k++){if(team[k].life.x==2u)continue;float distance_core=distance(q,team[k].core.xy);float shield=team[k].core.w;
 if(shield>0.0){float ring=1.0-smoothstep(0.6,2.0,abs(distance_core-shield));c=mix(c,team_color(k)*0.9,ring*0.8);if(distance_core<shield)c+=team_color(k)*0.018;}
 if(distance_core<team[k].core.z){float glow=1.0-distance_core/team[k].core.z;c=team_color(k)*(0.75+0.5*glow);if(team[k].life.x==1u)c=mix(c,vec3(1),0.35+0.25*sin(pc.clock.y*15.0));}
 vec2 gun=team[k].core.xy+direction(team[k].clocks.z)*(team[k].core.z+4.0);if(distance(q,gun)<3.0)c=vec3(1.0);
 }
 uint packed=pixels[i];if(packed!=0u){uint color=(packed&255u)-1u;float bright=float((packed>>8)&255u)/255.0;bool big=(packed&0x1000000u)!=0u,sniper=(packed&0x2000000u)!=0u;vec3 tint=team_color(color);
  if(sniper){bool primary=(packed&0x10000u)!=0u;c=primary?mix(tint*0.80,vec3(1.0),smoothstep(0.05,0.80,bright)):mix(tint*0.65,mix(tint,vec3(1.0),0.30),bright);}
  else c=big?mix(tint*0.45,vec3(1),bright*0.60):mix(tint,vec3(1),bright*0.65);}
 for(uint k=0u;k<4u;k++){
  if(team[k].misc.y==1u&&team[k].life.x!=2u){float charge=clamp((pc.clock.y-team[k].visual.w)/max(par[12].y,0.001),0.0,1.0);vec2 emitter=team[k].core.xy+direction(uintBitsToFloat(team[k].misc.x))*(team[k].core.z+3.0);float dist=distance(q,emitter);
   float glow=exp(-dist*dist/(12.0+charge*80.0));c+=mix(team_color(k),vec3(1.0),charge*0.7)*glow*(0.25+charge*0.9);}

 }
 float edge=min(min(q.x,q.y),min(world()-q.x,world()-q.y));if(edge<2.0)c=vec3(0.43,0.58,0.73);imageStore(output_image,ivec2(x,y),vec4(clamp(c,0.0,1.0),1.0));
}
void main(){uint i=gl_GlobalInvocationID.x;uint mode=pc.control.x;
 if(mode==0u)initialize(i);else if(mode==1u){if(i==0u)prepare();}else if(mode==2u){if(i<active_count()+balls())move_particle(i<active_count()?active_id(i):cap()+i-active_count());}else if(mode==3u){if(i<WIDE_HEADS)wide_space[i]=0xffffffffu;if(i<cols()*cols()*4u)head[i]=-1;if(i==0u)stat[30]=0xffffffffu;if(i<4u){team[i].accounting.x=0xffffffffu;team[i].life.w=0xffffffffu;}}else if(mode==4u){if(i<active_count())build_space(active_id(i));}else if(mode==5u)collision_cell(i);else if(mode==6u){if(i==0u)events();}else if(mode==7u){if(i==0u)statistics();}else if(mode==8u){if(i<render_size()*render_size())pixels[i]=0u;}else if(mode==9u){if(i<active_count()+balls())splat(i<active_count()?active_id(i):cap()+i-active_count());}else if(mode==10u)render(i);else if(mode==11u){if(i==0u)refresh_indirect();}else if(mode==12u){if(i==0u)compact_pool();}else if(mode==13u){if(i==0u)preclaim_contact_prefixes();}
}
