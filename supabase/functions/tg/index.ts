// DACHA MAFIA · Telegram edge function
// POST {action:"auth", initData}   -> verifies Telegram mini app data, returns a Supabase session
// POST {action:"notify", game_id}  -> host only: bot tells every player their card has arrived
// POST {action:"poll", question, options, test} / {action:"poll_close", poll_id} -> @tivishka only
// POST ?hook=1 (Telegram webhook)  -> answers /start with a "Дача" button, takes poll answers (callback_query pv:<poll>:<i>)
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
  later(syncBirthday(userId, u.id));
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

// announcement from @tivishka: plain text, optional photo OR video URL, optional "sign up" button; test = only to the sender
async function broadcast(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const { data: me } = await admin.from("profiles").select("tg_id,tg_username").eq("id", user.id).maybeSingle();
  // announcements: @tivishka for any game, a host only for the game he hosts
  const game = ["mafia", "volley", "foot"].includes(body.game) ? body.game : "mafia";
  const uname = (me?.tg_username || "").toLowerCase();
  let allowed = uname === "tivishka";
  if (!allowed && game === "mafia" && uname) { const { data: h } = await admin.from("host_allowlist").select("tg_username").eq("tg_username", uname).maybeSingle(); allowed = !!h; }
  if (!allowed && game !== "mafia") { const { data: h } = await admin.from("sport_hosts").select("user_id").eq("user_id", user.id).eq("sport", game).maybeSingle(); allowed = !!h; }
  if (!allowed) return json({ error: "Анонсы по этой игре делает её ведущий" }, 403);
  const text = String(body.text || "").trim().slice(0, 4000);
  const ours = (u: unknown) => typeof u === "string" && u.startsWith(SB_URL + "/storage/v1/object/public/announce/") ? u : null;
  const video = ours(body.video_url);
  const photo = video ? null : ours(body.photo_url);
  if (!text && !photo && !video) return json({ error: "Пустой анонс" }, 400);
  const btn = ({ mafia: ["Записаться на мафию", "?v=events"], volley: ["Записаться на волейбол", "?v=volley"], foot: ["Записаться на футбол", "?v=foot"] } as Record<string, string[]>)[game];
  // a date to sign up for straight from the post: "✋ Я буду" writes the sign-up into the app
  let eventId: string | null = null;
  if (typeof body.event_id === "string" && /^[0-9a-f-]{36}$/i.test(body.event_id)) {
    const { data: ev } = game === "mafia"
      ? await admin.from("events").select("id").eq("id", body.event_id).eq("status", "open").maybeSingle()
      : await admin.from("sport_events").select("id").eq("id", body.event_id).eq("sport", game).neq("status", "removed").maybeSingle();
    eventId = ev?.id || null;
  }
  const joinBtn = eventId ? [{ text: "✋ Я буду", callback_data: `j:${game}:${eventId}` }] : null;
  const markup = body.button ? { inline_keyboard: [...(joinBtn ? [joinBtn] : []), [{ text: joinBtn ? "Открыть в приложении" : btn[0], web_app: { url: APP + btn[1] } }]] } : undefined;
  const groupMarkup = body.button ? { inline_keyboard: [...(joinBtn ? [joinBtn] : []), [{ text: "Открыть DACHA", url: "https://t.me/dacha_play_game" }]] } : undefined;
  let chats: number[];
  if (body.test) chats = [me!.tg_id];
  else {
    const { data } = await admin.from("profiles").select("id,tg_id").not("tg_id", "is", null).or(`notify_all.eq.true,notify_kinds.cs.{${game}}`);
    const { data: bl } = await admin.rpc("blocked_ids"); const blocked = new Set((bl || []).map((x: any) => typeof x === "string" ? x : x.blocked_ids));
    chats = (data || []).filter((r: any) => !blocked.has(r.id)).map((r: any) => r.tg_id).filter((id: number) => !(id >= 990000000 && id <= 990000099));
  }
  let sent = 0;
  const failed: Record<string, number> = {};
  let fileId: string | null = null;
  for (const chat of chats) {
    let r: any;
    // Telegram скачивает файл по ссылке один раз, дальше шлём по file_id
    const media = video
      ? (cap: Record<string, unknown>) => tgApi("sendVideo", { chat_id: chat, video: fileId || video, supports_streaming: true, ...cap })
      : photo ? (cap: Record<string, unknown>) => tgApi("sendPhoto", { chat_id: chat, photo: fileId || photo, ...cap }) : null;
    const keep = (res: any) => {
      if (fileId || !res?.ok) return;
      fileId = video ? res.result?.video?.file_id || res.result?.document?.file_id || null : res.result?.photo?.at(-1)?.file_id || null;
    };
    if (media && text.length <= 1024) {
      r = await media({ caption: text || undefined, reply_markup: markup });
      keep(r);
    } else {
      if (media) keep(await media({}));
      r = await tgApi("sendMessage", { chat_id: chat, text, reply_markup: markup, link_preview_options: { is_disabled: false } });
    }
    if (r.ok) sent++;
    else {
      const why = r.description || "error"; failed[why] = (failed[why] || 0) + 1;
      if (r.error_code === 429) await new Promise((res) => setTimeout(res, (r.parameters?.retry_after || 2) * 1000));
    }
    await new Promise((res) => setTimeout(res, 45));
  }
  // @tivishka's announcements also go to the DACHA group
  let group: string | null = null;
  if (uname === "tivishka" && !body.test) {
    const { data: bc } = await admin.from("bot_chats").select("chat_id").in("status", ["administrator", "member"]).neq("type", "private").order("added_at", { ascending: false }).limit(1).maybeSingle();
    const target = bc?.chat_id || GROUP_CHAT;
    const info: any = await tgApi("getChat", { chat_id: target });
    if (!info.ok) group = "бот не добавлен в группу";
    else {
      const thread = info.result?.is_forum && target === GROUP_CHAT ? { message_thread_id: GROUP_THREAD } : {};
      const gm = video ? (cap: Record<string, unknown>) => tgApi("sendVideo", { chat_id: target, video: fileId || video, supports_streaming: true, ...thread, ...cap })
        : photo ? (cap: Record<string, unknown>) => tgApi("sendPhoto", { chat_id: target, photo: fileId || photo, ...thread, ...cap }) : null;
      let r: any;
      if (gm && text.length <= 1024) r = await gm({ caption: text || undefined, reply_markup: groupMarkup });
      else { if (gm) await gm({}); r = await tgApi("sendMessage", { chat_id: target, text, reply_markup: groupMarkup, ...thread }); }
      group = r.ok ? "ok" : r.description || "ошибка";
    }
  }
  return json({ sent, total: chats.length, failed, group });
}

