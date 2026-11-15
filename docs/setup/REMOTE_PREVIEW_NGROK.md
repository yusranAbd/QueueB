# Remote Preview V1 — ngrok

Mode opsional untuk demo dengan **data fiktif**. Browser laptop, tablet, dan
smartphone memakai satu URL HTTPS. Android native tetap menggunakan konfigurasi
development sebelumnya; tidak ada perubahan UI, database, Queue Engine, RBAC,
Firewall, Wi-Fi, atau router.

Alur: browser → HTTPS ngrok dengan Google OAuth/email allowlist → proxy
`127.0.0.1:8085` → Flutter Web `127.0.0.1:5173` atau NestJS `127.0.0.1:3000`.
`/api/v1` dan `/socket.io` menuju API; path lainnya menuju Flutter. Deep link,
aset, multipart, cookie, Authorization, streaming, dan upgrade Socket.IO tetap
melewati kontrak existing. Proxy tidak membuka folder lokal.

## 1. Instal dan hubungkan ngrok

Gunakan [installer Windows resmi](https://ngrok.com/download/windows), atau:

```powershell
winget install ngrok -s msstore
ngrok version
```

Pada pemeriksaan 5 November 2026, ngrok `3.39.11` sudah terpasang di komputer
proyek. Tidak perlu menginstal ulang jika command versi berhasil.

Ambil authtoken dari dashboard akun ngrok dan masukkan **langsung pada terminal
lokal**. Jangan kirim token ke chat atau menyimpannya di repository:

```powershell
ngrok config add-authtoken "<AUTHTOKEN_ANDA>"
ngrok config check
```

Gunakan domain dev yang terdaftar pada akun tersebut. Domain diberikan sebagai
parameter, bukan ditanam dalam source. Dukungan OAuth/Traffic Policy dan batas
penggunaan mengikuti paket akun. Jika ngrok menolak policy, startup berhenti;
tidak ada fallback ke tunnel terbuka. Lihat [CLI ngrok](https://ngrok.com/docs/gateway/agent/cli)
dan [OAuth dengan pembatasan email](https://ngrok.com/docs/gateway/traffic-policy/actions/oauth#restricting-access-by-email).

## 2. Jalankan API existing untuk preview

Hentikan hanya API yang Anda jalankan melalui terminal pemiliknya sebelum
memulai API pada port yang sama. Script preview tidak membuat API kedua.

Pada terminal baru khusus preview, set domain yang sama dengan startup:

```powershell
cd C:\Workspaces\QueueB\apps\api
$queuebPreviewUrl = 'https://DOMAIN_NGROK_ANDA'
# Pertahankan juga origin lain yang sebelumnya sudah disetujui jika ada.
$env:CORS_ALLOWED_ORIGINS = "http://localhost:3000,http://localhost:5173,http://127.0.0.1:5173,http://127.0.0.1:8085,$queuebPreviewUrl"
npm run start:dev
```

Variabel ini berlaku hanya pada terminal/proses tersebut. `.env` dan rahasia
database tidak ditulis ulang. Tutup terminal khusus ini setelah demo untuk
kembali ke environment terminal normal. Port API tetap 3000.

REST membaca konfigurasi tervalidasi; guard namespace Socket.IO/display membaca
process environment. Karena itu origin harus ada **sebelum** `npm run start:dev`.
Mengubah environment setelah API berjalan tidak memperbarui proses yang sudah
hidup. Origin tidak diubah/disamarkan oleh proxy dan tidak memakai wildcard.

## 3. Aktifkan Remote Preview

Hentikan Flutter normal pada port 5173 melalui terminal pemiliknya. Server normal
dengan API absolut tidak boleh dipakai sebagai preview. Startup menjalankan
Flutter preview baru dalam grup proses miliknya, dengan argumen:

```powershell
# Informasi argumen Flutter yang dipakai startup; jangan menjalankan keduanya.
flutter run -d web-server --profile --web-hostname=127.0.0.1 --web-port=5173 `
  --dart-define=QUEUEB_REMOTE_PREVIEW=true --dart-define=API_BASE_URL=/api/v1
```

Startup memakai file defines unik berisi nilai yang sama dan zona waktu backend,
serta target `apps/client/lib/main.dart` absolut. Jangan menjalankan command
Flutter manual di atas bersamaan dengan startup. Jika Web normal perlu tetap
berjalan, pilih port preview lain, misalnya `-WebPort 5174`; perhatikan build
output Flutter tetap berasal dari checkout yang sama. Untuk demo paling sederhana,
gunakan satu mode Web pada satu waktu.

Dari root repository, periksa prasyarat tanpa memulai service:

```powershell
cd C:\Workspaces\QueueB
.\tools\dev\start-ngrok-preview.ps1 `
  -PublicUrl 'https://DOMAIN_NGROK_ANDA' `
  -AllowedEmail 'email-google-yang-diizinkan@example.com' -CheckOnly
```

Setelah memastikan backend hanya berisi data demo, jalankan:

```powershell
.\tools\dev\start-ngrok-preview.ps1 `
  -PublicUrl 'https://DOMAIN_NGROK_ANDA' `
  -AllowedEmail 'email-google-yang-diizinkan@example.com' -DemoDataOnly
```

Beberapa email dapat diberikan sebagai array PowerShell. `-PublicUrl` harus satu
origin HTTPS tanpa path/query; `-DemoDataOnly` merupakan pernyataan operator,
bukan pemeriksaan isi database. Script tidak membaca tabel pasien untuk menilai
data fiktif. Tidak ada kebutuhan mengganti IP ketika berpindah Wi-Fi.

Parameter opsional: `-Flutter`, `-Ngrok`, `-NgrokConfig`, `-ApiPort`, `-WebPort`,
`-ProxyPort` (default 8085), `-NgrokApiPort` (default 4045), dan
`-ReadyTimeoutSeconds` (default 600; maksimum 900). Port harus berbeda.
Port lama 8080 tidak digunakan. Authtoken juga dapat berasal dari environment
`NGROK_AUTHTOKEN`; script tidak menampilkannya. Untuk default nonrahasia,
`QUEUEB_PREVIEW_URL` dan `QUEUEB_PREVIEW_EMAILS` (dipisah koma) didukung.

## 4. Pemeriksaan sebelum tunnel tersedia

Startup memeriksa versi/config/token ngrok tanpa mencetak nilainya, health API,
respons 401 tanpa login, CORS persis, dan penolakan namespace Socket.IO yang benar.
Token readiness sengaja tidak valid; tidak ada login atau transaksi pasien.

Seluruh proses preview dibuat suspended, dimasukkan ke Windows Job Object,
lalu dijalankan. Keluarnya launcher saja tidak dianggap kegagalan selama proses
turunan dalam grup masih aktif. Kesiapan Web memerlukan bootstrap Flutter serta
hash HTTP `main.dart.js` yang sama dengan build lokal stabil. PID listener yang
terlihat harus menjadi anggota grup Web. Port yang terpakai tidak diambil alih.

Setelah proxy siap, Web/REST/Socket.IO diperiksa melalui proxy. ngrok baru
dijalankan dengan policy Google OAuth tanpa pengecualian path, lalu rule deny
untuk email di luar allowlist. Basic Auth tidak digunakan agar header Bearer
Authorization aplikasi tetap utuh. Policy selalu diteruskan saat pembuatan
endpoint; tidak ada tahap membuka tunnel tanpa policy.

Konfigurasi ngrok asli tidak diubah. Overlay sementara menempatkan agent API pada
`127.0.0.1:4045`, menonaktifkan inspector/log ngrok serta remote management, dan
mempertahankan validasi TLS. URL HTTPS/upstream/nama endpoint diverifikasi lewat
agent API lokal. Request publik tanpa sesi harus mengarah ke OAuth yang dikenali;
jika tidak, grup ngrok ditutup. Pesan URL siap ditampilkan setelah tahap itu.

Detail run, policy, defines, dan log Flutter/proxy berada di `.cache/ngrok-preview/`
yang sudah diabaikan Git. Script tidak mencetak body API, password, token,
query pasien, atau authtoken. Proxy tidak mencatat request/response aplikasi.
Stdout/stderr agent ngrok dibuang ke NUL agar diagnostik terkait kredensial
tidak tersimpan pada log workflow.
Marker proses membutuhkan Host lokal dan nonce sesi; marker serta health API
tidak tersedia melalui Host publik. Socket.IO tetap memerlukan JWT/cookie dan
izin aplikasi setelah OAuth edge berhasil.

## 5. Buka dari tablet/HP

Buka URL **HTTPS yang benar-benar dicetak startup** pada browser perangkat.
Login dengan akun Google dalam allowlist, kemudian login ke QueueB
seperti biasa. Endpoint REST menjadi `https://DOMAIN/api/v1`; transport Socket.IO
menjadi WSS pada `https://DOMAIN/socket.io/`. AppConfig memakai origin halaman
hanya saat kedua flag preview aktif. Tidak ada request API yang diarahkan ke
localhost perangkat berdasarkan konfigurasi preview tersebut.

Peringatan browser ngrok bukan kontrol akses; akses tetap memerlukan OAuth dan
allowlist. Jangan membagikan akun Google/JWT, memasukkan data pasien nyata, atau
membuka inspector/debugger ke publik. Laptop harus tetap hidup dan tersambung
internet. HTTPS berakhir di ngrok, sehingga ini layanan pihak ketiga untuk demo,
bukan deployment production atau jaminan privasi data klinis.

Login Google, izin email yang benar/salah, lima portal, cookie display, dan
realtime perlu dicoba langsung pada perangkat. Probe transport yang berhasil
bukan bukti seluruh alur bisnis atau tablet sudah berhasil.
Pembatasan request/handshake backend tetap aktif. Karena proxy memakai koneksi
loopback, beberapa browser dapat berbagi kuota IP yang sama; jangan menonaktifkan
guard atau mempercayai header IP publik secara sembarang untuk mengatasinya.

## 6. Hentikan dan kembali ke mode normal

Tekan **Ctrl+C** pada terminal startup, atau dari terminal lain pada root proyek:

```powershell
.\tools\dev\start-ngrok-preview.ps1 -Stop
```

Perintah kedua hanya menulis permintaan stop pada direktori sesi yang tervalidasi.
Pemilik sesi menutup Job Object miliknya sehingga hanya Flutter preview, proxy,
dan ngrok yang diluncurkan sesi itu dihentikan. NestJS/database serta proses
pengguna di luar grup tetap berjalan. PID yang dipakai ulang tidak ditargetkan.
Menutup proses supervisor juga menutup handle job dan proses preview miliknya.

Mode normal tidak memerlukan flag preview, proxy, atau ngrok:

```powershell
# Terminal backend normal, tanpa environment tambahan preview:
cd C:\Workspaces\QueueB\apps\api
npm run start:dev

# Terminal Flutter normal:
cd C:\Workspaces\QueueB\apps\client
flutter run -d chrome --profile --web-port=5173 `
  --dart-define=API_BASE_URL=http://localhost:3000/api/v1
```

## 7. Batas verifikasi — 5 November 2026

- Parse PowerShell, kompilasi helper Job Object, dan sintaks dua modul Node lolos.
- Fixture supervisor `cmd /c exit 0` serta parser argumen Windows lolos.
  Isolasi dua job juga lolos: menutup satu job menghentikan proses fixture-nya
  tanpa menghentikan proses fixture dalam job lain; seluruh fixture dibersihkan.
  `ngrok version` melalui job dan output NUL juga berhasil dengan exit code 0.
- Tiga belas kelompok smoke fixture loopback proxy lolos: aset/deep link,
  metode/path/query/body JSON/multipart, header autentikasi/cookie, streaming,
  status upstream, guard Host/path/nonce, Socket.IO duplex, serta 502/504.
- Dua probe tanpa kredensial ke API existing lolos: origin localhost ditolak
  sebagai `UNAUTHORIZED`, sedangkan origin tidak diizinkan ditolak sebagai
  `ORIGIN_NOT_ALLOWED`. Tidak ada login, room join, atau mutasi data.
- Overlay ngrok v2/v3 lolos `ngrok config check` pada agent 3.39.11, tanpa
  authtoken fixture atau koneksi tunnel.
- Preflight aktual berhenti sebelum menjalankan Flutter/proxy/ngrok karena
  konfigurasi ngrok default belum tersedia. Tunnel publik **belum diaktifkan**;
  dukungan policy akun, redirect OAuth aktual, kompilasi Web preview, login
  perangkat dan akses tablet belum diverifikasi.

Tidak menjalankan seluruh test suite, APK build, E2E, perubahan database,
commit, atau push dalam pekerjaan ini.
