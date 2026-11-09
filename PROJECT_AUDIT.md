# PROJECT AUDIT — QueueB

**Tanggal audit:** 2026-11-09 · **Branch:** `main` @ `9dda7b9` · **Cakupan:** `apps/api` (NestJS + Prisma + PostgreSQL), `apps/client` (Flutter Android/Web), CI, dokumentasi, tooling.

**Metode:** pembacaan kode aktual dan pemeriksaan non-destruktif (typecheck, lint, unit test, `flutter analyze`, `flutter test`, `dart format --output=none`, `npm audit`, riwayat CI GitHub). Tidak ada file proyek yang diubah selain pembuatan laporan ini. Database tidak disentuh: tes e2e (yang menulis ke PostgreSQL) **tidak dijalankan**.

> Catatan penting: working tree berisi **54 file termodifikasi + 20-an path untracked yang belum di-commit** (±3.760 baris tambah / 1.945 hapus). Sebagian temuan di bawah berasal dari perubahan lokal tersebut dan ditandai **[LOKAL]**. Temuan tanpa tanda berlaku pada kode yang sudah di-commit.

---

## 1. Ringkasan Eksekutif

| Area | Kondisi | Catatan utama |
|---|---|---|
| Arsitektur backend | **Baik** | Modular per domain, Queue Engine transaksional (Serializable + retry, advisory lock, CAS `versi`), realtime pasca-commit, audit sesi terpseudonimisasi. |
| Keamanan & sesi | **Baik, ada celah** | JWT + sesi DB + rotasi refresh CAS, RBAC per endpoint, origin check socket, cookie display httpOnly. Celah: tanpa `trust proxy`, tanpa security headers, kebijakan reset sandi lemah, dependensi rentan. |
| Arsitektur Flutter | **Campuran / technical debt tinggi** | Lapisan `features/*` (BLoC/Cubit + repository) hidup berdampingan dengan file datar raksasa & berversi (`patient.dart` 4.264 baris, `patient_home_v6/v7/v8`, `staff_v4`). |
| Status build/test | **Merah** | CI `main` gagal (Flutter analyze) di 4 dari 5 run terakhir. Lokal: 7 unit test API gagal, e2e `queue-broadcast` tidak lolos typecheck, `flutter analyze` 4 issue, 3 file belum terformat, `flutter test` banyak kegagalan (lihat §6). |
| Perubahan lokal belum commit | **Risiko tinggi** | Termasuk fitur backend baru (auto-expire tiket, reset sandi admin, nama pasien di portal dokter) yang belum dites ulang; satu di antaranya **pasti gagal di runtime** (P0-1). |

**Lima prioritas teratas**

1. **P0-1 [LOKAL]** Endpoint reset kata sandi staf selalu gagal: insert `audit_sesi` melanggar CHECK constraint database.
2. **P0-2** Pipeline merah: CI `main` gagal; unit test API & Flutter gagal pada working tree; e2e tidak dijalankan di CI.
3. **P0-3 [LOKAL]** `GET /tiket/saya` & `GET /reservasi*` kini menjalankan transaksi tulis (auto-expire) pada setiap baca/polling.
4. **P1** Tanpa `trust proxy` → rate limit login/pairing berbagi satu IP di balik ngrok/reverse proxy; tanpa helmet/security headers; 5 high vuln `npm audit`.
5. **P1** Technical debt Flutter (file raksasa & berversi) dan `queue.service.ts` 2.349 baris dengan 7 salinan pola retry.

---

## 2. Kondisi Project Saat Ini

### 2.1 Struktur repository

```text
apps/api      NestJS 12, Prisma 7.10 (adapter-pg), Socket.IO 4, 21 modul domain, 11 migrasi
apps/client   Flutter (Dart ^3.13), go_router, flutter_bloc, socket_io_client, secure storage
apps/web      KOSONG (src/, public/, tests/ kosong; hanya dist/ & node_modules/ hasil build lama) — untracked
docs/         Banyak dokumen fase (backend/, frontend/, setup/…); docs/api, docs/database, docs/dfd kosong
infra/docker  KOSONG; compose.yml di root hanya PostgreSQL 18
tools/dev, sql/, backups/, artifacts/ (74 MB) — semuanya untracked dan TIDAK di-.gitignore
```

### 2.2 Backend (apps/api)

