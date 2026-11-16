-- Push notification FCM untuk pasien Android.
-- Tabel notifikasi tetap sumber kebenaran; push adalah salinan best effort.
-- Trigger queueb_notifikasi_peristiwa tidak diubah.

-- Token perangkat terikat ke sesi login. Sesi dihapus = token ikut terhapus;
-- sesi dicabut/kedaluwarsa disaring dispatcher sehingga push berhenti.
CREATE TABLE perangkat_push (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pengguna_id uuid NOT NULL REFERENCES pengguna(id) ON DELETE CASCADE,
  sesi_pengguna_id uuid NOT NULL REFERENCES sesi_pengguna(id) ON DELETE CASCADE,
  token varchar(4096) NOT NULL,
  platform varchar(16) NOT NULL,
  dibuat_pada timestamptz(6) NOT NULL DEFAULT now(),
  diperbarui_pada timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT perangkat_push_platform_check CHECK (platform = 'ANDROID'),
  CONSTRAINT perangkat_push_token_check CHECK (length(btrim(token)) > 0)
);

CREATE UNIQUE INDEX perangkat_push_token_key ON perangkat_push(token);
CREATE INDEX perangkat_push_pengguna_id_diperbarui_pada_idx ON perangkat_push(pengguna_id, diperbarui_pada);
CREATE INDEX perangkat_push_sesi_pengguna_id_idx ON perangkat_push(sesi_pengguna_id);

-- Penanda klaim dispatcher. Baris lama ditandai agar tidak ada push historis.
ALTER TABLE notifikasi ADD COLUMN push_diproses_pada timestamptz(6);
UPDATE notifikasi SET push_diproses_pada = now() WHERE push_diproses_pada IS NULL;

CREATE INDEX idx_notifikasi_push_antrean
  ON notifikasi(dibuat_pada, id)
  WHERE push_diproses_pada IS NULL;
