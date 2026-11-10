import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  NotFoundException,
} from '@nestjs/common';
import { StatusTiket } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CheckInService } from './check-in.service';

const petugas = '22222222-2222-4222-8222-222222222222';
const loketId = '11111111-1111-4111-8111-111111111111';
const layananId = '44444444-4444-4444-8444-444444444444';
const tiketId = '33333333-3333-4333-8333-333333333333';
// 12:00 WIB pada 2030-01-01 (Selasa).
const sekarang = new Date('2030-01-01T05:00:00.000Z');

const tiket = {
  id: tiketId,
  layananId,
  tanggalAntrean: new Date('2030-01-01T00:00:00.000Z'),
  nomorUrut: 25,
  status: StatusTiket.DIPESAN,
  versi: 3,
  checkInPada: null as Date | null,
  janjiTemu: null,
  pengguna: { nama: 'Budi Santoso Wijaya' },
  layanan: {
    nama: 'Poli Umum',
    aktif: true,
    prefixAntrean: 'A',
    modeReservasi: 'ANTREAN_HARIAN',
  },
};
const penugasan = {
  id: 'penugasan-1',
  loket: { aktif: true, layananId, layanan: { aktif: true } },
};
const jadwal = {
  aktif: true,
  jamBuka: new Date('1970-01-01T08:00:00.000Z'),
  jamTutup: new Date('1970-01-01T16:00:00.000Z'),
};