- **Bootstrap**: `src/main.ts`, `src/configure-app.ts` — prefix `api/v1`, `ValidationPipe({whitelist, forbidNonWhitelisted, transform})`, CORS dari `CORS_ALLOWED_ORIGINS`.
- **Validasi env**: `src/config/env.validation.ts` — panjang secret ≥16, access≠refresh, origin tervalidasi, timezone IANA. Baik.
- **Domain**: `auth` (+profile, audit), `akun-petugas`, `dokter`, `layanan`, `loket`, `jadwal-layanan`, `jadwal-praktik`, `slot-praktik`, `penugasan-petugas`, `reservasi`, `janji-temu`, `tiket`, `qr`, `check-in`, `queue`, `realtime`, `display`, `notifikasi`, `laporan`, `admin-delete`, `portal-dokter`, `health`.
- **Queue Engine** (`src/queue/queue.service.ts`): setiap transisi (ENQUEUE, CALL, RECALL, SKIP, REQUEUE, START, COMPLETE) dalam transaksi Serializable dengan retry P2034, state machine terpisah (`queue-state-machine.ts`), event `peristiwa_antrean`, broadcast setelah commit.
- **Konsistensi data**: unique constraint nomor & urutan FIFO per layanan/tanggal, advisory lock untuk slot janji temu (`janji-temu.service.ts:294-301`), trigger notifikasi di DB (`migrations/20261102_.../migration.sql:30-75`).
- **Realtime**: 4 namespace (`/queue`, `/display`, `/patient`, `/doctor`), autentikasi JWT/token perangkat di handshake, room diotorisasi server-side, revalidasi akses per broadcast.

### 2.3 Frontend (apps/client)

- 73.678 baris Dart (lib + test). Lapisan baru `lib/src/features/{admin,patient,staff,doctor,display,account}` memakai Cubit/BLoC + repository; lapisan lama di `lib/src/*.dart` memakai StatefulWidget + `QueueApi` (ChangeNotifier).
- Routing `go_router` dengan `RoutePolicy` (`lib/src/routing/route_policy.dart`) — validasi path/query ketat, open-redirect dicegah, home per peran.
- Sesi: `QueueApi` (`lib/src/api.dart`) dengan retry tunggal pada 401, generation counter anti-race; token disimpan di `FlutterSecureStorage` (Android) dan **hanya di memori** di Web (`session_store.dart:20`).
- Realtime pasien: socket + fallback polling 30 dtk + rekonsiliasi 2 menit (`patient_sync.dart:44-70`); staff & display polling 15 dtk sebagai cadangan.

### 2.4 Database

Skema `apps/api/prisma/schema.prisma` (430 baris, 17 model). Kekuatan: `timestamptz` konsisten, indeks FIFO komposit, `versi` untuk optimistic concurrency, pseudonymous `auditRef`. Catatan: 4 dari 11 folder migrasi tidak memakai format timestamp lengkap (`20261013_hospital_h1_fondasi`, dst.) — urutan leksikal masih benar, tetapi rawan bila ada migrasi baru bertanggal sama.

---

## 3. Temuan Berdasarkan Prioritas Risiko

Legenda: **P0** = perbaiki sebelum pengembangan/demo berikutnya · **P1** = sprint berikutnya · **P2** = perbaikan berkelanjutan.

### P0 — Kritis

#### P0-1 [LOKAL] Reset kata sandi staf oleh ADMIN selalu gagal (HTTP 500)

> **Status 2026-11-09: DIPERBAIKI (belum commit).** Audit kini memakai konvensi pencabutan sesi yang sudah ada (`aksi=CABUT_SESI`, `alasan=PASSWORD_CHANGED`, `klien` dari header `x-queueb-client`, `sumber=UNKNOWN`) tanpa migrasi. Aturan tepat 8 karakter dipertahankan. Regression: 9 unit test di `src/auth/auth.service.spec.ts` + e2e `test/admin-staff-password-reset.e2e-spec.ts` (4 test, DB uji terisolasi, snapshot DB bersih). DTO untuk body masih tertunda.
- **Lokasi**: `apps/api/src/auth/auth.service.ts:293-368` (`adminResetStaffPassword`), dipanggil dari `apps/client/lib/src/doctor_account.dart:279`.
- **Bukti**: transaksi menulis `auditSesi` dengan `aksi:'RESET_PASSWORD'`, `klien:'PORTAL_ADMIN'`, `sumber:'ADMIN'`. Tabel dibuat dengan
  `CHECK (aksi IN ('LOGIN','REFRESH','LOGOUT','CABUT_SESI','BACA_AUDIT'))`, `CHECK (klien IN ('WEB','ANDROID','IOS','DESKTOP','UNKNOWN'))`, `CHECK (sumber = 'UNKNOWN')` (`prisma/migrations/20261102_notifications_and_session_audit/migration.sql:16-20`). Tidak ada migrasi lain yang mengubah constraint ini. Ketiga nilai melanggar → seluruh transaksi rollback (hash sandi tidak berubah) → error 500 ke UI.
