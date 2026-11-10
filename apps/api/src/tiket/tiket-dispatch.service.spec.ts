import { ModeReservasi, StatusTiket } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { ReservasiService } from '../reservasi/reservasi.service';
import { TiketService } from './tiket.service';

const penggunaId = 'ec8a387e-f186-4324-8c6a-faec174ce55c';
const layananId = '1bfa9aa4-6c27-4e67-b938-b0fb53f485cf';
// 12:00 WIB pada 2030-01-01.
const sekarang = new Date('2030-01-01T05:00:00.000Z');
const hariIni = new Date('2030-01-01T00:00:00.000Z');

function kandidatWalkIn(id: string, urutan: number, checkIn: string) {
  return {
    id,
    layananId,
    tanggalAntrean: hariIni,
    nomorUrut: urutan,
    status: StatusTiket.MENUNGGU,
    versi: 1,
    loketId: null,
    urutanMasukAntrean: urutan,
    masukAntreanPada: new Date(checkIn),
    checkInPada: new Date(checkIn),
    peristiwaAntrean: [],
    janjiTemu: null,
  };
}

function tiket(mode: ModeReservasi, janjiTemu: { id: string } | null) {
  return {
    id: 'tiket-saya',
    layananId,
    status: StatusTiket.MENUNGGU,
    tanggalAntrean: hariIni,
    checkInPada: new Date('2030-01-01T03:00:00.000Z'),
    urutanMasukAntrean: 3,
    janjiTemu,
    layanan: {
      id: layananId,
      kode: 'KIA',
      nama: 'Poli KIA',
      prefixAntrean: 'K',
      modeReservasi: mode,
      aktif: true,
    },
    loket: null,
  };
}

describe('TiketService.dispatch: posisi antrean', () => {
  const findFirst = jest.fn();
  const findMany = jest.fn();
  const count = jest.fn();
  const jadwalFindUnique = jest.fn();
  const loketFindFirst = jest.fn();
  const tx = {
    tiketAntrean: { findFirst, findMany, count },
    jadwalLayanan: { findUnique: jadwalFindUnique },
    loket: { findFirst: loketFindFirst },
  };
  const prisma = {
    $transaction: (callback: (t: typeof tx) => unknown) => callback(tx),
  } as unknown as PrismaService;
  const service = new TiketService({} as ReservasiService, prisma);

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(sekarang);
    jest.clearAllMocks();
    jadwalFindUnique.mockResolvedValue({ aktif: true });
    loketFindFirst.mockResolvedValue({ id: 'loket-1' });
  });
  afterEach(() => jest.useRealTimers());

  it('walk-in poli HIBRIDA mendapat posisi dari urutan selector', async () => {
    findFirst.mockResolvedValue(tiket(ModeReservasi.HIBRIDA, null));
    findMany
      .mockResolvedValueOnce([]) // sedang dilayani
      .mockResolvedValueOnce([
        kandidatWalkIn('a', 1, '2030-01-01T02:50:00.000Z'),
        kandidatWalkIn('b', 2, '2030-01-01T02:55:00.000Z'),
        kandidatWalkIn('tiket-saya', 3, '2030-01-01T03:00:00.000Z'),
        kandidatWalkIn('d', 4, '2030-01-01T03:05:00.000Z'),
      ]);
    const hasil = await service.dispatch('tiket-saya', penggunaId);
    expect(hasil.posisiAntrean).toBe(3);
    expect(hasil.jumlahDiDepan).toBe(2);
    expect(hasil.alasanPosisi).toBeNull();
    expect(count).not.toHaveBeenCalled();
  });

  it('janji temu pada poli HIBRIDA tetap tanpa angka posisi', async () => {
    findFirst.mockResolvedValue(
      tiket(ModeReservasi.HIBRIDA, { id: 'janji-1' }),
    );
    findMany.mockResolvedValue([]);
    const hasil = await service.dispatch('tiket-saya', penggunaId);
    expect(hasil.posisiAntrean).toBeNull();
    expect(hasil.jumlahDiDepan).toBeNull();
    expect(hasil.alasanPosisi).toBe('MODE_ANTREAN_BELUM_DIDUKUNG');
  });

  it('poli JANJI_TEMU_DOKTER tetap tanpa angka posisi', async () => {
    findFirst.mockResolvedValue(tiket(ModeReservasi.JANJI_TEMU_DOKTER, null));
    findMany.mockResolvedValue([]);
    const hasil = await service.dispatch('tiket-saya', penggunaId);
    expect(hasil.posisiAntrean).toBeNull();
    expect(hasil.alasanPosisi).toBe('MODE_ANTREAN_BELUM_DIDUKUNG');
  });

  it('ANTREAN_HARIAN tetap memakai hitungan FIFO lama', async () => {
    findFirst.mockResolvedValue(tiket(ModeReservasi.ANTREAN_HARIAN, null));
    findMany.mockResolvedValue([]);
    count.mockResolvedValue(4);
    const hasil = await service.dispatch('tiket-saya', penggunaId);
    expect(hasil.posisiAntrean).toBe(5);
    expect(hasil.jumlahDiDepan).toBe(4);
    expect(count).toHaveBeenCalledTimes(1);
  });

  it('tanpa loket bertugas, posisi walk-in HIBRIDA tidak dihitung', async () => {
    findFirst.mockResolvedValue(tiket(ModeReservasi.HIBRIDA, null));
    findMany.mockResolvedValue([]);
    loketFindFirst.mockResolvedValue(null);
    const hasil = await service.dispatch('tiket-saya', penggunaId);
    expect(hasil.posisiAntrean).toBeNull();
    expect(hasil.alasanPosisi).toBe('LOKET_PELAYANAN_BELUM_TERSEDIA');
  });
});
