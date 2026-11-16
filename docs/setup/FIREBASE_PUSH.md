# Push Notification Firebase (FCM) — Panduan Konfigurasi

Ditulis 16 November 2026. Push FCM mengirim salinan notifikasi pasien ke aplikasi **Android** saat aplikasi di latar belakang atau tertutup. Inbox dalam aplikasi tetap menjadi sumber kebenaran. Kontrak API ada di `docs/backend/API_INTEGRATION_GUIDE.md` bagian "Push FCM pasien Android".

Tanpa langkah di bawah, semuanya tetap berjalan: backend mencatat `Push FCM nonaktif`, build Android tidak memasang plugin google-services, dan aplikasi berjalan tanpa push.

## 1. Membuat proyek Firebase

1. Buka [Firebase Console](https://console.firebase.google.com/) → **Add project** → beri nama, misalnya `QueueB`. Google Analytics tidak diperlukan.
2. Di halaman proyek, pilih **Add app → Android**.
   - **Android package name:** `id.queueb.queueb_client` (harus sama persis dengan `applicationId` di `apps/client/android/app/build.gradle.kts`).
   - Nickname bebas. SHA-1 tidak diperlukan untuk FCM.
3. Unduh **`google-services.json`** dan simpan di:

   ```
   apps/client/android/app/google-services.json
   ```

   File ini di-ignore Git. Jangan commit dan jangan kirim lewat chat.
4. Lewati langkah "Add Firebase SDK" di console karena konfigurasi Gradle sudah ada di repo.

## 2. Kunci service account untuk backend

1. Firebase Console → ⚙️ **Project settings → Service accounts → Generate new private key**.
2. Simpan file JSON di **luar repository**, misalnya `C:\Users\<nama>\QueueB-private\firebase-admin.json`.
   File ini memberi akses kirim ke seluruh proyek Firebase. Perlakukan seperti kata sandi.
3. Tambahkan ke `.env` di root repo (file yang dibaca `apps/api`):

   ```
   FIREBASE_SERVICE_ACCOUNT_PATH=C:\Users\<nama>\QueueB-private\firebase-admin.json
   ```

4. Restart API. Log yang benar: `Push FCM aktif untuk proyek <project-id>`. Kalau path diisi tetapi file tidak ada, API menolak start dengan pesan `FIREBASE_SERVICE_ACCOUNT_PATH menunjuk file yang tidak ditemukan`. Kalau isi file rusak, API tetap start dan push nonaktif.

## 3. Database

Migration `20261116_push_notifikasi_fcm` menambah tabel `perangkat_push` dan kolom `notifikasi.push_diproses_pada`. Terapkan dengan prosedur biasa (backup lalu `npx prisma migrate deploy` dari `apps/api`).

## 4. Build dan uji di perangkat

1. `flutter build apk` atau `flutter run` dari `apps/client` setelah `google-services.json` terpasang. Gradle menerapkan plugin google-services hanya jika file itu ada.
2. Login sebagai **pasien** di HP. Pada Android 13 ke atas muncul permintaan izin notifikasi; pilih **Izinkan**.
3. Tutup atau minimize aplikasi. Dari portal Web, petugas memanggil nomor pasien itu.
4. Dalam beberapa detik muncul push "Nomor Anda dipanggil". Ketuk untuk membuka inbox notifikasi.
5. Logout di HP, lalu panggil lagi. Push tidak boleh muncul karena token dihapus dan sesinya dicabut.

## 5. Batasan

- Hanya Android. Web dan iOS tidak menerima push.
- Pengiriman paling banyak sekali (*best effort*). Push yang gagal tidak diulang, dan notifikasi berumur lebih dari 10 menit tidak dipush.
- Isi push (nomor, layanan, ruang) melewati server Google dan tampil di layar kunci. Tidak ada nama pasien.
- Ikon notifikasi memakai ikon launcher. Ikon monokrom khusus status bar belum dibuat.
- Klien memakai registration token FCM (`getToken`/`onTokenRefresh`), yang ditandai deprecated di firebase_messaging 17 dan digantikan Firebase Installation ID (`register`/`onRegistered`, `fids` di firebase-admin). Migrasi ke FID harus dilakukan di klien dan server sekaligus, setelah diuji di perangkat.
