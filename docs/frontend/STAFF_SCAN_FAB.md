# PETUGAS — tombol pindai QR mengambang

Revisi 28 Oktober 2026 menghapus panel QR Check-in Otomatis di bawah dashboard beserta input payload manual. Akses kamera memakai `Scaffold.floatingActionButton` dan `FloatingActionButton.extended` berlabel **Pindai QR**, di kanan bawah. Dialog kamera, validasi QR, deduplikasi frame dan POST `/check-in/auto-antrean` tetap existing. Keberhasilan hanya ditampilkan setelah server mengembalikan MENUNGGU; snapshot dimuat ulang setelah tindakan.

Tombol tidak muncul tanpa penugasan aktif, dan tidak bisa ditekan saat memuat/memproses atau saat snapshot belum tersedia/akses ditolak. Daftar mempunyai padding bawah 88 logical px agar bagian terakhir dapat digulir melewati tombol; ruang yang tadinya dipakai panel QR dialokasikan kembali ke daftar dan pelayanan. Hasil scan tetap terlihat dalam dialog. Penolakan kamera memberikan petunjuk izin kamera dan membuka ulang pemindai, tanpa mengarahkan pengguna ke input manual yang sudah dihapus.

Tidak ada perubahan API, autentikasi, RBAC, Queue Engine, database, migration, atau portal role lain.

## Validasi

- Dart format dan Flutter analyze: PASS, 0 issue.
- Regresi PETUGAS/scanner/UI: 67 PASS.
- Seluruh Flutter test: 516 PASS, 1 tes live opsional SKIP tanpa fixture live.
- Widget responsive: 1280×640, 1280×720, 1366×768, 1440×900, 1920×1080, 768×1024, 320×740, 375×812, 414×896; tanpa RenderFlex overflow.
- Regresi mencakup FAB membuka/menutup/membuka ulang pemindai, input manual tidak dirender, QR tidak valid tidak mengirim request, callback scan mengirim satu operasi check-in+enqueue dan memperbarui snapshot, deduplikasi frame, kegagalan/offline, serta CALL/RECALL/SKIP/REQUEUE/START/COMPLETE, pagination dan pergantian ruang.

Unit integrasi callback bukan bukti kamera fisik. Kamera Android/perangkat fisik tidak diuji pada pekerjaan ini.

- Flutter Web release: PASS, JavaScript; peringatan WASM dry-run dari dependency existing tetap di luar perubahan ini.
- Chrome release nyata: PASS di sembilan viewport di atas; 0 page error. Video kamera virtual berisi QR sintetis dibaca decoder mobile_scanner asli; satu POST check-in+enqueue, frame berulang tidak mengirim ulang. CALL/RECALL/START/COMPLETE, SKIP/REQUEUE, pencarian, isolasi ruang, reconnect/REST refresh dan profil/logout juga PASS.
- Data HTTP/Socket.IO dan video QR adalah fixture sintetis. Tidak ada data development yang ditulis. QA memuat aset decoder pinned 3.1.3 identik melalui cdn.jsdelivr.net karena host Fastly default paket tidak terjangkau di lingkungan QA; source/runtime scanner aplikasi tidak diganti. Instalasi tetap membutuhkan izin kamera dan akses aset decoder existing.

[Screenshot desktop](images/staff-scan-fab/staff-1366x768.png) · [Laptop 1280×720](images/staff-scan-fab/staff-1280x720.png) · [Mobile](images/staff-scan-fab/staff-375x812.png) · [Scan berhasil](images/staff-scan-fab/scan-dialog.png) · [Laporan Chrome](images/staff-scan-fab/report.json).

Runner: `apps/client/tool/browser-staff-v4.cjs` dengan `compact: true` dan opsi `cameraVideo` menunjuk video Y4M QR sintetis `SQ1.` diikuti 43 karakter A, sesuai fixture runner. Tanpa video, runner memeriksa petunjuk kamera tidak tersedia. Jangan memakai token atau QR pengguna nyata sebagai fixture.

## Check-in tanpa QR (pasien tanpa HP)

Di samping **Pindai QR** ada tombol **Tanpa QR** (`staff-manual-button`) yang membuka dialog pencarian. Petugas mengetik nomor antrean (mis. `A-025`), melihat nomor, status, layanan dan nama pasien yang disamarkan, mencocokkan nama dengan pasien di depannya, lalu menekan **Check-in & masuk antrean**. Backend: `POST /check-in/cari-nomor` (read-only) dan `POST /check-in/manual`; hasil dianggap berhasil hanya bila server mengembalikan `MENUNGGU` untuk tiket yang sama. Snapshot dimuat ulang setelah berhasil, dan realtime `ENQUEUE` tetap dikirim.

Tombol mengikuti kondisi tombol Pindai QR (nonaktif saat memuat/memproses atau snapshot belum tersedia). Pada lebar di bawah 520 px kedua tombol berbagi satu baris di bawah kolom pencarian. Tiket yang sudah check-in, berstatus akhir, bukan hari pelayanan, atau di luar jam pelayanan ditampilkan dengan alasan dan tanpa tombol check-in. Kamera tidak diperlukan; input QR manual (payload teks) tetap tidak ada.

Dialog tidak mengubah bloc: ia memanggil repository dan memicu refresh. Tes: `apps/client/test/staff_manual_check_in_test.dart` (format salah tidak mengirim request, cari lalu check-in, tiket tidak boleh check-in, error server). Tidak ada perubahan skema database atau migration. Belum diuji di perangkat fisik atau dengan database nyata.
