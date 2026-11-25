// Transfer Defteri — U-ETDS gönderici
// Sabit IP'li bir sunucuda çalışır. Onaylanan rezervasyonları U-ETDS (tarifesiz / arızi yolcu) web servisine bildirir,
// iptal edilenlerin seferini iptal eder ve sonucu rezervasyona yazar.
//
// Çalıştırma:  SUPABASE_URL=... SUPABASE_SERVICE_KEY=... node worker.mjs
// Kontrol:     node worker.mjs --wsdl          (U-ETDS servis metotlarını ve alan adlarını listeler)
//              node worker.mjs --dry <id>      (bir rezervasyon için gidecek XML'i gösterir, göndermez)
//
// Bağımlılık yok (Node 18+). Gizli anahtarlar yalnızca ortam değişkenlerinden okunur.

const SB = (process.env.SUPABASE_URL || "").replace(/\/$/, "");
const KEY = process.env.SUPABASE_SERVICE_KEY || "";
const POLL_MS = +(process.env.POLL_MS || 20000);
const LEG_HOURS = +(process.env.LEG_HOURS || 2);           // sefer bitişi için tahmini süre
const ENDPOINT = {
  test: process.env.UETDS_TEST_URL || "https://servis.turkiye.gov.tr/services/g2g/kdgm/test/uetdsarizi",
  live: process.env.UETDS_LIVE_URL || "https://servis.turkiye.gov.tr/services/g2g/kdgm/uetdsarizi",
};
const NS = process.env.UETDS_NS || "http://uetds.unetws.udhb.gov.tr/";

if (!SB || !KEY) { console.error("SUPABASE_URL ve SUPABASE_SERVICE_KEY gerekli"); process.exit(1); }