- **Masalah tambahan**: tidak ada unit/e2e test untuk endpoint ini; body tidak memakai DTO (`{ kataSandiBaru?: unknown }`, sehingga `ValidationPipe` dilewati); aturan sandi "tepat 8 karakter" (`auth.service.ts:301-307`) lebih lemah dan tidak konsisten dengan registrasi (8–72) — tidak bisa memakai sandi lebih panjang.
- **Rekomendasi**: (a) migrasi aditif yang memperluas CHECK (`aksi` + `RESET_PASSWORD`, `klien` + `PORTAL_ADMIN`/pakai `WEB`, `sumber` + `ADMIN`) dan sinkronkan tipe `AuthAction` di `auth-audit.service.ts:5`; atau pakai nilai yang sudah diizinkan (`CABUT_SESI`/`WEB`/`UNKNOWN`). (b) Buat `AdminResetPasswordDto` (`@IsString @MinLength(8) @MaxLength(72)`). (c) Tambah e2e pada DB uji `127.0.0.1:5433/capstone_antrean_test`.

#### P0-2 Pipeline build/test merah
- **CI GitHub**: 4 dari 5 run terakhir di `main` gagal; run terbaru (`41886461600`, commit `9dda7b9`) gagal di langkah *Flutter Analyze* ("10 issues found"). `.github/workflows/ci.yml` menjalankan `flutter analyze` tanpa `--no-fatal-infos`, sehingga info lint pun menggagalkan build.
- **Lokal (working tree)**:
  - API unit test: **714 lulus / 7 gagal** (2 suite). `reservasi.service.spec.ts` (5 test: mock `tx.tiketAntrean.findMany` tidak ada karena `findAll/findOne` kini memanggil `kedaluwarsakanTiketLampau`) dan `dokter.service.spec.ts` (2 test: mock tidak punya `$transaction`). Penyebab: perubahan [LOKAL] tanpa pembaruan test.
  - API typecheck (`tsc -p tsconfig.json`): 1 error di `apps/api/test/queue-broadcast.e2e-spec.ts:390` — tipe `JenisPerubahanAntrean` kini memuat `CANCEL`, sedangkan helper `postAntrean` hanya menerima 7 aksi. Dengan `ts-jest` (diagnostics aktif) suite e2e ini **gagal dikompilasi**. Build produksi (`tsconfig.build.json`) bersih.
  - `flutter analyze`: 4 info (`display_audio_controller.dart:4`, `patient_ticket_cubit.dart:184,246`, `patient_ticket_dispatch_ui.dart:1`) → exit 1.
  - `dart format`: 3 file belum terformat (`admin_data.dart`, `admin_service_setup_operations.dart`, `doctor_account.dart`) → langkah format CI akan gagal.
  - `flutter test`: **260 gagal / 1.118 lulus** di 39 file — sebagian besar test widget belum mengikuti perubahan UI lokal (lihat §6). Test yang terikat file berversi (`patient_home_v3/v6/v8`, `patient_mobile_v5`) menyumbang porsi terbesar, memperkuat P1-5.
- **CI tidak menjalankan e2e** (32 file `*.e2e-spec.ts`), padahal di situ tes konkurensi, RBAC, dan realtime berada. Tidak ada service PostgreSQL di workflow.
- **Rekomendasi**: perbaiki test & lint sebelum fitur baru; tambahkan job e2e dengan `services: postgres` (DB uji terisolasi, `prisma migrate deploy`); jadikan CI hijau sebagai syarat merge (branch protection).

#### P0-3 [LOKAL] Transaksi tulis di jalur baca pasien
- **Lokasi**: `apps/api/src/reservasi/reservasi.service.ts:59-185` (scheduler + `kedaluwarsakanTiketLampau`), dipanggil di `findAll` (`:388-390`) dan `findOne` (`:400-401`); `TiketService.findAll/findOne` (`src/tiket/tiket.service.ts:66-131`) memanggilnya.
- **Dampak**:
  - Setiap `GET /tiket/saya`, `GET /tiket/:id`, `GET /reservasi*` membuka transaksi DB (minimal satu `findMany` + kemungkinan update/insert) — dipicu juga oleh polling 30 dtk, rekonsiliasi, dan invalidasi realtime di klien (`apps/client/lib/src/patient_sync.dart:55`). GET tidak lagi idempoten/aman; beban DB naik linear terhadap pasien online.
  - Setiap tiket yang di-expire menyisipkan `peristiwa_antrean` status `DILEWATI` → trigger DB membuat notifikasi "Nomor antrean dilewati. Hubungi petugas…" untuk tiket hari-hari lampau (`migration.sql:58`). Pesan ini menyesatkan untuk kasus "tidak datang"; pada impor data 30 hari bisa menghasilkan ribuan notifikasi sekaligus saat API start.
  - Scheduler `setInterval` 60 dtk berjalan di **setiap instance** dan di setiap proses test yang mem-boot `AppModule` (e2e). `onModuleDestroy` tidak dipanggil saat SIGTERM karena `app.enableShutdownHooks()` tidak diaktifkan (`src/main.ts`).
  - Tidak ada broadcast realtime setelah auto-expire; tidak ada test untuk scheduler.
  - Perubahan semantik status (DIPESAN/CHECK_IN/MENUNGGU lampau → DILEWATI) belum tercantum di `docs/backend/API_INTEGRATION_GUIDE.md`, padahal AGENTS.md menyatakan pekerjaan tidak boleh mengubah Queue Engine tanpa kontrak.
