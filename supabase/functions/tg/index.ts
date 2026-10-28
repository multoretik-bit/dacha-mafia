// DACHA MAFIA · Telegram edge function
// POST {action:"auth", initData}   -> verifies Telegram mini app data, returns a Supabase session
// POST {action:"notify", game_id}  -> host only: bot tells every player their card has arrived
// POST ?hook=1 (Telegram webhook)  -> answers /start with an "Играть" button
import { createClient } from "npm:@supabase/supabase-js@2.117.0";

const BOT = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const PEPPER = Deno.env.get("TG_AUTH_PEPPER")!;
const HOOK_SECRET = Deno.env.get("TG_HOOK_SECRET")!;
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APP = "https://dacha-mafia.vercel.app/";
const MAX_AGE = 60 * 60 * 24; // initData older than a day is rejected

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const enc = new TextEncoder();
const hmac = async (key: Uint8Array | string, msg: string) => {
  const k = await crypto.subtle.importKey("raw", typeof key === "string" ? enc.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
};
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

// service-role client for data; never signs in, so it keeps the service role
const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const tgApi = (method: string, body: unknown) =>
  fetch(`https://api.telegram.org/bot${BOT}/${method}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());

type TgUser = { id: number; first_name?: string; last_name?: string; username?: string; photo_url?: string };

async function verifyInitData(initData: string): Promise<TgUser | null> {
  const p = new URLSearchParams(initData);
  const hash = p.get("hash");
  if (!hash) return null;
  p.delete("hash");
  const check = [...p.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => `${k}=${v}`).join("\n");
  const secret = await hmac("WebAppData", BOT);
  if (hex(await hmac(secret, check)) !== hash) return null;
  const age = Date.now() / 1000 - Number(p.get("auth_date") || 0);
  if (!(age < MAX_AGE)) return null;
  try { return JSON.parse(p.get("user") || "null"); } catch { return null; }
}

// copies the Telegram avatar into our public bucket so the app can cache it for a long time;
// the ?v= part changes only when the photo itself changes
async function mirrorPhoto(userId: string, photoUrl: string | undefined, current: string | null) {
  if (!photoUrl) {
    if (current) await admin.from("profiles").update({ tg_photo: null }).eq("id", userId);
    return;
  }
  const res = await fetch(photoUrl);
  if (!res.ok) return;
  const bytes = new Uint8Array(await res.arrayBuffer());
  const v = hex(new Uint8Array(await crypto.subtle.digest("SHA-1", bytes))).slice(0, 12);
  const url = `${SB_URL}/storage/v1/object/public/avatars/${userId}.jpg?v=${v}`;
  if (current === url) return;
  const up = await admin.storage.from("avatars").upload(`${userId}.jpg`, bytes, { contentType: res.headers.get("content-type") || "image/jpeg", cacheControl: "31536000", upsert: true });
  if (!up.error) await admin.from("profiles").update({ tg_photo: url }).eq("id", userId);
}
const later = (p: Promise<unknown>) => {
  const rt = (globalThis as any).EdgeRuntime;
  rt?.waitUntil ? rt.waitUntil(p.catch(() => {})) : p.catch(() => {});
};

async function auth(initData: string) {
  const u = await verifyInitData(initData || "");
  if (!u?.id) return json({ error: "Telegram не подтвердил вход. Открой приложение заново из бота." }, 401);
  const email = `tg${u.id}@tg.dacha-mafia.app`;
  const password = hex(await hmac(PEPPER, String(u.id)));
  const tgName = [u.first_name, u.last_name].filter(Boolean).join(" ");
  const tg = { tg_username: u.username || null, tg_name: tgName || null };
  const signer = createClient(SB_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  let res = await signer.auth.signInWithPassword({ email, password });
  if (res.error) {
    const created = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { nick: (u.first_name || u.username || "Дачник").slice(0, 24), tg_id: String(u.id), tg_username: tg.tg_username || "", tg_name: tg.tg_name || "" },
    });
    if (created.error) return json({ error: created.error.message }, 500);
    res = await signer.auth.signInWithPassword({ email, password });
    if (res.error) return json({ error: res.error.message }, 500);
  } else {
    await admin.from("profiles").update(tg).eq("id", res.data.user.id);
  }
  const userId = res.data.user.id;
  const { data: prof } = await admin.from("profiles").select("tg_photo").eq("id", userId).maybeSingle();
  later(mirrorPhoto(userId, u.photo_url, prof?.tg_photo ?? null));
  const s = res.data.session!;
  return json({ access_token: s.access_token, refresh_token: s.refresh_token });
}

async function notify(req: Request, gameId: string) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const { data: g } = await admin.from("games").select("id,host_id,status,notified_at").eq("id", gameId).maybeSingle();
  if (!g || g.host_id !== user.id || g.status !== "live") return json({ error: "Это не твоя игра" }, 403);
  if (g.notified_at) return json({ sent: 0 });
  await admin.from("games").update({ notified_at: new Date().toISOString() }).eq("id", g.id);
  const [{ data: host }, { data: seats }] = await Promise.all([
    admin.from("profiles").select("nick").eq("id", user.id).maybeSingle(),
    admin.from("seats").select("seat,user_id,profiles(tg_id)").eq("game_id", g.id).not("user_id", "is", null),
  ]);
  let sent = 0;
  await Promise.all((seats || []).map(async (s: any) => {
    const chat = s.profiles?.tg_id;
    if (!chat || s.user_id === user.id) return;
    const r = await tgApi("sendMessage", {
      chat_id: chat,
      text: `🃏 Тебе пришла карта. Место ${s.seat}, ведущий: ${host?.nick || "ведущий"}.\nОткрой, когда никто не смотрит.`,
      reply_markup: { inline_keyboard: [[{ text: "Открыть карту", web_app: { url: APP + "?v=card" } }]] },
    });
    if (r.ok) sent++;
  }));
  return json({ sent });
}

// announcement from @tivishka: plain text, optional photo URL, optional "sign up" button; test = only to the sender
async function broadcast(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const { data: me } = await admin.from("profiles").select("tg_id,tg_username").eq("id", user.id).maybeSingle();
  if ((me?.tg_username || "").toLowerCase() !== "tivishka") return json({ error: "Анонсы делает только @tivishka" }, 403);
  const text = String(body.text || "").trim().slice(0, 4000);
  const photo = typeof body.photo_url === "string" && body.photo_url.startsWith(SB_URL + "/storage/v1/object/public/announce/") ? body.photo_url : null;
  if (!text && !photo) return json({ error: "Пустой анонс" }, 400);
  const markup = body.button ? { inline_keyboard: [[{ text: "Записаться на игру", web_app: { url: APP + "?v=events" } }]] } : undefined;
  let chats: number[];
  if (body.test) chats = [me!.tg_id];
  else {
    const { data } = await admin.from("profiles").select("tg_id").not("tg_id", "is", null);
    chats = (data || []).map((r: any) => r.tg_id).filter((id: number) => !(id >= 990000000 && id <= 990000099));
  }
  let sent = 0;
  const failed: Record<string, number> = {};
  let fileId: string | null = null;
  for (const chat of chats) {
    let r: any;
    if (photo && text.length <= 1024) {
      r = await tgApi("sendPhoto", { chat_id: chat, photo: fileId || photo, caption: text || undefined, reply_markup: markup });
    } else {
      if (photo) { const p = await tgApi("sendPhoto", { chat_id: chat, photo: fileId || photo }); if (p.ok && !fileId) fileId = p.result.photo.at(-1).file_id; }
      r = await tgApi("sendMessage", { chat_id: chat, text, reply_markup: markup, link_preview_options: { is_disabled: false } });
    }
    if (r.ok) { sent++; if (photo && !fileId && r.result?.photo) fileId = r.result.photo.at(-1).file_id; }
    else {
      const why = r.description || "error"; failed[why] = (failed[why] || 0) + 1;
      if (r.error_code === 429) await new Promise((res) => setTimeout(res, (r.parameters?.retry_after || 2) * 1000));
    }
    await new Promise((res) => setTimeout(res, 45));
  }
  return json({ sent, total: chats.length, failed });
}

async function hook(req: Request) {
  if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== HOOK_SECRET) return new Response("forbidden", { status: 401 });
  const upd = await req.json().catch(() => ({}));
  const msg = upd.message;
  if (msg?.chat?.type === "private") {
    await tgApi("sendMessage", {
      chat_id: msg.chat.id,
      text: "Добро пожаловать на дачу! Жми «Играть»: ты сразу появишься в списке дачников. Когда ведущий раздаст роли, карта придёт сюда.",
      reply_markup: { inline_keyboard: [[{ text: "Играть", web_app: { url: APP } }]] },
    });
  }
  return new Response("ok");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (new URL(req.url).searchParams.has("hook")) return hook(req);
  const body = await req.json().catch(() => ({}));
  if (body.action === "auth") return auth(body.initData);
  if (body.action === "notify") return notify(req, body.game_id);
  if (body.action === "broadcast") return broadcast(req, body);
  return json({ error: "unknown action" }, 400);
});