describe('Pencarian dan check-in manual berdasarkan nomor antrean', () => {
  const tiketFindFirst = jest.fn();
  const tiketFindUnique = jest.fn();
  const tiketUpdateMany = jest.fn();
  const peristiwaCreate = jest.fn();
  const penugasanFindFirst = jest.fn();
  const jadwalFindUnique = jest.fn();
  const db = {
    tiketAntrean: {
      findFirst: tiketFindFirst,
      findUnique: tiketFindUnique,
      updateMany: tiketUpdateMany,
    },
    peristiwaAntrean: { create: peristiwaCreate },
    penugasanPetugas: { findFirst: penugasanFindFirst },
    jadwalLayanan: { findUnique: jadwalFindUnique },
  };
  const service = new CheckInService(db as unknown as PrismaService);
  const manual = { tiketId, loketId };

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(sekarang);
    jest.clearAllMocks();
    tiketFindFirst.mockResolvedValue(tiket);
    tiketFindUnique.mockResolvedValue(tiket);
    tiketUpdateMany.mockResolvedValue({ count: 1 });
    penugasanFindFirst.mockResolvedValue(penugasan);
    jadwalFindUnique.mockResolvedValue(jadwal);
  });
  afterEach(() => jest.useRealTimers());

  describe('cariTiketNomor (read-only)', () => {
    it('menemukan tiket, menyamarkan nama, tanpa menulis ke DB', async () => {
      const hasil = await service.cariTiketNomor(
        { nomorAntrean: 'a-025', loketId },
        petugas,
      );
      expect(hasil).toMatchObject({
        tiketId,
        nomorAntrean: 'A-025',
        status: StatusTiket.DIPESAN,
        namaPasien: 'Budi S. W.',
        dapatCheckInManual: true,
        alasan: null,
      });
      expect(tiketFindFirst).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ layananId, nomorUrut: 25 }),
        }),
      );
      expect(tiketUpdateMany).not.toHaveBeenCalled();
      expect(peristiwaCreate).not.toHaveBeenCalled();
      expect(JSON.stringify(hasil)).not.toContain('Santoso');
    });

    it('menolak format nomor yang tidak valid', async () => {
      await expect(
        service.cariTiketNomor({ nomorAntrean: '025', loketId }, petugas),
      ).rejects.toBeInstanceOf(BadRequestException);
      expect(tiketFindFirst).not.toHaveBeenCalled();
    });

    it('menolak petugas tanpa penugasan aktif di loket itu', async () => {
      penugasanFindFirst.mockResolvedValue(null);
      await expect(
        service.cariTiketNomor({ nomorAntrean: 'A-025', loketId }, petugas),
      ).rejects.toBeInstanceOf(ForbiddenException);
      expect(tiketFindFirst).not.toHaveBeenCalled();
    });

    it('tidak menemukan tiket bila prefix tidak cocok dengan layanan loket', async () => {
      await expect(
        service.cariTiketNomor({ nomorAntrean: 'B-025', loketId }, petugas),
      ).rejects.toBeInstanceOf(NotFoundException);
    });

    it('menandai tiket yang sudah check-in tidak dapat di-check-in lagi', async () => {
      tiketFindFirst.mockResolvedValue({
        ...tiket,
        status: StatusTiket.MENUNGGU,
      });
      const hasil = await service.cariTiketNomor(
        { nomorAntrean: 'A-025', loketId },
        petugas,
      );
      expect(hasil.dapatCheckInManual).toBe(false);
      expect(hasil.alasan).toBe('Pasien sudah check-in');
    });

    it('menandai di luar jam pelayanan', async () => {
      jadwalFindUnique.mockResolvedValue({
        ...jadwal,
        jamBuka: new Date('1970-01-01T13:00:00.000Z'),
      });
      const hasil = await service.cariTiketNomor(
        { nomorAntrean: 'A-025', loketId },
        petugas,
      );
      expect(hasil.dapatCheckInManual).toBe(false);
      expect(hasil.alasan).toBe('Check-in berada di luar jam pelayanan');
    });
  });

  describe('checkInManualDalamTransaksi', () => {
    const jalankan = () =>
      service.checkInManualDalamTransaksi(
        db as never,
        manual,
        petugas,
        sekarang,
      );

    it('mengubah DIPESAN menjadi CHECK_IN, mencabut token, dan mencatat audit manual', async () => {
      const hasil = await jalankan();
      expect(hasil).toMatchObject({
        tiketId,
        nomorAntrean: 'A-025',
        status: StatusTiket.CHECK_IN,
        loketId,
        petugasId: petugas,
      });
      expect(tiketUpdateMany).toHaveBeenCalledWith({
        where: {
          id: tiketId,
          status: StatusTiket.DIPESAN,
          versi: 3,
          checkInPada: null,
        },
        data: expect.objectContaining({
          status: StatusTiket.CHECK_IN,
          tokenQrHash: null,
          qrKedaluwarsaPada: null,
        }),
      });
      expect(peristiwaCreate).toHaveBeenCalledWith({
        data: expect.objectContaining({
          tiketAntreanId: tiketId,
          aktorId: petugas,
          dataTambahan: expect.objectContaining({
            metode: 'MANUAL_NOMOR_ANTREAN',
          }),
        }),
      });
    });

    it('menolak tiket dari layanan lain', async () => {
      tiketFindUnique.mockResolvedValue({
        ...tiket,
        layananId: 'layanan-lain',
      });
      await expect(jalankan()).rejects.toBeInstanceOf(ForbiddenException);
      expect(tiketUpdateMany).not.toHaveBeenCalled();
    });

    it('menolak tiket bukan hari pelayanan', async () => {
      tiketFindUnique.mockResolvedValue({
        ...tiket,
        tanggalAntrean: new Date('2030-01-02T00:00:00.000Z'),
      });
      await expect(jalankan()).rejects.toBeInstanceOf(BadRequestException);
      expect(tiketUpdateMany).not.toHaveBeenCalled();
    });

    it('idempoten untuk tiket yang sudah check-in', async () => {
      const lama = new Date('2030-01-01T03:00:00.000Z');
      tiketFindUnique.mockResolvedValue({
        ...tiket,
        status: StatusTiket.CHECK_IN,
        checkInPada: lama,
      });
      const hasil = await jalankan();
      expect(hasil.status).toBe(StatusTiket.CHECK_IN);
      expect(hasil.checkInPada).toBe(lama.toISOString());
      expect(tiketUpdateMany).not.toHaveBeenCalled();
      expect(peristiwaCreate).not.toHaveBeenCalled();
    });

    it('menolak tiket selesai/dibatalkan', async () => {
      tiketFindUnique.mockResolvedValue({
        ...tiket,
        status: StatusTiket.DIBATALKAN,
      });
      await expect(jalankan()).rejects.toBeInstanceOf(ConflictException);
    });

    it('menolak bila update bersyarat kalah balapan', async () => {
      tiketUpdateMany.mockResolvedValue({ count: 0 });
      await expect(jalankan()).rejects.toBeInstanceOf(ConflictException);
      expect(peristiwaCreate).not.toHaveBeenCalled();
    });

    it('menolak di luar jam pelayanan', async () => {
      jadwalFindUnique.mockResolvedValue(null);
      await expect(jalankan()).rejects.toBeInstanceOf(BadRequestException);
      expect(tiketUpdateMany).not.toHaveBeenCalled();
    });
  });
});