- **Rekomendasi**: jalankan expiry hanya dari scheduler (bukan dari GET); gunakan satu `UPDATE … WHERE tanggal_antrean < $batas AND status IN (…) RETURNING` + insert event massal, atau `@nestjs/schedule` dengan lock advisory agar aman multi-instance; tipe event `AUTO_EXPIRE` dengan teks notifikasi khusus (atau dikecualikan dari trigger); nonaktifkan scheduler saat `NODE_ENV=test`; dokumentasikan di API guide; tambahkan test.

### P1 — Tinggi

#### P1-1 Rate limiting & identitas klien di balik proxy
- `ThrottlerModule` hanya dipasang per-endpoint (auth, display, profile) dan berbasis IP in-memory. Express tidak diset `trust proxy` (`src/main.ts`), sehingga di balik ngrok/reverse proxy (`tools/dev/ngrok-preview-proxy.cjs`, `docs/setup/REMOTE_PREVIEW_NGROK.md`) **semua pengguna berbagi satu IP**: 5 login/menit untuk seluruh klinik, 3 register/menit, 5 pairing display/menit.
- Endpoint mutasi lain (reservasi, janji temu, check-in, queue) tidak di-throttle sama sekali; `ThrottlerGuard` tidak global.
- **Rekomendasi**: `app.set('trust proxy', <jumlah hop>)` secara eksplisit dan terdokumentasi; pertimbangkan throttle global default yang longgar + ketat untuk auth; untuk multi-instance gunakan storage Redis.

#### P1-2 Security headers & hardening HTTP
- Tidak ada `helmet`/CSP/HSTS/`X-Content-Type-Options` (grep: tidak ditemukan). Tidak ada batas ukuran body eksplisit selain default.
- Cookie display `secure` hanya jika `NODE_ENV=production` (`src/display/display-cookie.ts:44`); pada preview HTTPS non-production cookie dikirim tanpa `Secure`.
- **Rekomendasi**: tambahkan `helmet` (CSP disesuaikan untuk Flutter Web), set `secure` berdasarkan skema request/konfigurasi, dokumentasikan konfigurasi produksi.

#### P1-3 Dependensi rentan (npm audit, produksi)
- 7 kerentanan (5 high, 2 moderate): `body-parser` 2.0.0–2.3.0 (DoS), `deepmerge-ts` <8 (stack exhaustion, via prisma), `mysql2` (via prisma tooling), `qs`, `fast-uri`. Sebagian dapat diperbaiki dengan `npm audit fix`; sisanya perlu `prisma@7.10.1` (patch).
- **Rekomendasi**: `npm audit fix` pada branch terpisah, naikkan Prisma ke patch terbaru, jalankan seluruh test; tambahkan `npm audit --omit=dev --audit-level=high` ke CI.

#### P1-4 [LOKAL] Perluasan data pasien di portal dokter
- `src/portal-dokter/portal-dokter.service.ts:115,127,213,262,271` kini mengirim `namaPasien`; e2e yang sebelumnya menjaga "no patient identity" dilonggarkan (`test/doctor-portal.e2e-spec.ts:291,308` — regex `Pasien` dihapus). API guide sudah diperbarui dan `Cache-Control: no-store` ditambahkan — baik.
- **Risiko**: pool walk-in ANTREAN_HARIAN menampilkan nama pasien poli yang sama kepada dokter yang belum tentu menangani pasien tersebut (minimisasi data). Perlu keputusan eksplisit pemilik produk dan test negatif baru (dokter lain/poli lain tidak melihat nama).

#### P1-5 Kualitas kode Flutter: file raksasa, berversi, dan dua paradigma
- File > 1.000 baris: `patient.dart` (4.264), `doctor_dashboard.dart` (1.534), `queue.dart` (1.413), `admin_dashboard.dart` (1.378), `patient_reservations.dart` (1.354), `patient_home_v8.dart` (1.165), `admin_data.dart` (1.080), `display_board.dart` (1.049).
- File berversi yang masih saling bergantung: `patient_home.dart`, `patient_home_v6.dart`, `patient_home_v7.dart`, `patient_home_v8.dart`, `patient_mobile_v5.dart`, `staff_v4.dart` (v6 mengimpor v7 dan v8; `patient.dart` mengimpor semuanya). Sulit mengetahui mana UI aktif; risiko perubahan di versi yang salah.
- Dua pola state management sekaligus: `features/*/application` (Cubit/BLoC) vs StatefulWidget + `QueueApi` langsung (mis. `doctor_account.dart:277` memanggil `api.request` dari widget).
- Response API bertipe `Map<String,dynamic>` (`config.dart` `typedef Json`), model bertipe hanya sebagian di `features/*/models`.
- **Rekomendasi**: tetapkan satu pola (Cubit + repository + model bertipe); konsolidasi `patient_home_*` menjadi satu modul tanpa sufiks versi; pecah `patient.dart` per layar; hapus kode tak terpakai setelah dipastikan oleh test.