/* ---------------- Supabase (REST) ---------------- */
const H = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
async function rest(path, opt = {}) {
  const r = await fetch(SB + "/rest/v1/" + path, { ...opt, headers: { ...H, ...(opt.headers || {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}
const rpc = (fn, body = {}) => rest("rpc/" + fn, { method: "POST", body: JSON.stringify(body) });
const patchBooking = (id, row) => rest("bookings?id=eq." + id, { method: "PATCH", body: JSON.stringify(row), headers: { Prefer: "return=minimal" } });
async function account(cid) { const r = await rest(`uetds_accounts?company_id=eq.${cid}&select=*`); return r && r[0]; }
async function drivers(cid) { const r = await rest(`settings?company_id=eq.${cid}&select=drivers`); return (r && r[0] && r[0].drivers) || []; }

/* ---------------- SOAP ---------------- */
const x = v => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const el = (name, obj) => `<${name}>${Object.entries(obj).filter(([, v]) => v !== undefined && v !== null && v !== "").map(([k, v]) => `<${k}>${x(v)}</${k}>`).join("")}</${name}>`;
function envelope(op, parts) {
  return `<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:u="${NS}"><soapenv:Header/><soapenv:Body><u:${op}>${parts.join("")}</u:${op}></soapenv:Body></soapenv:Envelope>`;
}
const pick = (xml, tag) => { const m = xml.match(new RegExp(`<(?:\\w+:)?${tag}>([\\s\\S]*?)</(?:\\w+:)?${tag}>`)); return m ? m[1].trim() : null; };
async function call(acc, op, parts, dry) {
  const body = envelope(op, [el("wsuser", { kullaniciAdi: acc.ws_user, sifre: acc.ws_pass }), ...parts]);
  if (dry) { console.log("\n--- " + op + " ---\n" + body.replace(/<sifre>.*?<\/sifre>/, "<sifre>***</sifre>")); return { sonucKodu: "0", ref: "DRY" }; }
  const url = acc.test_mode ? ENDPOINT.test : ENDPOINT.live;
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "text/xml; charset=utf-8", SOAPAction: "" }, body });
  const t = await r.text();
  const fault = pick(t, "faultstring");
  if (fault) throw new Error(`${op}: ${fault}`);
  const kod = pick(t, "sonucKodu"), msg = pick(t, "sonucMesaji");
  if (kod !== "0") throw new Error(`${op}: ${msg || ("HTTP " + r.status + " " + t.slice(0, 200))}`);
  return { sonucKodu: kod, msg, ref: pick(t, "uetdsSeferReferansNo"), grup: pick(t, "uetdsGrupRefNo") };
}

/* ---------------- Rezervasyon → sefer ---------------- */
function addHours(date, time, h) {
  const d = new Date(`${date}T${(time || "00:00").slice(0, 5)}:00Z`); d.setUTCHours(d.getUTCHours() + h);
  return [d.toISOString().slice(0, 10), d.toISOString().slice(11, 16)];
}
const splitName = n => { const p = String(n || "").trim().split(/\s+/); return p.length > 1 ? [p.slice(0, -1).join(" "), p.at(-1)] : [p[0] || "", "-"]; };
function missing(b, drv) {
  const m = [];
  if (!b.plate) m.push("plaka");
  if (!drv) m.push("şoför"); else if (!drv.doc) m.push("şoför TC no");
  const ps = b.passengers || [];
  if (!ps.length) m.push("yolcu listesi");
  ps.forEach((p, i) => { const k = []; if (!p.name) k.push("ad"); if (!p.nat) k.push("uyruk"); if (!p.sex) k.push("cinsiyet"); if (!p.doc) k.push("kimlik no"); if (k.length) m.push(`${i + 1}. yolcu ${k.join("/")}`); });
  return m;
}
function legs(b, acc) {
  const start = acc.start_place || b.from_place || "Havalimanı";
  const hotel = [b.hotel, b.area].filter(Boolean).join(", ") || b.to_place || "Otel";
  const L = [{ key: "G", date: b.date, time: b.time, from: start, to: hotel, flight: b.flight }];
  if (b.return_date && b.return_time) L.push({ key: "D", date: b.return_date, time: b.return_time, from: hotel, to: start, flight: b.return_flight });
  return L;
}
async function send(b, dry) {
  const acc = await account(b.company_id);
  if (!acc || !acc.enabled) throw new Error("Firmanın U-ETDS ayarı kapalı");
  if (!acc.ws_user || !acc.ws_pass) throw new Error("U-ETDS web servis kullanıcı adı/şifresi eksik");
  const drv = (await drivers(b.company_id)).find(d => d.name === b.driver_name);
  const miss = missing(b, drv);
  if (miss.length) throw new Error("Eksik bilgi: " + miss.join(", "));
  const refs = [];
  for (const g of legs(b, acc)) {
    const [bd, bt] = addHours(g.date, g.time, LEG_HOURS);
    const s = await call(acc, "seferEkle", [el("ariziSeferBilgileriInput", {
      aracPlaka: b.plate.replace(/\s+/g, ""), hareketTarihi: g.date, hareketSaati: (g.time || "").slice(0, 5),
      seferAciklama: `${g.from} - ${g.to}${g.flight ? " (" + g.flight + ")" : ""}`.slice(0, 500),
      aracTelefonu: b.driver_phone || "", firmaSeferNo: String(b.id).slice(0, 8) + g.key,
      seferBitisTarihi: bd, seferBitisSaati: bt })], dry);
    const ref = s.ref;
    const gr = await call(acc, "seferGrupEkle", [`<uetdsSeferReferansNo>${x(ref)}</uetdsSeferReferansNo>`, el("ariziGrupBilgileriInput", {
      grupAciklama: `${b.first_name || ""} ${b.last_name || ""}`.trim().slice(0, 500), grupAdi: `${b.last_name || b.first_name || "Grup"}`.slice(0, 50),
      baslangicUlke: "TR", baslangicIl: acc.start_il || "", baslangicIlce: acc.start_ilce || "", baslangicYer: g.from.slice(0, 200),
      bitisUlke: "TR", bitisIl: acc.start_il || "", bitisIlce: acc.start_ilce || "", bitisYer: g.to.slice(0, 200),
      grupUcret: "0" })], dry);
    await call(acc, "personelEkle", [`<uetdsSeferReferansNo>${x(ref)}</uetdsSeferReferansNo>`, el("ariziSeferPersonelBilgileriInput", (() => {
      const [ad, soyad] = splitName(drv.name);
      return { turKodu: 0, uyrukUlke: drv.nat || "TR", tcKimlikPasaportNo: drv.doc, cinsiyet: drv.sex || "E", adi: ad, soyadi: soyad, telefon: drv.phone || b.driver_phone || "", adres: g.from.slice(0, 50) };
    })())], dry);
    for (const [i, p] of (b.passengers || []).entries()) {
      const [ad, soyad] = splitName(p.name);
      await call(acc, "yolcuEkle", [`<uetdsSeferReferansNo>${x(ref)}</uetdsSeferReferansNo>`, el("ariziSeferYolcuBilgileriInput", {
        uyrukUlke: p.nat, cinsiyet: p.sex, tcKimlikPasaportNo: p.doc, adi: ad, soyadi: soyad, koltukNo: String(i + 1),
        telefonNo: i === 0 ? (b.phone || "") : "", grupId: gr.grup || "" })], dry);
    }
    refs.push(`${g.key}:${ref}`);
  }
  return refs.join(";");
}
async function cancel(b, dry) {
  const acc = await account(b.company_id);
  if (!acc || !acc.ws_user || !acc.ws_pass) throw new Error("U-ETDS hesabı eksik");
  for (const part of String(b.uetds_ref || "").split(";").filter(Boolean)) {
    const ref = part.split(":")[1];
    await call(acc, "seferIptal", [`<uetdsSeferReferansNo>${x(ref)}</uetdsSeferReferansNo>`, `<iptalAciklama>Rezervasyon iptal edildi</iptalAciklama>`], dry);
  }
}

/* ---------------- Döngü ---------------- */
async function tick() {
  await rpc("uetds_unstick").catch(() => {});
  const jobs = await rpc("uetds_claim", { n: 10 });
  for (const b of jobs || []) {
    const cancelling = b.uetds_status === "cancelling";
    try {
      if (cancelling) { await cancel(b); await patchBooking(b.id, { uetds_status: "cancelled", uetds_msg: null, uetds_at: new Date().toISOString() }); }
      else { const ref = await send(b); await patchBooking(b.id, { uetds_status: "sent", uetds_ref: ref, uetds_msg: null, uetds_at: new Date().toISOString() }); }
      console.log(new Date().toISOString(), cancelling ? "iptal" : "gönderildi", b.id);
    } catch (e) {
      const msg = String(e.message || e).slice(0, 500);
      await patchBooking(b.id, { uetds_status: cancelling ? "sent" : "error", uetds_msg: msg, uetds_at: new Date().toISOString() }).catch(() => {});
      console.error(new Date().toISOString(), "HATA", b.id, msg);
    }
  }
}

const arg = process.argv[2];
if (arg === "--wsdl") {
  const r = await fetch(ENDPOINT.test + "?wsdl"); const t = await r.text();
  const ops = [...new Set([...t.matchAll(/<(?:\w+:)?operation name="([^"]+)"/g)].map(m => m[1]))];
  console.log("Metotlar:", ops.join(", "));
  for (const typ of ["ariziSeferBilgileriInput", "ariziGrupBilgileriInput", "ariziSeferPersonelBilgileriInput", "ariziSeferYolcuBilgileriInput"]) {
    const m = t.match(new RegExp(`name="${typ}"[\\s\\S]*?</(?:\\w+:)?complexType>`));
    console.log(typ + ":", m ? [...m[0].matchAll(/element name="([^"]+)"/g)].map(z => z[1]).join(", ") : "BULUNAMADI (alan adlarını kontrol edin)");
  }
  if (!/schemaLocation|import/.test(t)) {} else console.log("Not: tipler ayrı XSD'de olabilir; WSDL'deki import adresine bakın.");
} else if (arg === "--dry") {
  const r = await rest(`bookings?id=eq.${process.argv[3]}&select=*`);
  if (!r || !r[0]) console.log("Rezervasyon bulunamadı"); else console.log("\nreferanslar:", await send(r[0], true));
} else {
  console.log("U-ETDS gönderici çalışıyor. Aralık:", POLL_MS / 1000, "sn");
  for (;;) { try { await tick(); } catch (e) { console.error("tick", e.message); } await new Promise(r => setTimeout(r, POLL_MS)); }
}