const GROUP_CHAT = -1002172269288, GROUP_THREAD = 2;
// "✋ Я буду" under an announcement: sign the person up for that date right away
async function joinFromButton(cq: any) {
  const answer = (text: string, alert = false) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text, show_alert: alert });
  const [, g, e] = String(cq.data || "").split(":");
  if (!["mafia", "volley", "foot"].includes(g) || !e) return answer("Не понял кнопку");
  const { data: prof } = await admin.from("profiles").select("id,nick").eq("tg_id", cq.from?.id).maybeSingle();
  if (!prof) return answer("Сначала открой бота @dacha_play_game и нажми «Дача», потом жми «Я буду» ещё раз", true);
  const table = g === "mafia" ? "signups" : "sport_signups";
  const { data: ev } = g === "mafia"
    ? await admin.from("events").select("id,day,status").eq("id", e).maybeSingle()
    : await admin.from("sport_events").select("id,day,status").eq("id", e).maybeSingle();
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Bangkok" }).format(new Date());
  if (!ev || (g === "mafia" ? ev.status !== "open" : ev.status === "removed")) return answer("Эта игра уже недоступна", true);
  if (ev.day < today) return answer("Эта игра уже прошла", true);
  const { data: ex } = await admin.from(table).select("user_id").eq("event_id", e).eq("user_id", prof.id).maybeSingle();
  if (ex) await answer("Ты уже записан ✓");
  else {
    const { error } = await admin.from(table).insert({ event_id: e, user_id: prof.id, role: "player" });
    if (error) return answer(/blocked/.test(error.message) ? "Долг 1000 ฿ и больше — сначала пополни баланс в приложении" : "Не получилось записать, попробуй в приложении", true);
    await answer(`Записал тебя, ${prof.nick} ✓ Оплатить можно в приложении`);
  }
  // in private: "coming with someone?" — +1/+2/+3 shows next to the name in the list
  if (cq.from?.id) {
    const GN: Record<string, string> = { mafia: "мафию", volley: "волейбол", foot: "футбол" };
    await tgApi("sendMessage", { chat_id: cq.from.id, text: `Ты записан на ${GN[g]} ✓
Придёшь не один? Отметь, сколько человек будет с тобой — это увидят в списке.`,
      reply_markup: { inline_keyboard: [[1, 2, 3].map((n) => ({ text: `+${n}`, callback_data: `p:${g}:${e}:${n}` })), [{ text: "Иду один", callback_data: `p:${g}:${e}:0` }]] } });
  }
  const { data: rowsP } = await admin.from(table).select("plus").eq("event_id", e).eq("role", "player");
  const count = (rowsP || []).reduce((a: number, r: any) => a + 1 + (r.plus || 0), 0);
  const kb = cq.message?.reply_markup?.inline_keyboard;
  if (kb && cq.message) {
    const next = kb.map((row: any[]) => row.map((b: any) => (b.callback_data === cq.data ? { ...b, text: `✋ Я буду · ${count ?? ""}`.trim() } : b)));
    await tgApi("editMessageReplyMarkup", { chat_id: cq.message.chat.id, message_id: cq.message.message_id, reply_markup: { inline_keyboard: next } });
  }
}

// "+1": the player tells how many friends come with him
async function plusFromButton(cq: any) {
  const answer = (text: string, alert = false) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text, show_alert: alert });
  const [, g, e, nS] = String(cq.data || "").split(":"), n = Number(nS);
  if (!["mafia", "volley", "foot"].includes(g) || !e || !(n >= 0 && n <= 3)) return answer("Не понял кнопку");
  const { data: prof } = await admin.from("profiles").select("id").eq("tg_id", cq.from?.id).maybeSingle();
  if (!prof) return answer("Сначала открой приложение кнопкой «Дача»", true);
  const table = g === "mafia" ? "signups" : "sport_signups";
  const { data: upd } = await admin.from(table).update({ plus: n }).eq("event_id", e).eq("user_id", prof.id).eq("role", "player").select("user_id");
  if (!upd?.length) return answer("Ты уже не записан на эту игру", true);
  await answer(n ? `Отметил: ты и ещё ${n}` : "Отметил: идёшь один");
  if (cq.message) await tgApi("editMessageReplyMarkup", { chat_id: cq.message.chat.id, message_id: cq.message.message_id,
    reply_markup: { inline_keyboard: [[0, 1, 2, 3].map((k) => ({ text: (k === n ? "✔️ " : "") + (k ? `+${k}` : "один"), callback_data: `p:${g}:${e}:${k}` }))] } });
}