#### P1-6 Kualitas kode backend: duplikasi Queue Engine
- `src/queue/queue.service.ts` 2.349 baris; 7 metode transisi (`:140, :837, :1118, :1347, :1572, :1833, :2076`) masing-masing menyalin loop retry P2034 (`maksimalPercobaan = 3`) dan kerangka transaksi yang sama.
- Pola otorisasi tidak seragam: `QueueController` memakai `AuthGuard('jwt')` + pengecekan peran manual (`queue.controller.ts:50,72-89`) sementara modul lain memakai `JwtAuthGuard + RolesGuard + @Roles`.
- Duplikasi kecil: dua `JwtAuthGuard` identik (`src/auth/jwt-auth.guard.ts` dan `src/auth/guards/jwt-auth.guard.ts`); tiga implementasi "tanggal hari ini lokal" (`reservasi.service.ts:446`, `hospital/hospital-context.ts` `waktuPelayanan`, dan origin parsing CORS berulang di `socket-handshake-security.ts:62` & `display-cookie.ts:27`).
- **Rekomendasi**: ekstrak helper `denganRetrySerializable(fn)`; seragamkan guard + `@Roles(PETUGAS)` di controller; satu util waktu layanan & satu util origin.

#### P1-7 Performa jalur autentikasi & broadcast
- `JwtStrategy.validate` (`src/auth/jwt.strategy.ts:24-66`) melakukan 2–3 query DB per request (user, sesi, dokter). Dikombinasikan dengan polling klien dan P0-3, beban DB per pengguna aktif signifikan.
- `RealtimeGateway.broadcastPerubahan` (`src/realtime/realtime.gateway.ts:117-146`) memvalidasi ulang akses setiap socket secara **sekuensial** per event (N socket × query). Aman, tetapi O(N) query per transisi antrean.
- **Rekomendasi**: cache singkat (mis. 15–30 dtk) status sesi/peran per `sid` yang diinvalidasi saat logout/reset; validasi broadcast secara paralel terbatas atau cache hasil izin per socket dengan TTL.

#### P1-8 Kebersihan repository & data sensitif
- Untracked dan tidak di-.gitignore: `backups/` (dump PostgreSQL: `QueueB_sebelum_hapus_sesi_20261108.backup`, `queueb_sebelum_hospital_h1.dump`, …), `artifacts/` (74 MB), `Naskah Presentasi … .docx`, `apps/api/tool/queueb-data-30hari.json` (540 pasien fiktif, ditandai "FIKTIF"), `apps/web/`, log `*.log` di `apps/client/`. Sekali `git add .` tidak sengaja, dump DB (berisi hash sandi & data sesi) ikut ter-commit.
- `.env` root masih memakai `POSTGRES_PASSWORD` default `change-me-local-only` (lokal saja, tetapi port 5433 di-expose ke host oleh `compose.yml`).
- **Rekomendasi**: tambahkan `backups/`, `artifacts/`, `*.backup`, `*.dump`, `*.docx`, `apps/web/dist/` ke `.gitignore`; simpan dump di luar repo; ganti password DB lokal.

#### P1-9 Rilis Android belum siap
- `apps/client/android/app/build.gradle.kts:33-36`: build release ditandatangani dengan **debug key** (TODO bawaan template).
- Default `API_BASE_URL` = `http://localhost:3000/api/v1` (`lib/src/config.dart`); APK rilis memerlukan HTTPS (cleartext diblokir default Android 9+).
- **Rekomendasi**: konfigurasi signing via `key.properties` (sudah di-.gitignore), flavor/`--dart-define` per lingkungan, dokumentasi build rilis.

### P2 — Menengah / Rendah

