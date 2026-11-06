// Lexiaa New admin API. Deploy as: supabase/functions/lexiaa-admin/index.ts
import { createClient } from "npm:@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS", "Content-Type": "application/json" };
const json = (data: unknown, status=200) => new Response(JSON.stringify(data), { status, headers: cors });
const enc = new TextEncoder();
function b64url(bytes: Uint8Array) { let s=""; for (const b of bytes) s+=String.fromCharCode(b); return btoa(s).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_"); }
function fromB64url(s:string) { return Uint8Array.from(atob(s.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-s.length%4)%4)),c=>c.charCodeAt(0)); }
async function sign(payload:string, secret:string) {
 const key=await crypto.subtle.importKey("raw",enc.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 return b64url(new Uint8Array(await crypto.subtle.sign("HMAC",key,enc.encode(payload))));
}
async function validToken(token:string, secret:string) {
 const [p,s]=token.split("."); if(!p||!s) return false;
 const expected=await sign(p,secret);
 if(expected!==s) return false;
 try { const data=JSON.parse(new TextDecoder().decode(fromB64url(p))); return data.exp>Date.now() && data.scope==="lexiaa-admin"; } catch { return false; }
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
 if(req.method!=="POST") return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const adminKey=Deno.env.get("LEXIAA_ADMIN_KEY")!, adminPassword=Deno.env.get("LEXIAA_ADMIN_PASSWORD")!, tokenSecret=Deno.env.get("ADMIN_TOKEN_SECRET")!;
 if(!adminKey||!adminPassword||!tokenSecret||!service) return json({error:"Konfigurasi server admin belum lengkap."},500);
 let input:any; try { input=await req.json(); } catch { return json({error:"Permintaan tidak valid."},400); }
 if(input.action==="login") {
   if(input.key!==adminKey||input.password!==adminPassword) return json({error:"Kata kunci atau password salah."},401);
   const payload=b64url(enc.encode(JSON.stringify({exp:Date.now()+8*60*60*1000,scope:"lexiaa-admin"})));
   return json({token:payload+"."+await sign(payload,tokenSecret)});
 }
 const auth=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
 if(!await validToken(auth,tokenSecret)) return json({error:"Sesi admin tidak valid atau kedaluwarsa. Silakan masuk kembali."},401);
 const db=createClient(url,service,{auth:{persistSession:false}});
 if(input.action==="users") {
   const all:any[]=[]; let page=1;
   while(page<=5) {
     const {data,error}=await db.auth.admin.listUsers({page,perPage:1000});
     if(error) return json({error:"Gagal memuat akun Auth: "+error.message},400);
     const batch=data.users||[]; all.push(...batch);
     if(batch.length<1000) break;
     page++;
   }
   const ids=all.map(u=>u.id);
   if(!ids.length) return json({users:[]});
   const [walletResult,profileResult]=await Promise.all([
     db.from("ng_wallet_accounts").select("auth_user_id,phone,display_name,balance,created_at,updated_at").in("auth_user_id",ids),
     db.from("lexiaa_profiles").select("id,username,display_name,email_hint,old_registered,nextgen_joined_at,avatar_url,created_at").in("id",ids)
   ]);
   if(walletResult.error) return json({error:"Gagal membaca akun Saldo LEXIAA N.G. Pastikan migrasi ng_wallet sudah dijalankan: "+walletResult.error.message},400);
   const wallets=new Map((walletResult.data||[]).map((w:any)=>[w.auth_user_id,w]));
   const profiles=new Map((profileResult.error?[]:profileResult.data||[]).map((p:any)=>[p.id,p]));
   const users=all.map(u=>{
     const p:any=profiles.get(u.id)||{}, w:any=wallets.get(u.id)||null, meta=u.user_metadata||{};
     return {id:u.id,username:p.username||meta.username||null,display_name:w?.display_name||p.display_name||meta.display_name||null,email_hint:p.email_hint||null,email:u.email||null,created_at:u.created_at,nextgen_joined_at:p.nextgen_joined_at||null,phone:w?.phone||null,wallet_name:w?.display_name||null,balance:w?Number(w.balance):null,wallet_created_at:w?.created_at||null,has_wallet:Boolean(w)};
   }).sort((a,b)=>new Date(b.created_at||0).getTime()-new Date(a.created_at||0).getTime());
   return json({users,total:users.length,profile_directory_available:!profileResult.error});
 }
 if(input.action==="send") {
   const recipient=String(input.recipient_id||""), title=String(input.title||"").trim(), body=String(input.body||"").trim();
   if(!recipient||!title||title.length>140||!body||body.length>5000) return json({error:"Penerima, judul (maks. 140), dan isi pesan (maks. 5000) wajib diisi."},400);
   const {data:profile,error:profileError}=await db.auth.admin.getUserById(recipient);
   if(profileError||!profile?.user) return json({error:"Akun penerima tidak ditemukan."},404);
   const {data,error}=await db.from("lexiaa_messages").insert({recipient_id:recipient,title,body}).select("id,created_at").single();
   if(error) return json({error:error.message},400);
   return json({message:data});
 }
 if(input.action==="wallet_credit") {
   const recipient=String(input.recipient_id||"");
   const amount=Number(input.amount);
   const description=String(input.description||"Top Up oleh Admin").trim().slice(0,120)||"Top Up oleh Admin";
   if(!recipient||!Number.isSafeInteger(amount)||amount<1||amount>1000000000) return json({error:"Pilih akun Saldo N.G dan masukkan nominal Rp1 sampai Rp1.000.000.000."},400);
   const {data:account,error:accountError}=await db.from("ng_wallet_accounts").select("auth_user_id").eq("auth_user_id",recipient).maybeSingle();
   if(accountError) return json({error:"Gagal memeriksa akun dompet: "+accountError.message},400);
   if(!account) return json({error:"Pengguna ini belum mendaftarkan nomor di Saldo LEXIAA N.G."},404);
   const {data,error}=await db.rpc("ng_wallet_admin_credit",{p_auth_user_id:recipient,p_amount:amount,p_description:description});
   if(error) return json({error:"Gagal menambahkan saldo. Pastikan migrasi admin wallet sudah dijalankan: "+error.message},400);
   if(!data?.success) return json({error:data?.message||"Saldo tidak berhasil ditambahkan."},400);
   return json({success:true,balance:Number(data.balance),transaction_id:data.transaction_id});
 }
 return json({error:"Aksi tidak dikenal."},400);
});
