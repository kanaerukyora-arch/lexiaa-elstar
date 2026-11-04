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
 try { const data=JSON.parse(new TextDecoder().decode(fromB64url(p))); return data.exp>Date.now(); } catch { return false; }
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
 if(req.method!=="POST") return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const adminKey=Deno.env.get("LEXIAA_ADMIN_KEY")!, adminPassword=Deno.env.get("LEXIAA_ADMIN_PASSWORD")!, tokenSecret=Deno.env.get("ADMIN_TOKEN_SECRET")!;
 if(!adminKey||!adminPassword||!tokenSecret) return json({error:"Admin secrets belum dikonfigurasi."},500);
 let input:any; try { input=await req.json(); } catch { return json({error:"Permintaan tidak valid."},400); }
 if(input.action==="login") {
   if(input.key!==adminKey||input.password!==adminPassword) return json({error:"Kata kunci atau password salah."},401);
   const payload=b64url(enc.encode(JSON.stringify({exp:Date.now()+8*60*60*1000,scope:"lexiaa-admin"})));
   return json({token:payload+"."+await sign(payload,tokenSecret)});
 }
 const auth=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
 if(!await validToken(auth,tokenSecret)) return json({error:"Sesi admin tidak valid atau kedaluwarsa."},401);
 const db=createClient(url,service,{auth:{persistSession:false}});
 if(input.action==="users") {
   const {data,error}=await db.from("lexiaa_profiles").select("id,username,display_name,email_hint,old_registered,nextgen_joined_at,avatar_url,created_at").order("created_at",{ascending:false}).limit(2000);
   if(error) return json({error:error.message},400);
   return json({users:data||[]});
 }
 if(input.action==="send") {
   const recipient=String(input.recipient_id||""), title=String(input.title||"").trim(), body=String(input.body||"").trim();
   if(!recipient||!title||title.length>140||!body||body.length>5000) return json({error:"Penerima, judul (maks. 140), dan isi pesan (maks. 5000) wajib diisi."},400);
   const {data:profile,error:profileError}=await db.from("lexiaa_profiles").select("id").eq("id",recipient).maybeSingle();
   if(profileError||!profile) return json({error:"Akun penerima tidak ditemukan."},404);
   const {data,error}=await db.from("lexiaa_messages").insert({recipient_id:recipient,title,body}).select("id,created_at").single();
   if(error) return json({error:error.message},400);
   return json({message:data});
 }
 return json({error:"Aksi tidak dikenal."},400);
});