| # | Temuan | Lokasi | Rekomendasi |
|---|---|---|---|
| P2-1 | Refresh token reuse tidak memicu pencabutan sesi (hanya ditolak). | `auth.service.ts` `refreshInternal` (CAS `updateMany`) | Bila hash tidak cocok untuk sesi valid → cabut sesi (deteksi pencurian token). |
| P2-2 | `LoginDto.kataSandi` tanpa `MaxLength`; registrasi tanpa aturan kompleksitas. | `auth/dto/login.dto.ts`, `register.dto.ts` | `@MaxLength(72)` (batas bcrypt); kebijakan minimum terdokumentasi. |
| P2-3 | Sesi Web hanya di memori → reload/tab baru = logout. Disengaja demi keamanan, tetapi tidak dijelaskan di UI. | `apps/client/lib/src/session_store.dart:20` | Pertimbangkan refresh token via cookie httpOnly untuk Web, atau pesan UX yang jelas. |
| P2-4 | Reservasi tanpa batas tanggal maksimum di backend (klien membatasi 365 hari). | `reservasi.service.ts:421-444`, `config.dart` `initialServiceDate` | Validasi batas horizon di server. |
| P2-5 | Tidak ada unique constraint DB untuk 1 reservasi aktif per pasien/layanan/tanggal (hanya dicek di transaksi Serializable). | `reservasi.service.ts:268-286` | Partial unique index `WHERE status <> 'DIBATALKAN'`. |
| P2-6 | Endpoint daftar admin tanpa pagination (dokter, layanan, loket, jadwal). | `dokter.service.ts:116-146`, dll. | Pagination/limit konsisten seperti `queue/snapshot`. |
| P2-7 | Health check tidak membedakan liveness/readiness; tanpa versi build. | `src/health/health.controller.ts` | `/health/live` & `/health/ready`, sertakan versi commit. |
| P2-8 | Tidak ada logging terstruktur / request-id / error tracking. | global | Logger JSON + correlation id; Sentry/OTel opsional. |
| P2-9 | Lint API: variabel tak terpakai & `new Array(n)`. | `laporan/laporan.service.ts:65-86`, `laporan.service.spec.ts:50` | Gunakan `_`-prefix/omit util. Controller laporan didefinisikan di file module (`laporan.module.ts:26`) — pindahkan. |
| P2-10 | `apps/web` kosong tetapi disebut di README; `infra/docker`, `docs/api`, `docs/database`, `docs/dfd` kosong. | root | Hapus/isi; README menyatakan status sebenarnya. |
| P2-11 | Dokumentasi sangat terfragmentasi (±50 dokumen fase di `docs/frontend`, 14 di `docs/backend`, `CONTRIBUTING.md` 62 KB). | `docs/` | Satu indeks arsitektur + ADR; arsipkan dokumen fase lama. |
| P2-12 | Penamaan migrasi tidak seragam (tanpa jam). | `prisma/migrations/2026101{3,4,8,9}_*`, `20261024_*`, `20261102_*` | Gunakan `prisma migrate dev --create-only` (timestamp penuh) ke depan. |
| P2-13 | Polling cadangan berganda di klien (patient 30 dtk, staff/display 15 dtk, dashboard 30 dtk, display clock 1 dtk). | `patient_sync.dart:55`, `staff_queue_bloc.dart:66`, `display_monitor_bloc.dart:120`, `admin_dashboard_header.dart:298`, `doctor_visual.dart:165`, `staff_v4.dart:53` | Polling hanya saat socket terputus; backoff eksponensial. |
| P2-14 | Analisis Flutter memakai `flutter_lints` dasar; 38 penggunaan `dynamic>`/`as dynamic`. | `analysis_options.yaml`, `lib/src/**` | Aktifkan `strict-casts`, `strict-raw-types` bertahap. |
| P2-15 | Tidak ada `enableShutdownHooks()`; interval/socket tidak dibersihkan pada SIGTERM. | `src/main.ts` | Aktifkan shutdown hooks. |

---

## 4. Alur Bisnis per Portal (hasil penelusuran kode)

| Portal | Alur yang didukung (kode aktual) | Celah / catatan |
|---|---|---|
| **Pasien (USER)** | Register/login → katalog layanan & dokter (`GET /layanan`, `/dokter` difilter per peran) → reservasi harian (`POST /reservasi`) atau janji temu dokter (`POST /janji-temu`, advisory lock slot) → tiket + QR (`POST /tiket/:id/qr`) → pantau posisi/estimasi (`GET /layanan/antrean`, socket `/patient`) → notifikasi (trigger DB) → profil & avatar. | P0-3 (GET menulis), notifikasi DILEWATI untuk tiket lampau [LOKAL], sesi Web hilang saat reload. |
| **Petugas** | Penugasan loket per tanggal → scan QR/check-in (`/check-in`, `/check-in/verifikasi-reservasi`, `/check-in/auto-antrean`) → masuk antrean → CALL/RECALL/SKIP/REQUEUE/START/COMPLETE (`/queue/*`) → snapshot + tindak lanjut berhalaman → batalkan sesi berakhir. | Otorisasi peran manual di controller (P1-6). Tidak ada throttle mutasi. |
| **Dokter** | Login (wajib profil dokter aktif) → profil, jadwal sendiri, janji temu, snapshot antrean sesi aktif (`/portal-dokter/*`, socket `/doctor`). Read-only; tidak dapat memanggil pasien. | P1-4 nama pasien [LOKAL]. Dokter tidak memiliki aksi operasional (sesuai desain), pastikan ekspektasi pengguna. |
| **Admin** | CRUD layanan/poli, loket/ruang, jadwal layanan, dokter (+foto, akun, relasi poli), jadwal praktik, slot, penugasan petugas, akun petugas, perangkat display (aktivasi kode 12 digit, 5 percobaan/menit), laporan operasional (maks 5.000 baris), audit sesi, hapus terkontrol (`admin-delete`). | P0-1 reset sandi [LOKAL]; daftar tanpa pagination (P2-6). |
| **Public Display** | Pairing kode → cookie httpOnly per perangkat → snapshot (`/display/:layananId/snapshot`) + socket `/display` → TTS/audio pemanggilan, multi-monitor. | Cookie `Secure` hanya production (P1-2). Reconnect bergantung polling 15 dtk. |

