-- READ ONLY: gunakan hanya untuk verifikasi target, tanpa mutasi.
SELECT current_database() AS database_saat_ini;
SELECT enumlabel AS mode_tersedia
FROM pg_enum e JOIN pg_type t ON e.enumtypid = t.oid
WHERE t.typname = 'mode_reservasi'
ORDER BY e.enumsortorder;
SELECT mode_reservasi, COUNT(*) AS jumlah_poli
FROM layanan GROUP BY mode_reservasi ORDER BY mode_reservasi;