// ---------- polls: «кто за мафию?» with answer buttons right in the bot ----------
const escHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const tally = async (pollId: string, n: number) => {
  const { data } = await admin.from("poll_votes").select("option").eq("poll_id", pollId);
  const c = Array(n).fill(0);
  (data || []).forEach((v: any) => { if (v.option >= 0 && v.option < n) c[v.option]++; });
  return c;
};
const pollText = (p: any, counts: number[], mine: number | null) => {
  const total = counts.reduce((a, b) => a + b, 0);
  const lines = p.options.map((o: string, i: number) => `${mine === i ? "▸ " : ""}${escHtml(o)} — <b>${counts[i]}</b>`);
  const tail = p.closed_at ? "Опрос закрыт. Спасибо всем, кто ответил!"
    : mine === null ? "Нажми кнопку ниже, чтобы ответить." : `Твой ответ: ${escHtml(p.options[mine])}. Передумал — нажми другую кнопку.`;
  return `📊 <b>Опрос · DACHA MAFIA</b>\n\n<b>${escHtml(p.question)}</b>\n\n${lines.join("\n")}\n\nОтветили: ${total}\n${tail}`;
};
const pollKeys = (p: any, mine: number | null) => p.closed_at ? { inline_keyboard: [] }
  : { inline_keyboard: p.options.map((o: string, i: number) => [{ text: (mine === i ? "✔️ " : "") + o, callback_data: `pv:${p.id}:${i}` }]) };

// a player says "I paid for PREMIUM": tell @tivishka in the bot, with a button to the payments screen
// Баланс Дачи: дачник пополнил кассу (наличными / QR) — @tivishka подтверждает в приложении
async function fundNotify(req: Request, _body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const { data: tx } = await admin.from("fund_tx").select("amount,method,note").eq("user_id", user.id).eq("status", "pending").order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!tx) return json({ ok: false });
  const { data: who } = await admin.from("profiles").select("nick,tg_username").eq("id", user.id).maybeSingle();
  const { data: own } = await admin.from("profiles").select("tg_id").ilike("tg_username", "tivishka").maybeSingle();
  if (!own?.tg_id) return json({ ok: false });
  await tgApi("sendMessage", { chat_id: own.tg_id, text: `🏡 Баланс Дачи
${who?.nick || "Дачник"}${who?.tg_username ? " (@" + who.tg_username + ")" : ""} пополняет кассу на ${tx.amount} ฿ · ${tx.method === "qr" ? "перевод по QR" : "наличными тебе"}.${tx.note ? "\nКомментарий: " + tx.note : ""}
Проверь, что деньги пришли, и подтверди в приложении.`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть кассу Дачи", web_app: { url: APP + "?v=fund" } }]] } });
  return json({ ok: true });
}

async function premiumNotify(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const kind = body?.kind === "withdraw" ? "withdraw" : "premium";
  const { data: tx } = await admin.from("wallet_tx").select("amount,currency,method,note").eq("user_id", user.id).eq("purpose", kind).eq("status", "pending").order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!tx) return json({ ok: false });
  const { data: who } = await admin.from("profiles").select("nick,tg_username").eq("id", user.id).maybeSingle();
  const { data: own } = await admin.from("profiles").select("tg_id").ilike("tg_username", "tivishka").maybeSingle();
  if (!own?.tg_id) return json({ ok: false });
  const cur = ({ THB: "฿", RUB: "₽", USD: "$" } as Record<string, string>)[tx.currency] || "฿";
  const how = tx.method === "qr" ? "перевод по QR" : tx.method === "cash" ? "наличными тебе" : "перевод";
  if (kind === "withdraw") {
    await tgApi("sendMessage", { chat_id: own.tg_id, text: `💸 Вывод денег
${who?.nick || "Дачник"}${who?.tg_username ? " (@" + who.tg_username + ")" : ""} просит вывести ${-tx.amount} ฿.
Куда: ${tx.note || "—"}
Выплати и отметь в приложении «Запросы».`,
      reply_markup: { inline_keyboard: [[{ text: "Открыть запросы", web_app: { url: APP + "?v=requests" } }]] } });
    return json({ ok: true });
  }
  await tgApi("sendMessage", {
    chat_id: own.tg_id,
    text: `◆ PREMIUM
${who?.nick || "Дачник"}${who?.tg_username ? " (@" + who.tg_username + ")" : ""} оплатил ${tx.amount} ${cur} · ${how}.
Проверь оплату и подтверди в приложении: PREMIUM включится на месяц, +200 ฿ и 50 🍅.`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть оплаты", web_app: { url: APP + "?v=requests" } }]] },
  });
  return json({ ok: true });
}

// money came in: tell the person in the bot (once per wallet row, only fresh confirmed incoming rows)
// DACHA WORLD: "Дениска зовёт тебя на пляж"
async function worldInvite(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user || typeof body.to !== "string") return json({ error: "Нужно войти" }, 401);
  const what = String(body.what || "").slice(0, 60).trim();
  if (!what || body.to === user.id) return json({ error: "Некого звать" }, 400);
  const [{ data: me }, { data: mem }] = await Promise.all([
    admin.from("profiles").select("nick, tg_username").eq("id", user.id).maybeSingle(),
    admin.from("world_members").select("user_id").eq("user_id", user.id).maybeSingle(),
  ]);
  void mem;   // 06.11: DACHA WORLD is open for everybody
  const { data: to } = await admin.from("profiles").select("tg_id").eq("id", body.to).maybeSingle();
  if (!to?.tg_id) return json({ error: "У человека не подключён бот" }, 400);
  let gameUrl = "";
  if (typeof body.game === "string") {
    const { data: g } = await admin.from("world_games").select("id, a, b, kind, players").eq("id", body.game).maybeSingle();
    if (!g || g.a !== user.id || (g.b !== body.to && !(g.players || []).includes(body.to))) return json({ error: "Нет такой партии" }, 400);
    gameUrl = APP + "?v=game&g=" + g.id;
  }
  let invId = "";
  if (typeof body.invite === "string") {
    const { data: inv } = await admin.from("world_invites").select("id, from_id, to_id").eq("id", body.invite).maybeSingle();
    if (!inv || inv.from_id !== user.id || inv.to_id !== body.to) return json({ error: "Нет такого приглашения" }, 400);
    invId = inv.id;
  }
  const { data: pr } = await admin.from("world_presence").select("lat, lng, visible").eq("user_id", user.id).maybeSingle();
  const where = pr?.visible && pr.lat != null ? `\n📍 Где он сейчас: https://maps.google.com/?q=${pr.lat.toFixed(5)},${pr.lng.toFixed(5)}` : "";
  const r: any = await tgApi("sendMessage", { chat_id: to.tg_id, text: `🌍 DACHA WORLD\n${me?.nick || "Дачник"}${me?.tg_username ? " (@" + me.tg_username + ")" : ""} зовёт тебя ${what}${gameUrl ? " ♟" : "!"}${gameUrl ? "" : where}`,
    reply_markup: { inline_keyboard: [
      ...(invId ? [[{ text: "✅ Иду", callback_data: `wi:ok:${invId}` }, { text: "❌ Не могу", callback_data: `wi:no:${invId}` }]] : []),
      [{ text: gameUrl ? "Принять и играть" : invId ? "💬 Договориться в приложении" : "Открыть DACHA", web_app: { url: gameUrl || (invId ? APP + "?v=invite&i=" + invId : APP) } }],
      ...(me?.tg_username ? [[{ text: "Написать в Telegram", url: "https://t.me/" + me.tg_username }]] : [])] } });
  return json({ ok: !!r?.ok, error: r?.ok ? undefined : "Telegram не доставил" });
}

