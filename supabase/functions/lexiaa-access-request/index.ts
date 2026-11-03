import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const respond = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const unlockCode = Deno.env.get("LEXIAA_UNLOCK_CODE");
    if (!supabaseUrl || !anonKey || !serviceKey || !unlockCode) {
      throw new Error("Konfigurasi server belum lengkap.");
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return respond({ error: "Silakan login terlebih dahulu." }, 401);

    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await authClient.auth.getUser(token);
    if (userError || !userData.user) {
      return respond({ error: "Sesi login tidak valid. Silakan login kembali." }, 401);
    }

    const payload = await req.json();
    const message = typeof payload?.message === "string" ? payload.message.trim() : "";
    if (!message || message.length > 2000) {
      return respond({ error: "Pesan wajib diisi (maksimal 2000 karakter)." }, 400);
    }

    const accessGranted = message === unlockCode;
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: insertError } = await adminClient
      .from("lexiaa_access_messages")
      .insert({
        user_id: userData.user.id,
        sender_email: userData.user.email ?? null,
        message,
        access_granted: accessGranted,
      });
    if (insertError) throw insertError;

    return respond({ success: true, access_granted: accessGranted });
  } catch (error) {
    console.error("lexiaa-access-request:", error);
    return respond({ error: error instanceof Error ? error.message : "Terjadi kesalahan server." }, 500);
  }
});
