# U-ETDS gönderici

Firmaların onayladığı transferleri Ulaştırma Bakanlığı U-ETDS (tarifesiz/arızi yolcu) web servisine bildiren küçük program.
U-ETDS, bağlantıyı yalnızca firmanın e-Devlet'te tanımladığı IP adresinden kabul eder. Bu yüzden program **sabit IP'li bir sunucuda** çalışır.

## Nasıl çalışır
1. Firma Ayarlar → U-ETDS bölümünü açar, web servis kullanıcı adı ve şifresini girer.
2. Rezervasyon onaylanınca veritabanı onu sıraya alır (`uetds_status = queued`).
3. Bu program 20 saniyede bir sırayı alır, her bacak (geliş, varsa dönüş) için
   `seferEkle → seferGrupEkle → personelEkle (şoför) → yolcuEkle (her yolcu)` çağırır.
4. Sonuç rezervasyona yazılır: **Bildirildi** (referans no ile) ya da **Hata** (sebebiyle). Uygulamada anında görünür.
5. Rezervasyon iptal edilir ya da silinirse sefer `seferIptal` ile iptal edilir.

## Sunucu kurulumu (bir kez)
1. Sabit IP'li küçük bir Linux sunucu kiralayın (1 CPU / 1 GB yeterli). Node.js 18 veya üstünü kurun.
2. Bu klasörü sunucuya kopyalayın.
3. Supabase → Project Settings → API'den **service_role** anahtarını alın. Bu anahtar yalnızca bu sunucuda,
   ortam değişkeninde durur; koda, GitHub'a ya da sohbete yazılmaz.
4. Çalıştırın (örnek systemd servisi aşağıda):
   ```
   SUPABASE_URL=https://ppqfcasjawbbfohjnvjr.supabase.co SUPABASE_SERVICE_KEY=... node worker.mjs
   ```
5. Sunucunun IP adresini uygulamadaki `UETDS_IP` sabitine yazın. Firmalar bu adresi
   e-Devlet → "Uetds IP Tanımlama İşlemleri" hizmetinden tanımlar.

## İlk deneme (zorunlu)
- `node worker.mjs --wsdl` → U-ETDS servisindeki metot ve alan adlarını listeler.
  Bu programdaki alan adları kamuya açık dokümana göre yazıldı; **canlıya geçmeden önce WSDL ile karşılaştırın**, fark varsa düzeltin.
- `node worker.mjs --dry <rezervasyon-id>` → gidecek XML'i gösterir, göndermez.
- Firma ayarında **Deneme modu** açıkken Bakanlığın test sistemine gönderilir. Sorunsuz çalışınca deneme modu kapatılır.

## Bilinen açık noktalar
- İlçe kodları: kalkış/varış ilçe kodu şimdilik firma ayarındaki tek değerden alınıyor. Otel ilçesine göre kod eşlemesi,
  test ortamında U-ETDS'nin kod listesi görüldükten sonra eklenecek.
- Sefer bitiş saati, kalkıştan `LEG_HOURS` (varsayılan 2) saat sonra kabul edilir.

## systemd örneği
```
[Unit]
Description=Transfer Defteri U-ETDS
After=network-online.target
[Service]
WorkingDirectory=/opt/uetds-worker
Environment=SUPABASE_URL=https://ppqfcasjawbbfohjnvjr.supabase.co
EnvironmentFile=/etc/uetds-worker.env
ExecStart=/usr/bin/node worker.mjs
Restart=always
[Install]
WantedBy=multi-user.target
```
`/etc/uetds-worker.env` içine yalnızca `SUPABASE_SERVICE_KEY=...` yazılır (izin: 600).
