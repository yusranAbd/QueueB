-- H1 QueueB Hospital — PRE-FLIGHT READ ONLY
-- Gunakan hanya pada DB dev/staging yang dimaksud; tidak mengubah data.
-- Cocokkan nama schema (default public) dengan database Anda.

-- Migrasi yang telah diterapkan
SELECT migration_name, finished_at, rolled_back_at
FROM "_prisma_migrations"
ORDER BY started_at DESC LIMIT 20;

-- Status lama (cek kesiapan mode ANTREAN_HARIAN)
SELECT status::text AS status_tiket, COUNT(*) AS jumlah
FROM tiket_antrean GROUP BY status ORDER BY status;

-- Potensi duplikasi AKTIF per pasien/poli/hari;
-- harus ditinjau sebelum membuat partial unique index opsional.
SELECT pengguna_id, layanan_id, tanggal_antrean, COUNT(*) AS jumlah
FROM tiket_antrean
WHERE status <> 'DIBATALKAN'
GROUP BY pengguna_id, layanan_id, tanggal_antrean
HAVING COUNT(*) > 1
ORDER BY jumlah DESC LIMIT 25;

-- Inventaris tabel yang akan diubah/ditambah
SELECT table_name FROM information_schema.tables
WHERE table_schema='public'
AND table_name IN ('layanan','tiket_antrean','dokter','dokter_layanan',
                   'jadwal_praktik','slot_praktik','janji_temu')
ORDER BY table_name;
