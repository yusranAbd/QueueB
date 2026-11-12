-- Bedakan notifikasi tiket kedaluwarsa (event AUTO_EXPIRE dari scheduler) dari
-- nomor yang dilewati petugas (SKIP). Status tiket tetap DILEWATI; hanya teks
-- notifikasi baru yang berubah. Tidak ada backfill notifikasi historis.
CREATE OR REPLACE FUNCTION queueb_notifikasi_peristiwa() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  pemilik UUID;
  nomor TEXT;
  nama_layanan TEXT;
  nama_ruang TEXT;
  judul_pesan TEXT;
  isi TEXT;
  jenis_pesan "jenis_notifikasi";
BEGIN
  IF NEW.status_sesudah IS NULL OR
     (NEW.status_sebelum IS NOT DISTINCT FROM NEW.status_sesudah AND NEW.tipe <> 'RECALL') THEN
    RETURN NEW;
  END IF;
  SELECT t.pengguna_id, trim(l.prefix_antrean) || '-' || lpad(t.nomor_urut::text, greatest(3, length(t.nomor_urut::text)), '0'), l.nama, k.nama
    INTO pemilik, nomor, nama_layanan, nama_ruang
    FROM tiket_antrean t JOIN layanan l ON l.id=t.layanan_id
    LEFT JOIN loket k ON k.id=t.loket_id WHERE t.id=NEW.tiket_antrean_id;
  IF pemilik IS NULL THEN RETURN NEW; END IF;
  jenis_pesan := 'PERUBAHAN_STATUS';
  CASE NEW.status_sesudah
    WHEN 'DIPESAN' THEN judul_pesan := 'Reservasi berhasil'; isi := 'Reservasi Anda telah tersimpan.';
    WHEN 'CHECK_IN' THEN judul_pesan := 'Check-in berhasil'; isi := 'Kehadiran Anda telah dicatat.';
    WHEN 'MENUNGGU' THEN judul_pesan := 'Masuk antrean'; isi := 'Anda terdaftar dalam antrean. Pantau status untuk panggilan berikutnya.';
    WHEN 'DIPANGGIL' THEN
      judul_pesan := CASE WHEN NEW.tipe='RECALL' THEN 'Nomor dipanggil ulang' ELSE 'Nomor Anda dipanggil' END;
      isi := 'Silakan menuju ' || coalesce(nama_ruang, 'ruang pelayanan') || '.';
      jenis_pesan := 'PEMANGGILAN';
    WHEN 'DILAYANI' THEN judul_pesan := 'Pelayanan dimulai'; isi := 'Status tiket Anda telah berubah menjadi dilayani.';
    WHEN 'SELESAI' THEN judul_pesan := 'Pelayanan selesai'; isi := 'Pelayanan tiket Anda telah selesai.';
    WHEN 'DILEWATI' THEN
      IF NEW.tipe = 'AUTO_EXPIRE' THEN
        judul_pesan := 'Tiket kedaluwarsa';
        isi := 'Tanggal pelayanan sudah berlalu sebelum tiket dilayani, sehingga tiket tidak berlaku lagi. Buat reservasi baru bila masih membutuhkan layanan.';
      ELSE
        judul_pesan := 'Nomor antrean dilewati';
        isi := 'Hubungi petugas untuk tindak lanjut antrean Anda.';
      END IF;
    WHEN 'DIBATALKAN' THEN judul_pesan := 'Reservasi dibatalkan'; isi := 'Tiket Anda telah dibatalkan. Hubungi petugas jika membutuhkan tindak lanjut.';
    ELSE RETURN NEW;
  END CASE;
  INSERT INTO notifikasi (id,pengguna_id,tiket_antrean_id,peristiwa_antrean_id,jenis,judul,pesan,dibuat_pada)
    VALUES (gen_random_uuid(),pemilik,NEW.tiket_antrean_id,NEW.id,jenis_pesan,judul_pesan,
      nomor || ' · ' || nama_layanan || '. ' || isi, clock_timestamp())
    ON CONFLICT (peristiwa_antrean_id) DO NOTHING;
  RETURN NEW;
END;
$$;
