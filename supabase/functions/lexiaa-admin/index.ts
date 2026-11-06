// supabase/functions/lexiaa-admin/index.ts
// Admin API. Keep verify_jwt=false because the browser sends a custom HMAC admin token.
// This function verifies that custom token itself before every privileged action.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: cors });
const enc = new TextEncoder();

function b64url(bytes: Uint8Array) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function fromB64url(s: string) {
  return Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - s.length % 4) % 4)),
    c => c.charCodeAt(0),
  );
}
async function sign(payload: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(payload))));
}
function constantTimeEqual(a: string, b: string) {
  const aa = enc.encode(a), bb = enc.encode(b);
  if (aa.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
}
async function validToken(token: string, secret: string) {
  const [p, s, extra] = token.split(".");
  if (!p || !s || extra) return false;
  if (!constantTimeEqual(await sign(p, secret), s)) return false;
  try {
    const data = JSON.parse(new TextDecoder().decode(fromB64url(p)));
    return Number.isFinite(data.exp) && data.exp > Date.now() && data.scope === "lexiaa-admin";
  } catch { return false; }
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") || "";
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const adminKey = Deno.env.get("LEXIAA_ADMIN_KEY") || "";
  const adminPassword = Deno.env.get("LEXIAA_ADMIN_PASSWORD") || "";
  const tokenSecret = Deno.env.get("ADMIN_TOKEN_SECRET") || "";
  if (!url || !service || !adminKey || !adminPassword || !tokenSecret) {
    return json({ error: "Konfigurasi server admin belum lengkap." }, 500);
  }

  let input: any;
  try { input = await req.json(); } catch { return json({ error: "Permintaan JSON tidak valid." }, 400); }

  if (input.action === "login") {
    if (input.key !== adminKey || input.password !== adminPassword) {
      return json({ error: "Kata kunci atau password salah." }, 401);
    }
    const payload = b64url(enc.encode(JSON.stringify({
      exp: Date.now() + 8 * 60 * 60 * 1000,
      scope: "lexiaa-admin",
    })));
    return json({ token: payload + "." + await sign(payload, tokenSecret) });
  }

  const auth = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!await validToken(auth, tokenSecret)) {
    return json({ error: "Sesi admin tidak valid atau kedaluwarsa. Silakan masuk kembali." }, 401);
  }

  const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  if (input.action === "users") {
    const all: any[] = [];
    for (let page = 1; page <= 20; page++) {
      const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) return json({ error: "Gagal memuat akun Auth: " + error.message }, 400);
      const batch = data.users || [];
      all.push(...batch);
      if (batch.length < 1000) break;
    }
    const ids = all.map(u => u.id);
    if (!ids.length) return json({ users: [], total: 0, profile_directory_available: true });
    const [walletResult, profileResult] = await Promise.all([
      db.from("ng_wallet_accounts")
        .select("auth_user_id,phone,display_name,balance,created_at,updated_at")
        .in("auth_user_id", ids),
      db.from("lexiaa_profiles")
        .select("id,username,display_name,email_hint,old_registered,nextgen_joined_at,avatar_url,created_at")
        .in("id", ids),
    ]);
    if (walletResult.error) {
      return json({ error: "Gagal membaca ng_wallet_accounts. Periksa migrasi Wallet: " + walletResult.error.message }, 400);
    }
    const wallets = new Map((walletResult.data || []).map((w: any) => [w.auth_user_id, w]));
    const profiles = new Map((profileResult.data || []).map((p: any) => [p.id, p]));
    const users = all.map(u => {
      const p: any = profiles.get(u.id) || {};
      const w: any = wallets.get(u.id) || null;
      const meta = u.user_metadata || {};
      return {
        id: u.id,
        username: p.username || meta.username || null,
        display_name: w?.display_name || p.display_name || meta.display_name || null,
        email_hint: p.email_hint || null,
        email: u.email || null,
        created_at: u.created_at,
        old_registered: p.old_registered === true,
        nextgen_joined_at: p.nextgen_joined_at || null,
        avatar_url: p.avatar_url || null,
        phone: w?.phone || null,
        wallet_name: w?.display_name || null,
        balance: w ? Number(w.balance) : null,
        wallet_created_at: w?.created_at || null,
        has_wallet: Boolean(w),
      };
    }).sort((a, b) => new Date(b.created_at || 0).getTime() - new Date(a.created_at || 0).getTime());
    return json({
      users,
      total: users.length,
      profile_directory_available: !profileResult.error,
      profile_directory_error: profileResult.error?.message || null,
    });
  }

  if (input.action === "send") {
    const recipient = String(input.recipient_id || "");
    const title = String(input.title || "").trim();
    const body = String(input.body || "").trim();
    if (!recipient || !title || title.length > 140 || !body || body.length > 5000) {
      return json({ error: "Penerima, judul (maks. 140), dan isi pesan (maks. 5000) wajib diisi." }, 400);
    }
    const { data: target, error: targetError } = await db.auth.admin.getUserById(recipient);
    if (targetError || !target?.user) return json({ error: "Akun penerima tidak ditemukan." }, 404);
    const { data, error } = await db.from("lexiaa_messages")
      .insert({ recipient_id: recipient, title, body })
      .select("id,created_at").single();
    if (error) return json({ error: "Gagal menyimpan pesan: " + error.message }, 400);
    return json({ success: true, message: data });
  }

  if (input.action === "wallet_credit") {
    const recipient = String(input.recipient_id || "");
    const amount = Number(input.amount);
    const description = String(input.description || "Top Up oleh Admin").trim().slice(0, 120) || "Top Up oleh Admin";
    if (!recipient || !Number.isSafeInteger(amount) || amount < 1 || amount > 1_000_000_000) {
      return json({ error: "Pilih akun Wallet N.G dan masukkan nominal Rp1 sampai Rp1.000.000.000." }, 400);
    }
    const { data: account, error: accountError } = await db.from("ng_wallet_accounts")
      .select("auth_user_id").eq("auth_user_id", recipient).maybeSingle();
    if (accountError) return json({ error: "Gagal memeriksa akun Wallet: " + accountError.message }, 400);
    if (!account) return json({ error: "Pengguna belum mendaftarkan Wallet LEXIAA N.G." }, 404);
    const { data, error } = await db.rpc("ng_wallet_admin_credit", {
      p_auth_user_id: recipient, p_amount: amount, p_description: description,
    });
    if (error) return json({ error: "Gagal menambahkan saldo. Pastikan RPC ng_wallet_admin_credit sudah dibuat: " + error.message }, 400);
    if (!data?.success) return json({ error: data?.message || "Saldo tidak berhasil ditambahkan." }, 400);
    return json({ success: true, balance: Number(data.balance), transaction_id: data.transaction_id });
  }

  return json({ error: "Aksi tidak dikenal." }, 400);
});