// ---------- chat: a message not read in the app within a few seconds goes to Telegram too ----------
const esc2 = (t: string) => String(t).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c] as string));
async function dmDeliver(m: any) {
  const [{ data: from }, { data: to }] = await Promise.all([
    admin.from("profiles").select("nick, tg_username").eq("id", m.from_id).maybeSingle(),
    admin.from("profiles").select("tg_id").eq("id", m.to_id).maybeSingle(),
  ]);
  if (!to?.tg_id || !m.game_id) return;
  const { data: g } = await admin.from("world_games").select("kind").eq("id", m.game_id).maybeSingle();
  const GN: Record<string, string> = { chess: "шахматы", checkers: "шашки", durak: "дурак" };
  const r: any = await tgApi("sendMessage", { chat_id: to.tg_id, parse_mode: "HTML",
    text: `💬 <b>${esc2(from?.nick || "Дачник")}</b> · ${GN[g?.kind] || "игра"}:\n${esc2(m.body)}\n\n<i>Ответь на это сообщение (свайп влево) — ответ придёт в игру</i>`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть игру", web_app: { url: APP + "?v=game&g=" + m.game_id } }]] } });
  if (r?.ok) await admin.from("dm_messages").update({ tg_msg_id: r.result.message_id }).eq("id", m.id);
}
async function dmNotify(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user || typeof body.id !== "string") return json({ error: "Нужно войти" }, 401);
  const { data: m } = await admin.from("dm_messages").select("*").eq("id", body.id).maybeSingle();
  if (!m || m.from_id !== user.id || m.tg_msg_id || Date.now() - new Date(m.created_at).getTime() > 60000) return json({ ok: true, sent: 0 });
  await new Promise((r) => setTimeout(r, 5000));   // the other one may be in the chat right now
  const { data: again } = await admin.from("dm_messages").select("read_at, tg_msg_id").eq("id", m.id).maybeSingle();
  if (!again || again.read_at || again.tg_msg_id) return json({ ok: true, sent: 0 });
  await dmDeliver(m);
  return json({ ok: true, sent: 1 });
}
// a Telegram reply to a duplicated message → back into the chat
async function dmFromTelegram(msg: any): Promise<boolean> {
  const rid = msg.reply_to_message?.message_id; if (!rid || !msg.text) return false;
  const { data: me } = await admin.from("profiles").select("id").eq("tg_id", msg.from?.id).maybeSingle(); if (!me) return false;
  const { data: orig } = await admin.from("dm_messages").select("from_id, to_id, game_id").eq("tg_msg_id", rid).eq("to_id", me.id).maybeSingle(); if (!orig?.game_id) return false;
  const { data: nm } = await admin.from("dm_messages").insert({ from_id: me.id, to_id: orig.from_id, body: String(msg.text).slice(0, 1000), via_tg: true, game_id: orig.game_id }).select("*").maybeSingle();
  await tgApi("setMessageReaction", { chat_id: msg.chat.id, message_id: msg.message_id, reaction: [{ type: "emoji", emoji: "👍" }] }).catch(() => {});
  if (nm) {
    await new Promise((r) => setTimeout(r, 5000));
    const { data: a } = await admin.from("dm_messages").select("read_at").eq("id", nm.id).maybeSingle();
    if (a && !a.read_at) await dmDeliver(nm);
  }
  return true;
}

// an invitation got an answer: tell the one who invited
const INV_TXT: Record<string, string> = { accepted: "✅ придёт", declined: "❌ не сможет", talk: "💬 ответил" };
async function inviteNotifyFrom(inv: any) {
  const [{ data: to }, { data: from }] = await Promise.all([
    admin.from("profiles").select("nick, tg_username").eq("id", inv.to_id).maybeSingle(),
    admin.from("profiles").select("tg_id").eq("id", inv.from_id).maybeSingle(),
  ]);
  if (!from?.tg_id) return;
  await admin.from("world_invites").update({ notified_at: new Date().toISOString() }).eq("id", inv.id);
  await tgApi("sendMessage", { chat_id: from.tg_id, text: `🌍 ${to?.nick || "Дачник"} ${INV_TXT[inv.status] || ""} — ${inv.what}${inv.reply ? `\n💬 «${inv.reply}»` : ""}`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть DACHA", web_app: { url: APP + "?v=invite&i=" + inv.id } }], ...(to?.tg_username ? [[{ text: "Написать в Telegram", url: "https://t.me/" + to.tg_username }]] : [])] } });
}
async function inviteAnswered(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user || typeof body.invite !== "string") return json({ error: "Нужно войти" }, 401);
  const { data: inv } = await admin.from("world_invites").select("*").eq("id", body.invite).maybeSingle();
  if (!inv || inv.to_id !== user.id || !inv.answered_at) return json({ ok: false });
  if (Date.now() - new Date(inv.answered_at).getTime() > 2 * 60 * 1000) return json({ ok: false });
  if (inv.notified_at && new Date(inv.notified_at) >= new Date(inv.answered_at)) return json({ ok: true, sent: 0 });
  await inviteNotifyFrom(inv);
  return json({ ok: true, sent: 1 });
}
async function inviteCallback(cq: any) {
  const answer = (text: string, alert = false) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text, show_alert: alert });
  const [, how, id] = String(cq.data || "").split(":");
  const { data: prof } = await admin.from("profiles").select("id").eq("tg_id", cq.from?.id).maybeSingle();
  const { data: inv } = await admin.from("world_invites").select("*").eq("id", id).maybeSingle();
  if (!prof || !inv || inv.to_id !== prof.id) return answer("Это приглашение не тебе", true);
  const status = how === "ok" ? "accepted" : "declined";
  const { data: upd } = await admin.from("world_invites").update({ status, answered_at: new Date().toISOString() }).eq("id", id).select("*").maybeSingle();
  await answer(status === "accepted" ? "Отлично, он узнает ✅" : "Ок, передам ❌");
  if (cq.message) await tgApi("editMessageReplyMarkup", { chat_id: cq.message.chat.id, message_id: cq.message.message_id,
    reply_markup: { inline_keyboard: [[{ text: status === "accepted" ? "✅ Ты идёшь" : "❌ Ты отказался", callback_data: "noop" }], [{ text: "💬 Договориться в приложении", web_app: { url: APP + "?v=invite&i=" + id } }]] } });
  if (upd) await inviteNotifyFrom(upd);
}

