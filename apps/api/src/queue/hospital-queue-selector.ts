import { ModeReservasi } from '../generated/prisma/client';
import { alasanPenerimaanHospital, PILIH_JANJI_TEMU_HOSPITAL, type KonteksSlotHospital, type AlasanTidakLayakHospital } from '../hospital/hospital-context';

/**
 * H3.3: selector murni tanpa operasi database.
 * Berlaku hanya untuk mode JANJI_TEMU_DOKTER/HIBRIDA; ANTREAN_HARIAN
 * tetap melewati jalur FIFO lama di QueueService.
 *
 * Slot yang sudah dimulai layak dipanggil di loket yang ditetapkan dokter,
 * selama rantai relasinya aktif dan sesi praktik masih berlangsung pada
 * tanggal tiket. Akhir slot adalah estimasi konsultasi,
 * bukan kedaluwarsa hak pasien yang masih MENUNGGU (kebijakan H1).
 * Toleransi keterlambatan dan anti-starvation numerik tidak ditetapkan di sini.
 */
export interface KandidatHospital {
  id: string;
  urutanMasukAntrean: number | null;
  checkInPada: Date | null;
  tanggalAntrean: Date;
  layananId: string;
  /** Query hanya mengambil audit REQUEUE terbaru; bukan bagian respons API. */
  peristiwaAntrean?: readonly { terjadiPada: Date }[];
  janjiTemu: {
    slotPraktik: KonteksSlotHospital;
  } | null;
}

export type JenisAntreanHospital = 'JANJI_TEMU' | 'WALK_IN';

export interface KandidatTerurut<T extends KandidatHospital> {
  tiket: T;
  jenisAntrean: JenisAntreanHospital;
  layakDipanggil: boolean;
  slotMulaiPada: string | null;
  prioritas: number;
  alasanTidakLayak: AlasanTidakLayakHospital | null;
}

function waktuPrioritas(tiket: KandidatHospital): number {
  return (tiket.peristiwaAntrean?.[0]?.terjadiPada ?? tiket.checkInPada)?.getTime() ??
    Number.MAX_SAFE_INTEGER;
}

function statusKandidat<T extends KandidatHospital>(
  tiket: T,
  mode: ModeReservasi,
  loketId: string,
  sekarang: Date,
  sesiWalkInAktif: boolean,
): KandidatTerurut<T> {
  const slot = tiket.janjiTemu?.slotPraktik;
  if (!slot) {
    const alasan: AlasanTidakLayakHospital | null = tiket.checkInPada === null ? 'BELUM_CHECK_IN' :
      mode !== ModeReservasi.HIBRIDA ? 'APPOINTMENT_TIDAK_ADA' :
      !sesiWalkInAktif ? 'SESI_WALK_IN_TIDAK_TERSEDIA' : null;
    const bolehWalkIn = alasan === null;
    return {
      tiket,
      jenisAntrean: 'WALK_IN',
      layakDipanggil: bolehWalkIn,
      slotMulaiPada: null,
      prioritas: bolehWalkIn ? 1 : 2,
      alasanTidakLayak: alasan,
    };
  }
  const alasan: AlasanTidakLayakHospital | null = tiket.checkInPada === null ? 'BELUM_CHECK_IN' :
    alasanPenerimaanHospital({ ...tiket, modeReservasi: mode }, loketId, sekarang) ??
    (slot.jadwalPraktik.mulaiPada > sekarang ? 'SESI_BELUM_DIMULAI' :
      slot.mulaiPada > sekarang ? 'SLOT_BELUM_DIMULAI' : null);
  const layak = alasan === null;
  return {
    tiket,
    jenisAntrean: 'JANJI_TEMU',
    layakDipanggil: layak,
    slotMulaiPada: slot.mulaiPada.toISOString(),
    prioritas: layak ? 0 : 2,
    alasanTidakLayak: alasan,
  };
}

/**
 * Satu sumber logika untuk CALL, GET menunggu dan REST snapshot.
 * Total order deterministik: prioritas > slot > waktu REQUEUE terbaru
 * (atau check-in jika belum pernah REQUEUE) > urutan masuk > id.
 * Tidak mengubah nomor tiket permanen atau waktu check-in asli.
 */
export function urutkanKandidatHospital<T extends KandidatHospital>(
  kandidat: readonly T[],
  mode: ModeReservasi,
  loketId: string,
  sekarang: Date,
  sesiWalkInAktif: boolean,
): Array<KandidatTerurut<T>> {
  const terurut = kandidat.map((tiket) => statusKandidat(tiket, mode, loketId, sekarang, sesiWalkInAktif));
  terurut.sort(bandingkanKandidatHospital);
  return terurut;
}