---

## 5. Integrasi Frontend ↔ Backend ↔ DB ↔ WebSocket

- **Kontrak**: `docs/backend/API_INTEGRATION_GUIDE.md` (2.104 baris) adalah sumber kebenaran. Drift ditemukan: auto-expire `AUTO_EXPIRE` [LOKAL], field `loketLayanan` pada `GET /tiket/saya` & `/tiket/:id` [LOKAL], dan endpoint `PATCH /auth/admin/accounts/:id/password` [LOKAL] **belum terdokumentasi**.
- **Realtime**: event hanya sebagai sinyal invalidasi; klien selalu re-fetch REST (`patient_sync.dart:38-39`) — desain yang baik untuk konsistensi, tetapi memperbesar efek P0-3/P1-7.
- **Single instance**: gateway, rate limit handshake (`socket-handshake-security.ts`), throttler, dan scheduler semuanya in-process. Scale-out butuh Socket.IO Redis adapter, throttler storage bersama, dan lock scheduler — sudah dicatat di komentar kode, belum ada rencana implementasi.
- **Zona waktu**: server memakai `SERVICE_TIME_ZONE` (default Asia/Jakarta), klien memakai paket `timezone` dengan nilai `--dart-define` yang sama; ketidaksamaan konfigurasi tidak terdeteksi otomatis. Rekomendasi: kirim zona waktu server pada respons `/health` atau `/auth/me` dan validasi di klien.

---

## 6. Status Pengujian & Build (hasil aktual 2026-11-09)

| Pemeriksaan | Perintah | Hasil |
|---|---|---|
| API typecheck (build) | `tsc --noEmit -p tsconfig.build.json` | ✅ bersih |
| API typecheck (src+test) | `tsc --noEmit -p tsconfig.json` | ❌ 1 error `test/queue-broadcast.e2e-spec.ts:390` |
| API lint | `npm run lint` (oxlint) | ✅ 0 error, 7 warning |
| API unit test | `jest` (dengan `--experimental-vm-modules`) | ❌ 714 lulus / 7 gagal (reservasi ×5, dokter ×2) |
| API e2e | — | ⏭️ tidak dijalankan (menulis DB; di luar aturan audit) |
| npm audit (prod) | `npm audit --omit=dev` | ❌ 5 high, 2 moderate |
| Flutter analyze | `flutter analyze` | ❌ 4 info (exit 1) |
| Dart format | `dart format --output=none --set-exit-if-changed` | ❌ 3 file |
| Flutter test | `flutter test` | ❌ **1.118 lulus / 260 gagal / 1 skip** di 39 file (terbanyak: `patient_home_v8_test` 38, `patient_home_v3_test` 23, `ui_test` 19, `admin_modern_refresh_test` 19, `login_ui_test` 17, `patient_reservations_test` 14, `doctor_schedule_test` 12, `patient_mobile_v5_test` 11). Pola dominan "Expected: exactly one matching candidate" → finder teks/widget tidak lagi cocok dengan UI hasil perubahan lokal (test usang, bukan crash). |
| Flutter build web | — | ⏭️ tidak dijalankan pada audit ini |
| CI GitHub `main` | `gh run list` | ❌ run terbaru gagal (Flutter analyze); 4/5 run terakhir gagal |

**Cakupan test yang ada**: API memiliki 53 suite unit (721 test) + 32 suite e2e dengan guard DB uji (`capstone_antrean_test`) — cakupan domain antrean, RBAC, realtime, dan konkurensi sangat baik. Flutter memiliki ±130 file test termasuk BLoC test dan `integration_test/final_qa_smoke_test.dart`. Celah: tidak ada test untuk auto-expire, reset sandi admin, dan e2e tidak berjalan di CI.

---

## 7. Fitur Belum Selesai / Belum Siap Produksi

1. Reset kata sandi staf oleh admin (P0-1) — belum berfungsi.
2. Auto-expire tiket lampau (P0-3) — fungsional tetapi belum aman/terdokumentasi/teruji.
3. `apps/web` — direktori kosong; tidak ada aplikasi web terpisah (Flutter Web yang dipakai).
4. Infrastruktur deploy — tidak ada Dockerfile API/Flutter, `infra/docker` kosong, tidak ada konfigurasi reverse proxy produksi, tidak ada strategi backup otomatis.
5. Skala horizontal — realtime/throttle/scheduler single-instance.
6. Rilis Android — signing debug, URL API lokal.
7. Observability — tanpa logging terstruktur, metrik, atau alerting.
8. Komentar skema `// H1 HOSPITAL — PERLUASAN ADITIF (REVIEW, BELUM MIGRASI)` (`schema.prisma:338`) sudah usang (migrasi sudah ada) — membingungkan.