// a tomato that didn't land on a screen (app closed): the bot tells the target
async function tomatoNotify(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user || typeof body.to !== "string") return json({ error: "Нужно войти" }, 401);
  const { data: t } = await admin.from("tomato_throws").select("id, to_id, created_at").eq("from_id", user.id).eq("to_id", body.to)
    .is("notified_at", null).gte("created_at", new Date(Date.now() - 2 * 60 * 1000).toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!t) return json({ ok: true, sent: 0 });
  await new Promise((r) => setTimeout(r, 8000));   // give the open app time to catch it
  const { data: again } = await admin.from("tomato_throws").select("seen_at, notified_at").eq("id", t.id).maybeSingle();
  if (!again || again.seen_at || again.notified_at) return json({ ok: true, sent: 0 });
  await admin.from("tomato_throws").update({ notified_at: new Date().toISOString() }).eq("id", t.id);
  const [{ data: to }, { data: from }] = await Promise.all([
    admin.from("profiles").select("tg_id").eq("id", t.to_id).maybeSingle(),
    admin.from("profiles").select("nick").eq("id", user.id).maybeSingle(),
  ]);
  if (!to?.tg_id) return json({ ok: true, sent: 0 });
  await tgApi("sendMessage", { chat_id: to.tg_id, text: `🍅 В тебя прилетел помидор от ${from?.nick || "дачника"}!
Открой DACHA — экран уже испачкан, придётся оттирать 😄`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть DACHA", web_app: { url: APP } }]] } });
  return json({ ok: true, sent: 1 });
}

async function walletNotify(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const ids = (Array.isArray(body.tx) ? body.tx : [body.tx]).filter((x: unknown) => typeof x === "string").slice(0, 5);
  let sent = 0;
  for (const id of ids) {
    const { data: t } = await admin.from("wallet_tx").select("id,user_id,amount,method,purpose,currency,status,peer_id,note,decided_at,notified_at").eq("id", id).maybeSingle();
    if (!t || t.status !== "confirmed" || t.notified_at) continue;
    if (t.amount <= 0 && t.purpose !== "withdraw") continue;
    if (!t.decided_at || Date.now() - new Date(t.decided_at).getTime() > 15 * 60 * 1000) continue;
    const { data: to } = await admin.from("profiles").select("tg_id").eq("id", t.user_id).maybeSingle();
    if (!to?.tg_id) continue;
    let text = "";
    if (t.purpose === "withdraw") {
      text = `💸 Вывод ${-t.amount} ฿ выполнен. Деньги отправлены: ${t.note || "как ты просил"}.`;
    } else if (t.purpose === "premium") {
      text = "◆ DACHA PREMIUM включён на месяц!\nБез рекламы, своя иконка, +200 ฿ на счёт и 50 🍅.";
    } else if (t.method === "transfer") {
      const { data: from } = await admin.from("profiles").select("nick,tg_username").eq("id", t.peer_id).maybeSingle();
      const msg = String(t.note || "").trim();
      text = `💸 ${from?.nick || "Дачник"}${from?.tg_username ? " (@" + from.tg_username + ")" : ""} перевёл тебе ${t.amount} ฿ на счёт DACHA.`
        + (msg && !msg.startsWith("Перевод от ") ? `

💬 «${msg}»` : "");
    } else if (t.method === "adjust") {
      text = `💸 На твой счёт DACHA пришло ${t.amount} ฿${t.note ? " · " + t.note : ""}.`;
    } else if (t.purpose === "gamepay") {
      text = `✅ Ведущий отметил: игра оплачена (${t.amount} ฿).`;
    } else {
      text = `✅ Оплата подтверждена: +${t.amount} ฿ на твой счёт DACHA.`;
    }
    await admin.from("wallet_tx").update({ notified_at: new Date().toISOString() }).eq("id", t.id);
    await tgApi("sendMessage", { chat_id: to.tg_id, text, reply_markup: { inline_keyboard: [[{ text: "Открыть баланс", web_app: { url: APP + "?v=pay" } }]] } });
    sent++;
  }
  return json({ ok: true, sent });
}

// birthday from the Telegram profile (if the person shows it); a date set by hand is kept
async function syncBirthday(userId: string, tgId: number) {
  const r: any = await tgApi("getChat", { chat_id: tgId });
  const b = r?.result?.birthdate;
  if (!b?.day || !b?.month) return;
  await admin.from("profiles").update({ birth_day: b.day, birth_month: b.month, birth_year: b.year ?? null, birth_src: "tg" }).eq("id", userId).or("birth_src.is.null,birth_src.eq.tg");
}

// ---------- community events: submitted → @tivishka approves → subscribers get it with "✋ Я буду" ----------
const DOWS = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"], MONS = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
const ruDay = (iso: string) => { const [y, m, d] = iso.split("-").map(Number); const w = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); return `${DOWS[w]}, ${d} ${MONS[m - 1]}`; };
const bkkToday = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Bangkok" }).format(new Date());
const nextDay = (ev: any) => { if (!ev.weekly) return ev.day; let d = ev.day; const t = bkkToday(); while (d < t) { const [y, m, dd] = d.split("-").map(Number); d = new Date(Date.UTC(y, m - 1, dd + 7)).toISOString().slice(0, 10); } return d; };
async function ceventText(ev: any) {
  const { data: org } = await admin.from("profiles").select("nick,tg_username").eq("id", ev.created_by).maybeSingle();
  let place = ev.place || "";
  if (ev.place_id) { const { data: pl } = await admin.from("places").select("name").eq("id", ev.place_id).maybeSingle(); place = pl?.name || place; }
  return `${ev.emoji || "✨"} ${ev.title}\n${ruDay(nextDay(ev))} · ${String(ev.start_time).slice(0, 5)}${ev.weekly ? " · каждую неделю" : ""}\n${place ? "📍 " + place + "\n" : ""}${ev.price ? "Цена: " + ev.price + " ฿" : "Бесплатно"}\nОрганизатор: ${org?.nick || "дачник"}${org?.tg_username ? " (@" + org.tg_username + ")" : ""}${ev.description ? "\n\n" + ev.description : ""}`;
}
async function ownerTg() { const { data } = await admin.from("profiles").select("tg_id").ilike("tg_username", "tivishka").maybeSingle(); return data?.tg_id || null; }
async function ceventSubmitted(req: Request, body: any) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Нужно войти" }, 401);
  const { data: ev } = await admin.from("cevents").select("*").eq("id", body.id).eq("created_by", user.id).eq("status", "pending").maybeSingle();
  if (!ev) return json({ ok: false });
  const own = await ownerTg(); if (!own) return json({ ok: false });
  await tgApi("sendMessage", { chat_id: own, text: "🆕 Новый ивент на проверку\n\n" + await ceventText(ev),
    reply_markup: { inline_keyboard: [[{ text: "✅ Одобрить", callback_data: `ce:ok:${ev.id}` }, { text: "❌ Отклонить", callback_data: `ce:no:${ev.id}` }]] } });
  return json({ ok: true });
}
async function decideCevent(id: string, ok: boolean) {
  const { data: ev } = await admin.from("cevents").select("*").eq("id", id).maybeSingle();
  if (!ev || ev.status !== "pending") return { ok: false, why: ev ? "уже решено" : "нет такого" };
  await admin.from("cevents").update({ status: ok ? "approved" : "rejected", decided_at: new Date().toISOString() }).eq("id", id);
  const { data: org } = await admin.from("profiles").select("tg_id").eq("id", ev.created_by).maybeSingle();
  if (org?.tg_id) await tgApi("sendMessage", { chat_id: org.tg_id, text: ok ? `✅ Твой ивент «${ev.title}» одобрен и разослан дачникам. Кто записался — видно в приложении.` : `❌ Ивент «${ev.title}» не прошёл проверку. Поправь и создай заново.`,
    reply_markup: { inline_keyboard: [[{ text: "Открыть DACHA", web_app: { url: APP + "?v=cevent&e=" + id } }]] } });
  let sent = 0;
  if (ok) {
    const text = "✨ Новый ивент на даче\n\n" + await ceventText(ev);
    const day = nextDay(ev);
    const { data: people } = await admin.from("profiles").select("id,tg_id").not("tg_id", "is", null).or("notify_all.eq.true,notify_kinds.cs.{community}");
    const { data: bl } = await admin.rpc("blocked_ids"); const blocked = new Set((bl || []).map((x: any) => typeof x === "string" ? x : x.blocked_ids));
    for (const r of people || []) {
      if (blocked.has(r.id)) continue;
      if (r.tg_id >= 990000000 && r.tg_id <= 990000099) continue;
      const res: any = await tgApi("sendMessage", { chat_id: r.tg_id, text, reply_markup: { inline_keyboard: [[{ text: "✋ Я буду", callback_data: `cj:${id}:${day}` }], [{ text: "Открыть в приложении", web_app: { url: APP + "?v=cevent&e=" + id } }]] } });
      if (res.ok) sent++;
      await new Promise((r2) => setTimeout(r2, 45));
    }
    await admin.from("cevents").update({ announced_at: new Date().toISOString() }).eq("id", id);
  }
  return { ok: true, sent };
}
async function ceventDecide(req: Request, body: any) {
  const me = await adminOf(req);
  if (!me) return json({ error: "Одобряет только @tivishka" }, 403);
  return json(await decideCevent(String(body.id || ""), !!body.ok));
}
async function ceventCallback(cq: any) {
  const answer = (text: string, alert = false) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text, show_alert: alert });
  const [, how, id] = String(cq.data).split(":");
  const own = await ownerTg();
  if (!own || cq.from?.id !== own) return answer("Одобряет только @tivishka", true);
  const r: any = await decideCevent(id, how === "ok");
  if (!r.ok) return answer(r.why || "Не получилось", true);
  await answer(how === "ok" ? `Одобрено, разослано ${r.sent}` : "Отклонено");
  if (cq.message) await tgApi("editMessageReplyMarkup", { chat_id: cq.message.chat.id, message_id: cq.message.message_id, reply_markup: { inline_keyboard: [[{ text: how === "ok" ? `✅ Одобрено · разослано ${r.sent}` : "❌ Отклонено", callback_data: "noop" }]] } });
}
async function ceventJoin(cq: any) {
  const answer = (text: string, alert = false) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text, show_alert: alert });
  const [, id, day0] = String(cq.data).split(":");
  const { data: prof } = await admin.from("profiles").select("id,nick").eq("tg_id", cq.from?.id).maybeSingle();
  if (!prof) return answer("Сначала открой бота @dacha_play_game и нажми «Дача», потом жми «Я буду» ещё раз", true);
  const { data: ev } = await admin.from("cevents").select("*").eq("id", id).maybeSingle();
  if (!ev || ev.status !== "approved") return answer("Этот ивент уже недоступен", true);
  const day = day0 >= bkkToday() ? day0 : nextDay(ev);
  const { data: ex } = await admin.from("csignups").select("user_id").eq("event_id", id).eq("day", day).eq("user_id", prof.id).maybeSingle();
  if (ex) await answer("Ты уже записан ✓");
  else { const { error } = await admin.from("csignups").insert({ event_id: id, day, user_id: prof.id }); if (error) return answer(/blocked/.test(error.message) ? "Долг 1000 ฿ и больше — сначала пополни баланс в приложении" : "Не получилось, попробуй в приложении", true); await answer(`Записал тебя, ${prof.nick} ✓`); }
  const { count } = await admin.from("csignups").select("user_id", { count: "exact", head: true }).eq("event_id", id).eq("day", day);
  const kb = cq.message?.reply_markup?.inline_keyboard;
  if (kb && cq.message) await tgApi("editMessageReplyMarkup", { chat_id: cq.message.chat.id, message_id: cq.message.message_id, reply_markup: { inline_keyboard: kb.map((row: any[]) => row.map((b: any) => (b.callback_data === cq.data ? { ...b, text: `✋ Я буду · ${count ?? ""}`.trim() } : b))) } });
}

