# QueueB - Sistem Manajemen Antrean Digital

Repository utama Capstone Project STSI4440
Program Studi Sistem Informasi
Universitas Terbuka.

## Status

Backend MVP QueueB selesai. Aplikasi Flutter di `apps/client` menyediakan portal PASIEN (USER), ADMIN, PETUGAS, DOKTER, dan Public Display, termasuk tiket digital, cetak, dan unduh PDF.

Kontrak API: [Panduan Integrasi Backend](docs/backend/API_INTEGRATION_GUIDE.md).
Menjalankan aplikasi: [Panduan Instalasi Lokal](docs/setup/LOCAL_INSTALLATION_GUIDE.md).
Demo HTTPS opsional: [Remote Preview ngrok](docs/setup/REMOTE_PREVIEW_NGROK.md).
Acuan tampilan: [Panduan UI/UX QueueB](docs/frontend/QUEUEB_UI_UX_GUIDELINES.md).

## Tujuan

Mengembangkan sistem manajemen antrean digital untuk
mendukung proses pelayanan secara terintegrasi melalui:

- Reservasi layanan
- Tiket antrean digital
- QR Check-In
- Real-Time Monitoring
- Posisi dan estimasi waktu tunggu
- Operasional petugas
- Public Display
- Text-to-Speech
- Dashboard administrasi

## Struktur Repository

```text
apps/
├── client/     Flutter Android dan Web untuk lima portal
├── web/        Folder tambahan; belum berisi source aplikasi lengkap
└── api/        NestJS Backend

docs/
├── requirements/
├── architecture/
├── database/
├── dfd/
├── uml/
├── ui-ux/
├── api/
└── testing/

infra/
└── docker/

scripts/
```

## Tim Pengembang

QueueB dikembangkan oleh **Kelompok B** Capstone Project STSI4440,
Program Studi Sistem Informasi, Universitas Terbuka.

| No. | Nama                       | Peran                          | Kontribusi                                                                                 |
| --- | -------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------ |
| 1   | Yusran Abdullah Arief      | Develop Sistem/Produk          | Coding sistem (frontend, backend, database, TTS, integrasi) dan bahan demo teknis          |
| 2   | Sindi Rohmawati Setyana    | Koordinator Laporan Akhir      | Proposal, laporan kemajuan, penggabungan dan finalisasi laporan akhir                      |
| 3   | Lestari Aslindawati Waruwu | Koordinator PPT & Poster       | Presentasi, poster A4, serta pengolahan screenshot/diagram sistem menjadi materi visual    |
| 4   | Putri Meilani              | Koordinator Video & Dokumentasi | Script dan rekaman demo, editing video, unggah YouTube, dan dokumentasi proses proyek     |
| 5   | Indah Suci Permatasari     | Koordinator Karya Ilmiah       | Penyusunan karya ilmiah, referensi, dan sitasi                                             |
