# Transfer Defteri — Proje Durumu (31 Ekim 2026)

Bu dosya yeni bir Claude sohbetinde kaldığımız yerden devam etmek için özet.

## Ne yapıldı
- **Uygulama (operatör):** `index.html` — rezervasyon listesi (tarihe göre), form, otel/havalimanı/ilçe otomatik tamamlama, fotoğraf, hatırlatma, ödeme durumu, müşteri linki paneli, Ayarlar (firma adı, WhatsApp, plaka, link kısa adı), ilk girişte şifre değiştirme, süresi dolan firma duvarı, **Yönetim paneli** (sadece platform yöneticisi).
- **Müşteri formu:** `r/index.html` — TR/EN/RU/DE, `r/?c=<slug>`; kısa yol `/<slug>` (`404.html` yönlendirir). Fiyat gösterilmez.
- **Yer listesi:** `places-data.js` (21 havalimanı, 134 ilçe/köy, ~370 otel).
- **Veritabanı:** Supabase projesi `transfer-defteri` (ref `ppqfcasjawbbfohjnvjr`, Zürih). Şema: `supabase/001_schema.sql`, `supabase/002_admin.sql` (uygulanmış durumda). Tablolar: companies, members, bookings, places, settings, payments, platform_admins, platform_settings, app_assets (kullanılmıyor). RLS açık; müşteri formu `submit_booking` RPC ile yazar.
- **Giriş:** kullanıcı adı + şifre (e-posta `kullaniciadi@firma.transferdefteri.net` olarak saklanır) veya e-posta. "Confirm email" KAPALI (ücretsiz plan e-posta sınırı). Platform yöneticisi: kenzcn0@gmail.com.
- **Abonelik modeli:** 30 gün deneme, aylık 250 TL, yıllık 3000 TL (platform_settings'ten değişir). Ödeme kaydı yönetici panelinden elle; IBAN ve destek WhatsApp panelden girilir.
- **Yayın:** GitHub Pages, repo `ismetcnyldz/transfer-defteri`, branch main. Özel alan adı **transferdefteri.net** (Natro, müşteri no 910554; DNS: 4 A kaydı GitHub IP'leri + www CNAME). HTTPS DNS yayılınca GitHub Pages ayarından "Enforce HTTPS" işaretlenecek.
- Eski adres: https://ismetcnyldz.github.io/transfer-defteri/ (CNAME eklendiği için artık transferdefteri.net'e yönlenir).

## Adresler
- Uygulama / giriş: https://transferdefteri.net
- Müşteri formu (kurucu firma): https://transferdefteri.net/vip
- Firma kayıt (kendi kendine): https://transferdefteri.net/#kayit (yönetici genelde panelden açar)

## Kalanlar / sıradaki işler
1. HTTPS kontrolü ve "Enforce HTTPS".
2. Yönetim paneli ilk kullanım: Platform ayarları (WhatsApp, IBAN, uygulama adresi = https://transferdefteri.net), ilk firmalar.
3. Tasarım: daha renkli/kurumsal görünüm, logo, WhatsApp link önizlemesi (og:image), plaka rozeti büyütme.
4. Ekran görüntüsünden otomatik doldurma (AI ile WhatsApp mesajı okuma).
5. Raporlar (ciro/kâr), şoför/araç listesi, gerçek push bildirimi.
6. Mağaza (Google Play / App Store) sürümü — kış.

## Notlar
- Supabase ücretsiz plan: 1 hafta erişilmezse proje uyur (panelden uyandırılır).
- Natro .net yenileme ~26,49 $/yıl; DNS servisi 0,10 $/ay.
- Kod güncellemeleri: Claude GitHub'a push eder, Pages 1–2 dk içinde yayınlar.