async function adminOf(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return null;
  const { data: me } = await admin.from("profiles").select("id,tg_id,tg_username").eq("id", user.id).maybeSingle();
  return (me?.tg_username || "").toLowerCase() === "tivishka" ? me : null;
}

async function pollCreate(req: Request, body: any) {
  const me = await adminOf(req);
  if (!me) return json({ error: "Опросы делает только @tivishka" }, 403);
  const question = String(body.question || "").trim().slice(0, 300);
  const options = (Array.isArray(body.options) ? body.options : []).map((o: unknown) => String(o || "").trim().slice(0, 40)).filter(Boolean).slice(0, 6);
  if (!question || options.length < 2) return json({ error: "Нужен вопрос и хотя бы два ответа" }, 400);
  let chats: number[];
  if (body.test) chats = [me.tg_id];
  else {
    const { data } = await admin.from("profiles").select("tg_id").not("tg_id", "is", null);
    chats = (data || []).map((r: any) => r.tg_id).filter((id: number) => !(id >= 990000000 && id <= 990000099));
  }
  const { data: p, error } = await admin.from("polls").insert({ question, options, created_by: me.id, test: !!body.test, total: chats.length }).select().single();
  if (error) return json({ error: error.message }, 500);
  const zero = Array(options.length).fill(0);
  let sent = 0;
  const failed: Record<string, number> = {};
  for (const chat of chats) {
    const r = await tgApi("sendMessage", { chat_id: chat, text: pollText(p, zero, null), parse_mode: "HTML", reply_markup: pollKeys(p, null) });
    if (r.ok) { sent++; await admin.from("poll_msgs").upsert({ poll_id: p.id, chat_id: chat, message_id: r.result.message_id }); }
    else {
      const why = r.description || "error"; failed[why] = (failed[why] || 0) + 1;
      if (r.error_code === 429) await new Promise((res) => setTimeout(res, (r.parameters?.retry_after || 2) * 1000));
    }
    await new Promise((res) => setTimeout(res, 45));
  }
  await admin.from("polls").update({ sent }).eq("id", p.id);
  return json({ id: p.id, sent, total: chats.length, failed });
}