/** Comparator yang sama juga dipakai proyeksi display lintas ruang; tidak mengubah CALL. */
export function bandingkanKandidatHospital<T extends KandidatHospital>(
  a: KandidatTerurut<T>, b: KandidatTerurut<T>,
): number {
  if (a.prioritas !== b.prioritas) return a.prioritas - b.prioritas;
  // Appointment pada slot lebih awal berhak dipanggil lebih dahulu.
  if (a.jenisAntrean === 'JANJI_TEMU' && b.jenisAntrean === 'JANJI_TEMU') {
    const waktuSlotA = a.tiket.janjiTemu?.slotPraktik.mulaiPada.getTime() ?? Number.MAX_SAFE_INTEGER;
    const waktuSlotB = b.tiket.janjiTemu?.slotPraktik.mulaiPada.getTime() ?? Number.MAX_SAFE_INTEGER;
    if (waktuSlotA !== waktuSlotB) return waktuSlotA - waktuSlotB;
  }
  const waktuA = waktuPrioritas(a.tiket);
  const waktuB = waktuPrioritas(b.tiket);
  if (waktuA !== waktuB) return waktuA - waktuB;
  const urutanA = a.tiket.urutanMasukAntrean ?? Number.MAX_SAFE_INTEGER;
  const urutanB = b.tiket.urutanMasukAntrean ?? Number.MAX_SAFE_INTEGER;
  if (urutanA !== urutanB) return urutanA - urutanB;
  return a.tiket.id.localeCompare(b.tiket.id);
}

/**
 * Select bersama untuk CALL, daftar menunggu, snapshot, dan posisi pasien.
 * Tidak membaca identitas pasien ataupun token QR.
 */
export const PILIHAN_KANDIDAT_HOSPITAL = {
  id: true,
  layananId: true,
  tanggalAntrean: true,
  nomorUrut: true,
  status: true,
  versi: true,
  loketId: true,
  urutanMasukAntrean: true,
  masukAntreanPada: true,
  checkInPada: true,
  // Audit REQUEUE adalah bukti bahwa FIFO tidak lagi memakai CHECK_IN awal.
  peristiwaAntrean: {
    where: { tipe: 'REQUEUE' },
    orderBy: { terjadiPada: 'desc' },
    take: 1,
    select: { terjadiPada: true },
  },
  janjiTemu: PILIH_JANJI_TEMU_HOSPITAL,
} as const;

/**
 * Jumlah tiket MENUNGGU yang dipanggil lebih dulu daripada tiket walk-in target
 * pada poli HIBRIDA, memakai comparator yang sama dengan CALL. Yang mendahului:
 * janji temu yang sudah layak dipanggil di ruang dokternya (prioritas 0) dan
 * walk-in dengan urutan lebih awal (prioritas 1). Mengembalikan null bila target
 * bukan walk-in yang sudah check-in. Hanya perkiraan urutan, bukan janji waktu:
 * kelayakan janji temu per ruang dan sesi walk-in dapat berubah.
 */
export function hitungDiDepanWalkIn<T extends KandidatHospital>(
  kandidat: readonly T[],
  tiketId: string,
  sekarang: Date,
): number | null {
  const terurut = kandidat.map((tiket) => statusKandidat(
    tiket,
    ModeReservasi.HIBRIDA,
    // Janji temu dinilai di ruang sesi dokternya sendiri.
    tiket.janjiTemu?.slotPraktik.jadwalPraktik.loketId ?? '',
    sekarang,
    // Urutan walk-in tidak bergantung pada sesi yang kebetulan sedang berjalan.
    true,
  ));
  const target = terurut.find((item) => item.tiket.id === tiketId);
  if (!target || target.jenisAntrean !== 'WALK_IN' || !target.layakDipanggil) return null;
  terurut.sort(bandingkanKandidatHospital);
  return terurut.findIndex((item) => item.tiket.id === tiketId);
}

/** Slot mendatang, relasi nonaktif atau ruang lain tidak boleh di-CALL. */
export function pilihBerikutnyaHospital<T extends KandidatHospital>(
  kandidat: readonly T[],
  mode: ModeReservasi,
  loketId: string,
  sekarang: Date,
  sesiWalkInAktif: boolean,
): T | null {
  return (
    urutkanKandidatHospital(kandidat, mode, loketId, sekarang, sesiWalkInAktif)
      .find((item) => item.layakDipanggil)?.tiket ?? null
  );
}