---

## 8. Roadmap Pengembangan Bertahap

### P0 — Stabilisasi (target: 1 sprint, sebelum fitur baru)

| # | Pekerjaan | Kriteria selesai |
|---|---|---|
| 1 | Perbaiki reset sandi admin: migrasi aditif CHECK `audit_sesi` (atau nilai yang diizinkan), DTO, batas 8–72, sinkron `AuthAction`. | e2e pada `capstone_antrean_test` lulus: sukses, sesi target dicabut, audit tercatat, non-admin 403. |
| 2 | Pindahkan auto-expire keluar dari GET; scheduler tunggal dengan advisory lock; notifikasi/tipe event khusus; nonaktif di test; dokumentasi API guide. | Unit test scheduler + e2e; `GET /tiket/saya` tanpa write (verifikasi via log query). |
| 3 | Perbarui 7 unit test API yang gagal & perbaiki tipe `queue-broadcast.e2e-spec.ts`. | `npm test` dan `tsc -p tsconfig.json` hijau. |
| 4 | Bersihkan `flutter analyze` (4 info) dan format 3 file; perbaiki test Flutter yang gagal. | `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test` hijau; CI `main` hijau. |
| 5 | Lindungi repo: `.gitignore` untuk `backups/`, `artifacts/`, dump, docx, `apps/web/dist`; pindahkan dump keluar repo. | `git status` bersih dari artefak sensitif. |
| 6 | Commit perubahan lokal secara terarah (per fitur, stage eksplisit) setelah butir 1–4. | Riwayat commit terpisah per domain; tidak ada perubahan tak terlacak. |

### P1 — Hardening & Fondasi (target: 2–3 sprint)

1. Job CI e2e dengan PostgreSQL service + `prisma migrate deploy`; `npm audit --audit-level=high` di CI; branch protection.
2. `trust proxy` eksplisit, `helmet`, cookie `secure` berbasis konfigurasi, throttle default global.
3. Upgrade dependensi rentan (Prisma patch, `npm audit fix`), regresi penuh.
4. Keputusan & test minimisasi data `namaPasien` di portal dokter.
5. Refactor Queue Engine: helper retry Serializable, guard/`@Roles` seragam, util waktu & origin tunggal, hapus guard duplikat.
6. Flutter: konsolidasi `patient_home_v6/v7/v8`, `patient_mobile_v5`, `staff_v4`; pecah `patient.dart`; satu pola Cubit + repository + model bertipe untuk modul yang disentuh.
7. Cache validasi sesi JWT & optimasi broadcast realtime; polling klien hanya saat socket terputus.
8. Release Android: signing, konfigurasi lingkungan via `--dart-define`, HTTPS.

### P2 — Skalabilitas & Kematangan (berkelanjutan)

1. Socket.IO Redis adapter, throttler storage bersama, scheduler terdistribusi (siap multi-instance).
2. Dockerfile API + Flutter Web, compose lengkap (API, DB, reverse proxy), backup otomatis terenkripsi di luar repo.
3. Observability: logger terstruktur + request-id, health live/ready, metrik antrean (dari data nyata), error tracking.
4. Pagination konsisten di endpoint admin; partial unique index reservasi aktif; batas horizon reservasi di server.
5. Deteksi reuse refresh token; kebijakan sandi; opsi sesi Web persisten yang aman (cookie httpOnly).
6. Lint ketat Dart (`strict-casts`, `strict-raw-types`) bertahap; kurangi `dynamic`.
7. Konsolidasi dokumentasi: indeks arsitektur, ADR, arsip dokumen fase; isi atau hapus folder kosong (`apps/web`, `infra/docker`, `docs/api|database|dfd`).

---

## 9. Kekuatan yang Perlu Dipertahankan

- Queue Engine transaksional dengan state machine, CAS `versi`, retry Serializable, dan advisory lock — jangan diganti tanpa test konkurensi setara.
- Broadcast setelah commit + realtime sebagai sinyal invalidasi (klien selalu re-fetch REST).
- Sesi JWT terikat sesi DB, rotasi refresh atomik, audit sesi terpseudonimisasi (tanpa IP/UA/ID mentah).
- `RoutePolicy` Flutter yang ketat terhadap open-redirect, isolasi token per `API_BASE_URL` di secure storage.
- Guard target DB pada tooling data (`tool/*.cjs`) dan e2e (`capstone_antrean_test`).
- Cakupan test API yang luas (721 unit test, 32 suite e2e).

---

*Laporan ini dihasilkan dari kode pada working tree 2026-11-09. Semua perubahan lokal dipertahankan; tidak ada commit, reset, atau akses tulis ke database yang dilakukan selama audit.*