// closing freezes the poll and turns every bot message into the final result
async function pollClose(req: Request, body: any) {
  if (!(await adminOf(req))) return json({ error: "Опросы закрывает только @tivishka" }, 403);
  const { data: p } = await admin.from("polls").update({ closed_at: new Date().toISOString() }).eq("id", body.poll_id).is("closed_at", null).select().maybeSingle();
  if (!p) return json({ error: "Опрос уже закрыт" }, 400);
  const counts = await tally(p.id, p.options.length);
  const [{ data: msgs }, { data: votes }] = await Promise.all([
    admin.from("poll_msgs").select("chat_id,message_id").eq("poll_id", p.id),
    admin.from("poll_votes").select("option,profiles(tg_id)").eq("poll_id", p.id),
  ]);
  const mineBy = new Map((votes || []).map((v: any) => [Number(v.profiles?.tg_id), v.option]));
  for (const m of msgs || []) {
    await tgApi("editMessageText", { chat_id: m.chat_id, message_id: m.message_id, text: pollText(p, counts, mineBy.get(Number(m.chat_id)) ?? null), parse_mode: "HTML", reply_markup: pollKeys(p, null) });
    await new Promise((res) => setTimeout(res, 45));
  }
  return json({ ok: true, counts });
}

async function pollVote(cq: any) {
  const [, pollId, idx] = String(cq.data).split(":");
  const i = Number(idx);
  const answer = (text: string) => tgApi("answerCallbackQuery", { callback_query_id: cq.id, text });
  const { data: p } = await admin.from("polls").select("*").eq("id", pollId).maybeSingle();
  if (!p) return answer("Опрос не найден");
  if (p.closed_at) return answer("Опрос уже закрыт");
  if (!(i >= 0 && i < p.options.length)) return answer("Нет такого ответа");
  const { data: prof } = await admin.from("profiles").select("id").eq("tg_id", cq.from.id).maybeSingle();
  if (!prof) return answer("Сначала нажми «Дача» в боте, чтобы попасть в список дачников");
  await admin.from("poll_votes").upsert({ poll_id: p.id, user_id: prof.id, option: i, voted_at: new Date().toISOString() });
  const counts = await tally(p.id, p.options.length);
  if (cq.message) {
    await tgApi("editMessageText", { chat_id: cq.message.chat.id, message_id: cq.message.message_id, text: pollText(p, counts, i), parse_mode: "HTML", reply_markup: pollKeys(p, i) });
  }
  return answer(`Записал: ${p.options[i]}`);
}

