// supabase/functions/lexiaa-admin/index.ts
// Admin API. Keep verify_jwt=false because the browser sends a custom HMAC admin token.
// This function verifies that custom token itself before every privileged action.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@^9";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: cors });
const enc = new TextEncoder();

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch] || ch));
}
async function sendProEmail(to: string, subject: string, body: string) {
  const host = Deno.env.get("SMTP_HOST") || "";
  const port = Number(Deno.env.get("SMTP_PORT") || "465");
  const user = Deno.env.get("SMTP_USER") || "";
  const pass = Deno.env.get("SMTP_PASS") || "";
  const from = Deno.env.get("LEXIAA_PRO_FROM_EMAIL") || user;
  if (!host || !user || !pass || !from || !to || !/^\S+@\S+\.\S+$/.test(to)) {
    return { sent: false, error: "Konfigurasi SMTP atau email penerima belum lengkap." };
  }
  try {
    const transport = nodemailer.createTransport({
      host, port, secure: port === 465,
      auth: { user, pass },
    });
    const safeSubject = escapeHtml(subject);
    const safeBody = escapeHtml(body).replace(/\n/g, "<br>");
    await transport.sendMail({
      from: { name: "LEXIAA N.G", address: from },
      to, subject,
      html: `<!doctype html><html><body style="margin:0;background:#080d1d;padding:32px 12px;font-family:Arial,sans-serif;color:#eef5ff"><div style="max-width:580px;margin:auto;border:1px solid #26365d;border-radius:22px;overflow:hidden;background:#101a34"><div style="padding:28px 30px;background:linear-gradient(120deg,#101a34,#19234a);border-bottom:1px solid #2b3d68"><div style="font-size:12px;letter-spacing:4px;color:#52e5ff;font-weight:bold">LEXIAA</div><div style="font-size:22px;font-weight:bold;margin-top:8px;color:#fff">THE NEXT GENERATION</div></div><div style="padding:30px"><div style="font-size:20px;font-weight:bold;color:#72eaff;margin-bottom:18px">${safeSubject}</div><div style="font-size:14px;line-height:1.8;color:#dce7ff">${safeBody}</div><div style="height:1px;background:#2a3a61;margin:26px 0 18px"></div><div style="font-size:11px;letter-spacing:2px;color:#8295bd">LEXIAA N.G · NOTIFIKASI RESMI</div></div></div></body></html>`,
      text: body,
    });
    await transport.close();
    return { sent: true, error: "" };
  } catch (e) {
    return { sent: false, error: String(e).slice(0, 300) };
  }
}


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


  // Public catalog and customer actions use the signed-in LEXIAA user's JWT.
  // The service key is used only server-side; user identity is verified before every action.
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  const customerAction = ["novel_catalog", "novel_buy", "novel_download", "video_catalog", "video_status", "video_stream", "video_vip_purchase", "video_buy"].includes(String(input.action || ""));
  if (customerAction) {
    if (!bearer) return json({ error: "Silakan masuk ke akun LEXIAA terlebih dahulu." }, 401);
    const { data: authData, error: authError } = await db.auth.getUser(bearer);
    const customer = authData?.user;
    if (authError || !customer) return json({ error: "Sesi akun tidak valid. Silakan masuk kembali." }, 401);
    const userDb = createClient(url, service, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: "Bearer " + bearer } },
    });

    if (input.action === "video_status") {
      const { data, error } = await db.from("ng_video_vip_subscriptions").select("package_code,starts_at,ends_at").eq("user_id", customer.id).maybeSingle();
      if (error) return json({ error: "Gagal memeriksa VIP: " + error.message }, 400);
      const active = Boolean(data && new Date(data.ends_at).getTime() > Date.now());
      return json({ vip_active: active, subscription: data || null, server_time: new Date().toISOString() });
    }

    if (input.action === "video_catalog") {
      const [{ data: videos, error: videoError }, { data: purchases, error: purchaseError }, { data: subscription, error: subError }, { data: membership, error: proError }, { data: proSettings, error: settingsError }] = await Promise.all([
        db.from("ng_videos").select("id,title,price,mime_type,file_size,created_at,thumbnail_path,is_pro_only").eq("is_published", true).order("created_at", { ascending: false }),
        db.from("ng_video_purchases").select("video_id").eq("user_id", customer.id),
        db.from("ng_video_vip_subscriptions").select("ends_at,package_code").eq("user_id", customer.id).maybeSingle(),
        db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle(),
        db.from("ng_pro_settings").select("discount_percent").eq("id", true).maybeSingle()
      ]);
      if (videoError || purchaseError || subError || proError || settingsError) return json({ error: "Gagal memuat katalog video." }, 400);
      const owned = new Set((purchases || []).map((p: any) => p.video_id));
      const active = Boolean(subscription && new Date(subscription.ends_at).getTime() > Date.now());
      const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
      const discountPercent = proActive ? Math.max(0, Math.min(100, Number(proSettings?.discount_percent ?? 50))) : 0;
      const catalog = await Promise.all((videos || []).map(async (v: any) => {
        let thumbnail_url: string | null = null;
        if (v.thumbnail_path) {
          const { data: thumb } = await db.storage.from("lexiaa-ng-videos").createSignedUrl(v.thumbnail_path, 3600);
          thumbnail_url = thumb?.signedUrl || null;
        }
        const listPrice = Number(v.price);
        const price = Math.floor(listPrice * (100 - discountPercent) / 100);
        return {
          id: v.id, title: v.title, price, list_price: listPrice, discount_percent: discountPercent,
          mime_type: v.mime_type, file_size: Number(v.file_size), thumbnail_url, owned: owned.has(v.id),
          playable: active && (listPrice === 0 || owned.has(v.id)), is_pro_only: v.is_pro_only === true
        };
      }));
      return json({ vip_active: active, subscription: subscription || null, is_pro: proActive, discount_percent: discountPercent, videos: catalog });
    }

    if (input.action === "video_stream") {
      const videoId = String(input.video_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(videoId)) return json({ error: "Video tidak valid." }, 400);
      const [{ data: sub }, { data: video }, { data: purchase }] = await Promise.all([
        db.from("ng_video_vip_subscriptions").select("ends_at").eq("user_id", customer.id).maybeSingle(),
        db.from("ng_videos").select("id,title,price,video_path,mime_type,thumbnail_path,is_pro_only").eq("id", videoId).eq("is_published", true).maybeSingle(),
        db.from("ng_video_purchases").select("id").eq("user_id", customer.id).eq("video_id", videoId).maybeSingle()
      ]);
      if (!sub || new Date(sub.ends_at).getTime() <= Date.now()) return json({ error: "Langganan VIP kamu sudah berakhir. Aktifkan VIP kembali untuk menonton." }, 403);
      if (!video) return json({ error: "Video tidak ditemukan." }, 404);
      if (video.is_pro_only === true) {
        const { data: membership, error: proError } = await db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle();
        if (proError) return json({ error: "Gagal memeriksa status Pro." }, 400);
        const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
        if (!proActive) return json({ error: "Video ini khusus anggota LEXIAA N.G Pro aktif." }, 403);
      }
      if (Number(video.price) > 0 && !purchase) return json({ error: "Video ini harus dibeli terlebih dahulu." }, 403);
      const { data: signed, error: signError } = await db.storage.from("lexiaa-ng-videos").createSignedUrl(video.video_path, 90);
      if (signError || !signed?.signedUrl) return json({ error: "Gagal menyiapkan pemutaran video." }, 400);
      let thumbnail_url: string | null = null;
      if (video.thumbnail_path) {
        const { data: thumb } = await db.storage.from("lexiaa-ng-videos").createSignedUrl(video.thumbnail_path, 3600);
        thumbnail_url = thumb?.signedUrl || null;
      }
      return json({ url: signed.signedUrl, mime_type: video.mime_type, title: video.title, thumbnail_url, vip_ends_at: sub.ends_at });
    }

    if (input.action === "video_vip_purchase") {
      const packageCode = String(input.package_code || "");
      const phone = String(input.phone || "");
      const pin = String(input.pin || "");
      const { data, error } = await userDb.rpc("ng_video_vip_purchase_linked", { p_pin: pin, p_package: packageCode });
      if (error) return json({ error: "Pembayaran VIP gagal diproses: " + error.message }, 400);
      if (!data?.success) return json({ error: data?.message || "Pembayaran VIP tidak berhasil.", ...data }, 400);
      return json(data);
    }

    if (input.action === "video_buy") {
      const videoId = String(input.video_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(videoId)) return json({ error: "Video tidak valid." }, 400);
      const { data: targetVideo, error: targetVideoError } = await db.from("ng_videos").select("is_pro_only").eq("id", videoId).maybeSingle();
      if (targetVideoError || !targetVideo) return json({ error: "Video tidak ditemukan." }, 404);
      if (targetVideo.is_pro_only === true) {
        const { data: membership, error: proError } = await db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle();
        if (proError) return json({ error: "Gagal memeriksa status Pro." }, 400);
        const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
        if (!proActive) return json({ error: "Video ini hanya dapat dibeli anggota LEXIAA N.G Pro aktif." }, 403);
      }
      const { data, error } = await userDb.rpc("ng_video_purchase_linked", { p_pin: String(input.pin || ""), p_video_id: videoId });
      if (error) return json({ error: "Pembelian video gagal diproses: " + error.message }, 400);
      if (!data?.success) return json({ error: data?.message || "Pembelian tidak berhasil.", ...data }, 400);
      return json(data);
    }

    if (input.action === "novel_catalog") {
      const [{ data: novels, error: novelError }, { data: purchases, error: purchaseError }, { data: membership, error: proError }, { data: proSettings, error: settingsError }] = await Promise.all([
        db.from("lexiaa_novels").select("id,title,price,cover_path,cover_mode,created_at,is_pro_only").eq("is_published", true).order("created_at", { ascending: false }),
        db.from("lexiaa_novel_purchases").select("novel_id").eq("user_id", customer.id),
        db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle(),
        db.from("ng_pro_settings").select("discount_percent").eq("id", true).maybeSingle()
      ]);
      if (novelError) return json({ error: "Gagal memuat katalog novel: " + novelError.message }, 400);
      if (purchaseError || proError || settingsError) return json({ error: "Gagal memuat status pembelian atau keanggotaan Pro." }, 400);
      const owned = new Set((purchases || []).map((p: any) => p.novel_id));
      const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
      const discountPercent = proActive ? Math.max(0, Math.min(100, Number(proSettings?.discount_percent ?? 50))) : 0;
      const result = await Promise.all((novels || []).map(async (n: any) => {
        let cover_url: string | null = null;
        if (n.cover_path) {
          const { data } = await db.storage.from("lexiaa-novels").createSignedUrl(n.cover_path, 900);
          cover_url = data?.signedUrl || null;
        }
        const listPrice = Number(n.price);
        const price = Math.floor(listPrice * (100 - discountPercent) / 100);
        return { id: n.id, title: n.title, price, list_price: listPrice, discount_percent: discountPercent, cover_url, owned: owned.has(n.id), is_pro_only: n.is_pro_only === true };
      }));
      return json({ is_pro: proActive, discount_percent: discountPercent, novels: result });
    }

    if (input.action === "novel_buy") {
      const novelId = String(input.novel_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(novelId)) {
        return json({ error: "Novel tidak valid." }, 400);
      }
      const { data: targetNovel, error: targetNovelError } = await db.from("lexiaa_novels").select("is_pro_only").eq("id", novelId).maybeSingle();
      if (targetNovelError || !targetNovel) return json({ error: "Novel tidak ditemukan." }, 404);
      if (targetNovel.is_pro_only === true) {
        const { data: membership, error: proError } = await db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle();
        if (proError) return json({ error: "Gagal memeriksa status Pro." }, 400);
        const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
        if (!proActive) return json({ error: "Novel ini hanya dapat dibeli anggota LEXIAA N.G Pro aktif." }, 403);
      }
      const { data, error } = await userDb.rpc("lexiaa_novel_buy_with_pin", { p_novel_id: novelId, p_pin: String(input.pin || "") });
      if (error) return json({ error: "Pembelian gagal diproses: " + error.message }, 400);
      if (!data?.success) return json({ error: data?.message || "Pembelian tidak berhasil." }, 400);
      return json(data);
    }

    if (input.action === "novel_download") {
      const novelId = String(input.novel_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(novelId)) {
        return json({ error: "Novel tidak valid." }, 400);
      }
      const { data: purchase, error: purchaseError } = await db.from("lexiaa_novel_purchases")
        .select("novel_id").eq("user_id", customer.id).eq("novel_id", novelId).maybeSingle();
      if (purchaseError) return json({ error: "Gagal memeriksa kepemilikan novel: " + purchaseError.message }, 400);
      if (!purchase) return json({ error: "Novel ini belum dibeli oleh akunmu." }, 403);
      const { data: novel, error: novelError } = await db.from("lexiaa_novels")
        .select("title,pdf_path,is_pro_only").eq("id", novelId).maybeSingle();
      if (novelError || !novel) return json({ error: "File novel tidak ditemukan." }, 404);
      if (novel.is_pro_only === true) {
        const { data: membership, error: proError } = await db.from("ng_pro_memberships").select("status,starts_at,ends_at").eq("user_id", customer.id).maybeSingle();
        if (proError) return json({ error: "Gagal memeriksa status Pro." }, 400);
        const proActive = Boolean(membership && membership.status === "active" && new Date(membership.starts_at).getTime() <= Date.now() && new Date(membership.ends_at).getTime() > Date.now());
        if (!proActive) return json({ error: "Novel ini khusus anggota LEXIAA N.G Pro aktif." }, 403);
      }
      const { data: signed, error: signError } = await db.storage.from("lexiaa-novels")
        .createSignedUrl(novel.pdf_path, 90, { download: String(novel.title || "lexiaa-novel").replace(/[\\/\\:*?"<>|]/g, "_") + ".pdf" });
      if (signError || !signed?.signedUrl) return json({ error: "Gagal menyiapkan unduhan novel." }, 400);
      return json({ url: signed.signedUrl });
    }
  }

  const auth = bearer;
  if (!await validToken(auth, tokenSecret)) {
    return json({ error: "Sesi admin tidak valid atau kedaluwarsa. Silakan masuk kembali." }, 401);
  }



  if (input.action === "pro_memberships") {
    const { data, error } = await db.from("ng_pro_memberships")
      .select("user_id,application_id,status,starts_at,ends_at,admin_note,updated_at")
      .order("updated_at", { ascending: false });
    if (error) return json({ error: "Gagal memuat anggota Pro: " + error.message }, 400);
    const appIds = [...new Set((data || []).map((m: any) => m.application_id).filter(Boolean))];
    let apps: any[] = [];
    if (appIds.length) {
      const { data: rows, error: appError } = await db.from("ng_pro_applications")
        .select("id,full_name,email,wallet_phone").in("id", appIds);
      if (appError) return json({ error: "Gagal memuat identitas anggota Pro: " + appError.message }, 400);
      apps = rows || [];
    }
    const appMap = new Map(apps.map((a: any) => [a.id, a]));
    return json({ memberships: (data || []).map((m: any) => ({ ...m, application: appMap.get(m.application_id) || null })) });
  }

  if (input.action === "pro_membership_update") {
    const userId = String(input.user_id || "");
    const status = input.status === "active" ? "active" : input.status === "inactive" ? "inactive" : "";
    const startsMs = Date.parse(String(input.starts_at || ""));
    const endsMs = Date.parse(String(input.ends_at || ""));
    const note = String(input.admin_note || "").trim().slice(0, 500);
    if (!userId || !status || !Number.isFinite(startsMs) || !Number.isFinite(endsMs) || endsMs <= startsMs) {
      return json({ error: "Status atau rentang masa aktif tidak valid." }, 400);
    }
    const startsAt = new Date(startsMs).toISOString();
    const endsAt = new Date(endsMs).toISOString();
    if (status === "inactive" && !note) return json({ error: "Catatan admin wajib diisi saat menonaktifkan Pro." }, 400);
    const { error } = await db.from("ng_pro_memberships").update({
      status, starts_at: startsAt, ends_at: endsAt, admin_note: note || null, updated_at: new Date().toISOString()
    }).eq("user_id", userId);
    if (error) return json({ error: "Gagal memperbarui keanggotaan Pro: " + error.message }, 400);
    const title = status === "active" ? "Status LEXIAA N.G Pro Diperbarui" : "LEXIAA N.G Pro Dinonaktifkan";
    const body = status === "active"
      ? "Masa aktif LEXIAA N.G Pro kamu telah diperbarui hingga " + new Date(endsAt).toLocaleString("id-ID", { timeZone: "Asia/Jakarta" }) + "." + (note ? "\\nCatatan admin: " + note : "")
      : "Keanggotaan LEXIAA N.G Pro kamu telah dinonaktifkan." + "\\nCatatan admin: " + note;
    await db.from("lexiaa_messages").insert({ recipient_id: userId, title, body });
    const { data: target } = await db.auth.admin.getUserById(userId);
    const emailResult = target?.user?.email ? await sendProEmail(target.user.email, title, body) : { sent: false, error: "Email akun tidak ditemukan." };
    return json({ success: true, status, starts_at: startsAt, ends_at: endsAt, email_sent: emailResult.sent, email_error: emailResult.error });
  }

  if (input.action === "pro_applications") {
    const { data, error } = await db.from("ng_pro_applications")
      .select("id,user_id,full_name,birth_date,email,whatsapp,wallet_phone,status,created_at")
      .order("created_at", { ascending: false });
    if (error) return json({ error: "Gagal memuat pengajuan Pro: " + error.message }, 400);
    return json({ applications: data || [] });
  }

  if (input.action === "pro_settings_get") {
    const { data, error } = await db.from("ng_pro_settings").select("*").eq("id", true).single();
    if (error) return json({ error: "Gagal memuat pengaturan Pro: " + error.message }, 400);
    return json({ settings: data });
  }

  if (input.action === "pro_settings_save") {
    const renewal_price = Number(input.renewal_price);
    const duration_days = Number(input.duration_days);
    const daily_bonus = Number(input.daily_bonus);
    if (!Number.isSafeInteger(renewal_price) || renewal_price < 0 || renewal_price > 1000000000 ||
        !Number.isInteger(duration_days) || duration_days < 1 || duration_days > 3650 ||
        !Number.isSafeInteger(daily_bonus) || daily_bonus < 0 || daily_bonus > 1000000000) {
      return json({ error: "Harga, durasi, atau bonus harian tidak valid." }, 400);
    }
    const { data, error } = await db.from("ng_pro_settings")
      .upsert({ id: true, renewal_price, duration_days, daily_bonus, discount_percent: 50, cashback_percent: 20, updated_at: new Date().toISOString() })
      .select("*").single();
    if (error) return json({ error: "Gagal menyimpan pengaturan Pro: " + error.message }, 400);
    return json({ success: true, settings: data });
  }

  if (input.action === "pro_decide") {
    const applicationId = String(input.application_id || "");
    const decision = input.decision === "approved" ? "approved" : input.decision === "rejected" ? "rejected" : "";
    const durationDays = Number(input.duration_days || 30);
    const note = String(input.admin_note || "").trim().slice(0, 500);
    if (!applicationId || !decision || !Number.isInteger(durationDays) || durationDays < 1 || durationDays > 3650) {
      return json({ error: "Keputusan atau masa aktif Pro tidak valid." }, 400);
    }
    const { data: app, error: appError } = await db.from("ng_pro_applications")
      .select("id,user_id,full_name,email,wallet_phone,status").eq("id", applicationId).maybeSingle();
    if (appError || !app) return json({ error: "Pengajuan tidak ditemukan." }, 404);
    if (app.status !== "pending") return json({ error: "Pengajuan ini sudah diproses." }, 409);

    const now = new Date();
    const endsAt = new Date(now.getTime() + durationDays * 86400000).toISOString();
    const { error: updateError } = await db.from("ng_pro_applications").update({
      status: decision, admin_note: note || null, reviewed_at: now.toISOString(), reviewed_by: "LEXIAA ADMIN"
    }).eq("id", applicationId).eq("status", "pending");
    if (updateError) return json({ error: "Gagal menyimpan keputusan: " + updateError.message }, 400);

    if (decision === "approved") {
      const { error: memberError } = await db.from("ng_pro_memberships").upsert({
        user_id: app.user_id, application_id: app.id, status: "active",
        starts_at: now.toISOString(), ends_at: endsAt, updated_at: now.toISOString()
      });
      if (memberError) return json({ error: "Keputusan tersimpan, tetapi aktivasi Pro gagal: " + memberError.message }, 400);
    }
    const title = decision === "approved" ? "LEXIAA N.G Pro Disetujui!" : "Pengajuan LEXIAA N.G Pro";
    const body = decision === "approved"
      ? "Selamat, pengajuan LEXIAA N.G Pro kamu telah disetujui. Keanggotaan aktif sampai " + new Date(endsAt).toLocaleString("id-ID", { timeZone: "Asia/Jakarta" }) + ". Semua benefit Pro sudah dapat digunakan."
      : "Maaf, pengajuan LEXIAA N.G Pro kamu belum disetujui." + (note ? "\\nCatatan admin: " + note : "");
    const { error: messageError } = await db.from("lexiaa_messages").insert({ recipient_id: app.user_id, title, body });

    const emailResult = app.email ? await sendProEmail(app.email, title, body) : { sent: false, error: "Email pengajuan tidak ditemukan." };
    return json({ success: true, decision, email_sent: emailResult.sent, email_error: emailResult.error,
      message_saved: !messageError, ends_at: decision === "approved" ? endsAt : null });
  }

  if (input.action === "video_list") {
    const { data, error } = await db.from("ng_videos").select("id,title,price,video_path,mime_type,file_size,is_published,is_pro_only,created_at").order("created_at", { ascending: false });
    if (error) return json({ error: "Gagal memuat daftar video: " + error.message }, 400);
    return json({ videos: data || [] });
  }

  if (input.action === "video_upload_sign") {
    const ext = String(input.extension || "").toLowerCase();
    const mime = ext === "mp4" ? "video/mp4" : ext === "webm" ? "video/webm" : ext === "jpg" ? "image/jpeg" : "";
    const size = Number(input.file_size);
    const maxSize = ext === "jpg" ? 200000 : 52428800;
    if (!mime || !Number.isSafeInteger(size) || size < 1 || size > maxSize) return json({ error: "File video atau thumbnail tidak valid." }, 400);
    const requestedVideoPath = String(input.video_path || "");
    const path = ext === "jpg"
      ? (/^admin\/[a-f0-9-]+\/video\.(?:mp4|webm)$/i.test(requestedVideoPath) ? requestedVideoPath.replace(/\/video\.(?:mp4|webm)$/i, "/thumbnail.jpg") : "")
      : "admin/" + crypto.randomUUID() + "/video." + ext;
    if (!path) return json({ error: "Lokasi video untuk thumbnail tidak valid." }, 400);
    const { data, error } = await db.storage.from("lexiaa-ng-videos").createSignedUploadUrl(path);
    if (error || !data?.token) return json({ error: "Gagal menyiapkan unggahan video: " + (error?.message || "Token upload tidak tersedia.") }, 400);
    return json({ path, token: data.token, mime_type: mime });
  }

  if (input.action === "video_save") {
    const title = String(input.title || "").trim(), price = Number(input.price);
    const path = String(input.video_path || ""), mime = String(input.mime_type || ""), thumbnailPath = String(input.thumbnail_path || "");
    const size = Number(input.file_size);
    const expectedThumbnail = path.replace(/\/video\.(?:mp4|webm)$/i, "/thumbnail.jpg");
    if (!title || title.length > 160 || !Number.isSafeInteger(price) || price < 0 || price > 1000000000 ||
        !/^admin\/[a-f0-9-]+\/video\.(?:mp4|webm)$/i.test(path) || !["video/mp4","video/webm"].includes(mime) ||
        !Number.isSafeInteger(size) || size < 1 || size > 52428800 ||
        (thumbnailPath && thumbnailPath !== expectedThumbnail)) return json({ error: "Judul, harga, atau file video tidak valid." }, 400);
    const { data, error } = await db.from("ng_videos").insert({ title, price, video_path: path, thumbnail_path: thumbnailPath || null, mime_type: mime, file_size: size, is_published: true, is_pro_only: input.is_pro_only === true })
      .select("id,title,price,video_path,mime_type,file_size,is_published,is_pro_only,created_at").single();
    if (error) return json({ error: "Gagal menyimpan video: " + error.message }, 400);
    return json({ success: true, video: data });
  }

  if (input.action === "video_pro_only") {
    const id = String(input.id || "");
    if (!id) return json({ error: "ID video tidak valid." }, 400);
    const { error } = await db.from("ng_videos").update({ is_pro_only: input.is_pro_only === true, updated_at: new Date().toISOString() }).eq("id", id);
    if (error) return json({ error: "Gagal mengubah akses Pro video: " + error.message }, 400);
    return json({ success: true });
  }

  if (input.action === "video_publish") {
    const id = String(input.id || "");
    if (!id) return json({ error: "ID video tidak valid." }, 400);
    const { error } = await db.from("ng_videos").update({ is_published: input.is_published === true, updated_at: new Date().toISOString() }).eq("id", id);
    if (error) return json({ error: "Gagal mengubah status video: " + error.message }, 400);
    return json({ success: true });
  }

  if (input.action === "video_delete") {
    const id = String(input.id || "");
    const { data: video, error: findError } = await db.from("ng_videos").select("id,video_path").eq("id", id).maybeSingle();
    if (findError || !video) return json({ error: "Video tidak ditemukan." }, 404);
    const { error } = await db.from("ng_videos").delete().eq("id", id);
    if (error) return json({ error: "Video tidak dapat dihapus. Sembunyikan video agar riwayat pembelian tetap aman." }, 400);
    await db.storage.from("lexiaa-ng-videos").remove([video.video_path]);
    return json({ success: true });
  }

  if (input.action === "novel_list") {
    const { data, error } = await db.from("lexiaa_novels")
      .select("id,title,price,pdf_path,cover_path,cover_mode,is_published,is_pro_only,created_at")
      .order("created_at", { ascending: false });
    if (error) return json({ error: "Gagal memuat katalog novel: " + error.message }, 400);
    return json({ novels: data || [] });
  }

  if (input.action === "novel_upload_sign") {
    const kind = input.kind === "cover" ? "cover" : input.kind === "pdf" ? "pdf" : "";
    const ext = kind === "pdf" ? "pdf" : String(input.extension || "jpg").toLowerCase();
    const allowed = kind === "pdf" ? ["pdf"] : ["jpg", "jpeg", "png", "webp"];
    if (!kind || !allowed.includes(ext)) return json({ error: "Jenis file unggahan tidak didukung." }, 400);
    const path = "admin/" + crypto.randomUUID() + "/" + kind + "." + ext;
    const { data, error } = await db.storage.from("lexiaa-novels").createSignedUploadUrl(path);
    if (error || !data?.token) return json({ error: "Gagal menyiapkan unggahan: " + (error?.message || "Token upload tidak tersedia.") }, 400);
    return json({ path, token: data.token });
  }

  if (input.action === "novel_save") {
    const id = String(input.id || "");
    const title = String(input.title || "").trim();
    const price = Number(input.price);
    const pdfPath = String(input.pdf_path || "");
    const coverPath = input.cover_path ? String(input.cover_path) : null;
    const coverMode = input.cover_mode === "custom" ? "custom" : "pdf";
    if (!title || title.length > 160 || !Number.isSafeInteger(price) || price < 0 || price > 1_000_000_000 || !pdfPath.startsWith("admin/") || (coverPath && !coverPath.startsWith("admin/"))) {
      return json({ error: "Judul, harga, atau file novel tidak valid." }, 400);
    }
    const payload = { title, price, pdf_path: pdfPath, cover_path: coverPath, cover_mode: coverMode, is_published: input.is_published !== false, is_pro_only: input.is_pro_only === true, updated_at: new Date().toISOString() };
    const query = id
      ? db.from("lexiaa_novels").update(payload).eq("id", id)
      : db.from("lexiaa_novels").insert(payload);
    const { data, error } = await query.select("id,title,price,pdf_path,cover_path,cover_mode,is_published,is_pro_only,created_at").single();
    if (error) return json({ error: "Gagal menyimpan novel: " + error.message }, 400);
    return json({ success: true, novel: data });
  }

  if (input.action === "novel_delete") {
    const id = String(input.id || "");
    if (!id) return json({ error: "ID novel tidak valid." }, 400);
    const { data: novel, error: findError } = await db.from("lexiaa_novels").select("id,pdf_path,cover_path")
      .eq("id", id).maybeSingle();
    if (findError || !novel) return json({ error: "Novel tidak ditemukan." }, 404);
    const { error } = await db.from("lexiaa_novels").delete().eq("id", id);
    if (error) return json({ error: "Novel tidak dapat dihapus. Jika sudah pernah dibeli, nonaktifkan publikasinya agar riwayat pembeli tetap aman." }, 400);
    const paths = [novel.pdf_path, novel.cover_path].filter(Boolean) as string[];
    if (paths.length) await db.storage.from("lexiaa-novels").remove(paths);
    return json({ success: true });
  }

  if (input.action === "novel_pro_only") {
    const id = String(input.id || "");
    if (!id) return json({ error: "ID novel tidak valid." }, 400);
    const { error } = await db.from("lexiaa_novels").update({ is_pro_only: input.is_pro_only === true, updated_at: new Date().toISOString() }).eq("id", id);
    if (error) return json({ error: "Gagal mengubah akses Pro novel: " + error.message }, 400);
    return json({ success: true });
  }

  if (input.action === "novel_publish") {
    const id = String(input.id || "");
    const published = input.is_published === true;
    const { error } = await db.from("lexiaa_novels").update({ is_published: published, updated_at: new Date().toISOString() }).eq("id", id);
    if (error) return json({ error: "Gagal mengubah status novel: " + error.message }, 400);
    return json({ success: true });
  }

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

  if (input.action === "wallet_accounts") {
    const { data, error } = await db.from("ng_wallet_accounts")
      .select("auth_user_id,phone,display_name,balance,created_at,updated_at")
      .order("created_at", { ascending: false });
    if (error) return json({ error: "Gagal membaca daftar Wallet: " + error.message }, 400);
    return json({ wallets: (data || []).map((w: any) => ({
      recipient_id: w.auth_user_id,
      phone: w.phone,
      display_name: w.display_name,
      balance: Number(w.balance),
      created_at: w.created_at,
    })), total: (data || []).length });
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
      .select("auth_user_id,phone").eq("auth_user_id", recipient).maybeSingle();
    if (accountError) return json({ error: "Gagal memeriksa akun Wallet: " + accountError.message }, 400);
    if (!account) return json({ error: "Nomor Wallet tujuan tidak ditemukan atau sudah tidak terdaftar." }, 404);
    const { data, error } = await db.rpc("ng_wallet_admin_credit", {
      p_auth_user_id: recipient, p_amount: amount, p_description: description,
    });
    if (error) return json({ error: "Gagal menambahkan saldo. Pastikan RPC ng_wallet_admin_credit sudah dibuat: " + error.message }, 400);
    if (!data?.success) return json({ error: data?.message || "Saldo tidak berhasil ditambahkan." }, 400);
    return json({ success: true, balance: Number(data.balance), transaction_id: data.transaction_id });
  }

  return json({ error: "Aksi tidak dikenal." }, 400);
});
