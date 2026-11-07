(function(){
"use strict";
let spinBusy=false,questFrame=0,questSession=null,questRunning=false,questGameCleanup=null;
const byId=id=>document.getElementById(id);
const money=n=>new Intl.NumberFormat("id-ID",{style:"currency",currency:"IDR",maximumFractionDigits:0}).format(Number(n)||0);
async function rpc(name,args){
 const client=window.lexiaaNgWalletBridge?.supabase;if(!client)throw new Error("Koneksi Wallet belum siap. Muat ulang halaman.");
 const {data,error}=await client.rpc(name,args||{});
 if(error)throw new Error(error.message||"Permintaan gagal.");
 const result=Array.isArray(data)?data[0]:data;
 if(!result||result.success!==true)throw new Error(result?.message||"Permintaan tidak berhasil.");
 return result;
}
function backToWallet(){
 if(questGameCleanup){questGameCleanup();questGameCleanup=null;}
 questRunning=false;questSession=null;
 window.lexiaaNgWalletBridge.showAccount(window.lexiaaNgWalletBridge.state.account||{});
}
async function status(){
 return await rpc("ng_wallet_spin_status");
}
function spinPageMarkup(s){
 return '<div class="ng-spin-page"><button class="ng-spin-back" id="ngSpinBack" type="button">← Kembali ke Wallet</button><div class="ng-spin-stats"><div class="ng-spin-stat"><b id="ngSpinDaily">'+s.daily_free_spins+'</b><small>Putaran gratis hari ini</small></div><div class="ng-spin-stat"><b id="ngSpinQuest">'+s.quest_spins+'</b><small>Putaran dari Quest</small></div></div><div class="ng-spin-wheel-wrap"><div class="ng-spin-pointer"></div><div class="ng-spin-wheel" id="ngSpinWheel"><span class="ng-wheel-label l0">ZONK</span><span class="ng-wheel-label l1">Rp1 JUTA</span><span class="ng-wheel-label l2">Rp2 JUTA</span><span class="ng-wheel-label l3">Rp3 JUTA</span><span class="ng-wheel-label l4">Rp100 JUTA</span><span class="ng-wheel-label l5">Rp999 JUTA</span><span class="ng-wheel-label l6">Rp1 M</span><span class="ng-wheel-core">LEXIAA</span></div></div><button class="ng-spin-action" id="ngSpinNow" type="button">PUTAR RODA HADIAH</button><div class="ng-spin-result" id="ngSpinResult" hidden></div><p class="ng-spin-note">10 putaran gratis setiap hari WIB. '+ 'Peluang: ZONK 40% · Rp1 juta 40% · Rp2 juta 10% · Rp3 juta 5% · Rp100 juta 4% · Rp999 juta 0,9% · Rp1 miliar 0,1%.' + ' Hadiah besar sangat langka; hasil ditentukan server. Quest memberi putaran tambahan.</p><button class="ng-spin-action" id="ngQuestOpen" type="button">MAIN QUEST · DAPATKAN SPIN</button></div>';
}
async function openSpin(){
 try{
  const s=await status();
  window.lexiaaNgWalletBridge.shell("SPIN & QUEST LEXIAA",spinPageMarkup(s));
  byId("ngSpinBack").onclick=backToWallet;
  byId("ngQuestOpen").onclick=openQuest;
  byId("ngSpinNow").onclick=doSpin;
 }catch(e){await window.lexiaaNgWalletBridge.dialog({title:"Spin Belum Siap",message:e.message,actions:[{label:"TUTUP"}]});}
}
async function refreshSpinStats(){
 const s=await status();
 if(byId("ngSpinDaily"))byId("ngSpinDaily").textContent=s.daily_free_spins;
 if(byId("ngSpinQuest"))byId("ngSpinQuest").textContent=s.quest_spins;
 return s;
}
async function doSpin(){
 if(spinBusy)return;
 const button=byId("ngSpinNow"),wheel=byId("ngSpinWheel"),resultBox=byId("ngSpinResult");
 if(!button||!wheel)return;
 spinBusy=true;button.disabled=true;button.textContent="LEXIAA SEDANG MEMUTAR...";
 resultBox.hidden=true;
 try{
  const result=await rpc("ng_wallet_spin");
  const current=Number(wheel.dataset.turn||0)+1800+Math.floor(Math.random()*360);
  wheel.dataset.turn=String(current);wheel.style.transform="rotate("+current+"deg)";
  await new Promise(resolve=>setTimeout(resolve,3250));
  resultBox.hidden=false;
  resultBox.innerHTML='<small>HASIL SPIN KAMU</small><strong>'+escapeHtml(result.prize)+'</strong><span>'+(Number(result.amount)>0?"Saldo bertambah "+money(result.amount):"Belum beruntung. Coba putar lagi!")+'</span>';
  if(Number(result.amount)>0&&window.lexiaaNgWalletBridge.state.account){window.lexiaaNgWalletBridge.state.account.balance=result.balance;}
  await refreshSpinStats();
 }catch(e){
  resultBox.hidden=false;resultBox.innerHTML='<strong>Spin belum berhasil</strong><span>'+escapeHtml(e.message)+'</span>';
 }finally{
  spinBusy=false;if(byId("ngSpinNow")){byId("ngSpinNow").disabled=false;byId("ngSpinNow").textContent="PUTAR RODA HADIAH";}
 }
}
function escapeHtml(value){return String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function questMarkup(s){
 return '<div class="ng-spin-page"><button class="ng-spin-back" id="ngQuestBack" type="button">← Kembali ke Spin</button><div class="ng-spin-stats"><div class="ng-spin-stat"><b id="ngQuestAvailable">'+s.quest_spins+'</b><small>Spin dari Quest</small></div><div class="ng-spin-stat"><b>100</b><small>Skor = 1 Spin</small></div></div><div class="ng-quest-game"><canvas id="ngQuestCanvas" width="640" height="360"></canvas><div class="ng-quest-score"><span>SKOR: <b id="ngQuestScore">0</b></span><span>HINDARI RINTANGAN</span></div></div><button class="ng-spin-action" id="ngQuestStart" type="button">MULAI PERMAINAN</button><p class="ng-quest-help">Ketuk layar untuk melompat dan hindari rintangan. Setiap 100 skor menghasilkan 1 putaran tambahan. Maksimal 10 putaran Quest per hari. Permainan ringan tanpa gambar berat.</p><div class="ng-spin-result" id="ngQuestResult" hidden></div></div>';
}
async function openQuest(){
 if(questGameCleanup){questGameCleanup();questGameCleanup=null;}
 const s=await refreshSpinStats();
 window.lexiaaNgWalletBridge.shell("QUEST · HINDARI RINTANGAN",questMarkup(s));
 byId("ngQuestBack").onclick=openSpin;
 byId("ngQuestStart").onclick=startQuest;
}
async function startQuest(){
 if(questRunning)return;
 const button=byId("ngQuestStart"),canvas=byId("ngQuestCanvas"),scoreNode=byId("ngQuestScore"),resultNode=byId("ngQuestResult");
 if(!canvas)return;
 button.disabled=true;button.textContent="MENYIAPKAN PERMAINAN...";
 try{
  const started=await rpc("ng_wallet_game_start");
  questSession=started.session_id;questRunning=true;
  button.textContent="KETUK LAYAR UNTUK MELOMPAT";
  const ctx=canvas.getContext("2d"),W=640,H=360,ground=300;
  let player={x:90,y:ground-42,w:34,h:42,vy:0},obstacles=[],last=0,lastSpawn=0,elapsed=0,score=0,dead=false;
  function jump(){if(!dead&&player.y>=ground-player.h-1)player.vy=-520;}
  function draw(){
   ctx.clearRect(0,0,W,H);
   ctx.fillStyle="#122b5a";ctx.fillRect(0,0,W,H);
   ctx.strokeStyle="#4168a2";ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(0,ground);ctx.lineTo(W,ground);ctx.stroke();
   ctx.fillStyle="#7fe8ff";ctx.fillRect(player.x,player.y,player.w,player.h);
   ctx.fillStyle="#c3a2ff";ctx.fillRect(player.x+7,player.y+8,20,7);
   ctx.fillStyle="#ff7898";obstacles.forEach(o=>ctx.fillRect(o.x,o.y,o.w,o.h));
   ctx.fillStyle="#fff";ctx.font="bold 18px Arial";ctx.fillText("SURVIVE!",20,32);
  }
  function finish(){
   if(dead)return;dead=true;questRunning=false;cancelAnimationFrame(questFrame);
   canvas.removeEventListener("pointerdown",jump);
   window.removeEventListener("keydown",keyJump);
   if(questGameCleanup){questGameCleanup();questGameCleanup=null;}
   button.disabled=false;button.textContent="MAIN LAGI";
   if(score<100){resultNode.hidden=false;resultNode.innerHTML="<strong>Skor "+score+"</strong><span>Capai minimal 100 skor untuk mendapat spin.</span>";return;}
   resultNode.hidden=false;resultNode.innerHTML="<strong>Memproses Quest...</strong>";
   rpc("ng_wallet_game_claim",{p_session_id:questSession,p_score:score}).then(async claimed=>{
    resultNode.innerHTML="<strong>+"+claimed.spins_earned+" SPIN</strong><span>Skor "+score+" berhasil ditukar. Putaran Quest tersedia: "+claimed.quest_spins+"</span>";
    await refreshSpinStats();
   }).catch(e=>{resultNode.innerHTML="<strong>Klaim belum berhasil</strong><span>"+escapeHtml(e.message)+"</span>";});
  }
  function keyJump(e){if(e.code==="Space"||e.code==="ArrowUp"){e.preventDefault();jump();}}
  canvas.addEventListener("pointerdown",jump);window.addEventListener("keydown",keyJump);
  questGameCleanup=()=>{cancelAnimationFrame(questFrame);canvas.removeEventListener("pointerdown",jump);window.removeEventListener("keydown",keyJump);};
  function frame(t){
   if(!questRunning||dead)return;
   const dt=Math.min(.04,(t-last)/1000||0);last=t;elapsed+=dt*1000;
   score=Math.min(5000,Math.floor(elapsed/10000)*100);scoreNode.textContent=String(score);
   player.vy+=1450*dt;player.y+=player.vy*dt;if(player.y>ground-player.h){player.y=ground-player.h;player.vy=0;}
   lastSpawn+=dt;if(lastSpawn>1.15){lastSpawn=0;obstacles.push({x:W,y:ground-34,w:22+Math.random()*18,h:34});}
   obstacles.forEach(o=>o.x-=250*dt);obstacles=obstacles.filter(o=>o.x+o.w>0);
   for(const o of obstacles){if(player.x<o.x+o.w&&player.x+player.w>o.x&&player.y<o.y+o.h&&player.y+player.h>o.y){draw();finish();return;}}
   draw();
   if(score>=5000){finish();return;}
   questFrame=requestAnimationFrame(frame);
  }
  draw();last=performance.now();questFrame=requestAnimationFrame(frame);
 }catch(e){questRunning=false;button.disabled=false;button.textContent="COBA LAGI";resultNode.hidden=false;resultNode.innerHTML="<strong>Permainan gagal dimulai</strong><span>"+escapeHtml(e.message)+"</span>";}
}
window.ngWalletSpinOpen=openSpin;
document.addEventListener("click",function(e){
 const target=e.target.closest("#ngWalletGetBalance");
 if(target){e.preventDefault();openSpin();}
});
})();