async function hook(req: Request) {
  if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== HOOK_SECRET) return new Response("forbidden", { status: 401 });
  const upd = await req.json().catch(() => ({}));
  if (upd.callback_query?.data?.startsWith("pv:")) { await pollVote(upd.callback_query); return new Response("ok"); }
  if (upd.my_chat_member) {
    const m = upd.my_chat_member, ch = m.chat || {}, st = m.new_chat_member?.status;
    if (ch.type !== "private") {
      await admin.from("bot_chats").upsert({ chat_id: ch.id, title: ch.title || "", type: ch.type, is_forum: !!ch.is_forum, status: st, added_at: new Date().toISOString() });
      const { data: own } = await admin.from("profiles").select("tg_id").ilike("tg_username", "tivishka").maybeSingle();
      if (own?.tg_id) await tgApi("sendMessage", { chat_id: own.tg_id, text: ["administrator", "member"].includes(st)
        ? `✅ Меня добавили в «${ch.title || ch.id}» (${st === "administrator" ? "админ" : "участник"}). Твои анонсы теперь будут дублироваться туда.${st === "member" && ch.type === "channel" ? " Для канала нужен статус администратора." : ""}`
        : `ℹ️ Меня убрали из «${ch.title || ch.id}».` });
    }
    return new Response("ok");
  }
  if (upd.callback_query?.data?.startsWith("ce:")) { await ceventCallback(upd.callback_query); return new Response("ok"); }
  if (upd.callback_query?.data?.startsWith("cj:")) { await ceventJoin(upd.callback_query); return new Response("ok"); }
  if (upd.callback_query?.data === "noop") { await tgApi("answerCallbackQuery", { callback_query_id: upd.callback_query.id }); return new Response("ok"); }
  if (upd.callback_query?.data?.startsWith("j:")) { await joinFromButton(upd.callback_query); return new Response("ok"); }
  if (upd.callback_query?.data?.startsWith("p:")) { await plusFromButton(upd.callback_query); return new Response("ok"); }
  if (upd.callback_query?.data?.startsWith("wi:")) { await inviteCallback(upd.callback_query); return new Response("ok"); }
  // live location shared with the bot keeps the map fresh even when the app is closed
  const loc = (upd.edited_message || upd.message);
  if (loc?.chat?.type === "private" && loc.location) {
    const { data: who } = await admin.from("profiles").select("id").eq("tg_id", loc.from?.id).maybeSingle();
    if (who) {
      const { data: had } = await admin.from("world_presence").select("status, emoji").eq("user_id", who.id).maybeSingle();
      await admin.from("world_presence").upsert({ user_id: who.id, lat: loc.location.latitude, lng: loc.location.longitude, visible: true, status: had?.status ?? null, emoji: had?.emoji ?? null, updated_at: new Date().toISOString() });
      if (upd.message) {
        const t = new Date().toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
        await tgApi("sendMessage", { chat_id: loc.chat.id, reply_markup: { remove_keyboard: true },
          text: loc.location.live_period ? `✅ Трансляция включена — ты на карте DACHA, точка двигается сама.` : `✅ Готово! Ты на карте DACHA (обновлено в ${t}).` });
        await tgApi("sendMessage", { chat_id: loc.chat.id, text: "Открыть карту:", reply_markup: { inline_keyboard: [[{ text: "🗺 Карта дачников", web_app: { url: APP + "?v=map" } }]] } });
      }
    } else if (upd.message) await tgApi("sendMessage", { chat_id: loc.chat.id, text: "Сначала открой DACHA кнопкой «Дача», потом пришли геопозицию ещё раз." });
    return new Response("ok");
  }
  const msg = upd.message;
  if (msg?.chat?.type === "private" && msg.reply_to_message && await dmFromTelegram(msg)) return new Response("ok");
  if (msg?.chat?.type === "private") {
    await tgApi("sendMessage", {
      chat_id: msg.chat.id,
      text: "DACHA — дом вдали от дома\n\nНажми «Дача» и попадёшь в расписание ближайших ивентов, рейтинги и профили друзей. Когда ведущий мафии раздаст роли, карта придёт сюда.",
      reply_markup: { inline_keyboard: [[{ text: "Дача", web_app: { url: APP } }]] },
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
  if (body.action === "premium_notify") return premiumNotify(req, body);
  if (body.action === "fund_notify") return fundNotify(req, body);
  if (body.action === "cevent_submitted") return ceventSubmitted(req, body);
  if (body.action === "cevent_decide") return ceventDecide(req, body);
  if (body.action === "wallet_notify") return walletNotify(req, body);
  if (body.action === "tomato_notify") return tomatoNotify(req, body);
  if (body.action === "world_invite") return worldInvite(req, body);
  if (body.action === "invite_answered") return inviteAnswered(req, body);
  if (body.action === "dm_notify") return dmNotify(req, body);
  if (body.action === "live_hint") {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return json({ error: "Нужно войти" }, 401);
    const { data: p } = await admin.from("profiles").select("tg_id").eq("id", user.id).maybeSingle();
    if (p?.tg_id) await tgApi("sendMessage", { chat_id: p.tg_id, text: `📍 Ты на карте DACHA!

Чтобы точка обновлялась сама, даже когда приложение закрыто:
📎 → Геопозиция → «Транслировать геопозицию» → «Пока не выключу».

Или нажми кнопку ниже — отправит твоё место один раз.`,
      reply_markup: { keyboard: [[{ text: "📍 Отправить мою геопозицию", request_location: true }]], resize_keyboard: true, one_time_keyboard: true } });
    return json({ ok: true });
  }
  if (body.action === "poll") return pollCreate(req, body);
  if (body.action === "poll_close") return pollClose(req, body);
  return json({ error: "unknown action" }, 400);
});
