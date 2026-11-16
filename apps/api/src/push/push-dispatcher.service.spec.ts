import { PrismaService } from '../prisma/prisma.service';
import type { FcmClient, HasilKirimPush } from './fcm.client';
import { PushDispatcherService } from './push-dispatcher.service';

describe('PushDispatcherService (mock only)', () => {
  const perangkatPush = { findMany: jest.fn(), deleteMany: jest.fn() };
  const prisma = { $queryRaw: jest.fn(), perangkatPush };
  const fcm = {
    aktif: true,
    kirim: jest.fn<Promise<HasilKirimPush>, [string[], unknown]>(),
  };
  const service = new PushDispatcherService(
    prisma as unknown as PrismaService,
    fcm as unknown as FcmClient,
  );
  const baris = (id: string, penggunaId: string, basi = false) => ({
    id,
    penggunaId,
    tiketAntreanId: `tiket-${id}`,
    jenis: 'PEMANGGILAN',
    judul: 'Nomor Anda dipanggil',
    pesan: 'A-001 · Poli Umum. Silakan menuju Ruang 1.',
    basi,
  });

  beforeEach(() => {
    jest.clearAllMocks();
    fcm.aktif = true;
    fcm.kirim.mockResolvedValue({ terkirim: 1, gagal: 0, tokenTidakValid: [] });
    perangkatPush.findMany.mockResolvedValue([]);
    perangkatPush.deleteMany.mockResolvedValue({ count: 0 });
  });

  it('mengklaim baris dengan SKIP LOCKED dan menandainya sebelum mengirim', async () => {
    prisma.$queryRaw.mockResolvedValue([]);
    await expect(service.prosesSekali()).resolves.toBe(0);
    const sql = (prisma.$queryRaw.mock.calls[0][0] as string[]).join('?');
    expect(sql).toContain('SET push_diproses_pada = clock_timestamp()');
    expect(sql).toContain('WHERE push_diproses_pada IS NULL');
    expect(sql).toContain('FOR UPDATE SKIP LOCKED');
    expect(perangkatPush.findMany).not.toHaveBeenCalled();
  });

  it('mengirim ke semua token aktif pemilik notifikasi dengan data tiket', async () => {
    prisma.$queryRaw.mockResolvedValue([baris('n1', 'pasien-a')]);
    perangkatPush.findMany.mockResolvedValue([
      { token: 'tok-hp', penggunaId: 'pasien-a' },
      { token: 'tok-tablet', penggunaId: 'pasien-a' },
    ]);
    await expect(service.prosesSekali()).resolves.toBe(1);

    const filter = perangkatPush.findMany.mock.calls[0][0].where;
    expect(filter.penggunaId).toEqual({ in: ['pasien-a'] });
    expect(filter.pengguna).toEqual({ aktif: true });
    expect(filter.sesiPengguna.dicabutPada).toBeNull();
    expect(filter.sesiPengguna.kedaluwarsaPada.gt).toBeInstanceOf(Date);

    expect(fcm.kirim).toHaveBeenCalledWith(['tok-hp', 'tok-tablet'], {
      judul: 'Nomor Anda dipanggil',
      pesan: 'A-001 · Poli Umum. Silakan menuju Ruang 1.',
      data: {
        notifikasiId: 'n1',
        tiketAntreanId: 'tiket-n1',
        jenis: 'PEMANGGILAN',
      },
    });
  });

  it('tidak mengirim notifikasi basi dan pengguna tanpa token aktif', async () => {
    prisma.$queryRaw.mockResolvedValue([
      baris('basi', 'pasien-a', true),
      baris('n2', 'pasien-tanpa-token'),
    ]);
    await expect(service.prosesSekali()).resolves.toBe(2);
    expect(perangkatPush.findMany.mock.calls[0][0].where.penggunaId).toEqual({
      in: ['pasien-tanpa-token'],
    });
    expect(fcm.kirim).not.toHaveBeenCalled();
  });

  it('saat FCM nonaktif hanya menandai baris tanpa membaca token', async () => {
    fcm.aktif = false;
    prisma.$queryRaw.mockResolvedValue([baris('n1', 'pasien-a')]);
    await expect(service.prosesSekali()).resolves.toBe(1);
    expect(perangkatPush.findMany).not.toHaveBeenCalled();
    expect(fcm.kirim).not.toHaveBeenCalled();
  });

  it('menghapus token yang ditolak permanen dan melanjutkan saat satu kiriman gagal', async () => {
    prisma.$queryRaw.mockResolvedValue([
      baris('n1', 'pasien-a'),
      baris('n2', 'pasien-b'),
    ]);
    perangkatPush.findMany.mockResolvedValue([
      { token: 'tok-a', penggunaId: 'pasien-a' },
      { token: 'tok-b', penggunaId: 'pasien-b' },
    ]);
    fcm.kirim
      .mockRejectedValueOnce(new Error('jaringan'))
      .mockResolvedValueOnce({
        terkirim: 0,
        gagal: 1,
        tokenTidakValid: ['tok-b'],
      });
    await expect(service.prosesSekali()).resolves.toBe(2);
    expect(fcm.kirim).toHaveBeenCalledTimes(2);
    expect(perangkatPush.deleteMany).toHaveBeenCalledWith({
      where: { token: { in: ['tok-b'] } },
    });
  });
});
