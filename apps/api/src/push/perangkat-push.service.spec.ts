import { UnauthorizedException } from '@nestjs/common';
import type { AuthenticatedUser } from '../auth/auth.types';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  MAKS_PERANGKAT_PUSH,
  PerangkatPushService,
} from './perangkat-push.service';

describe('PerangkatPushService (mock only)', () => {
  const perangkatPush = {
    upsert: jest.fn(),
    findMany: jest.fn(),
    deleteMany: jest.fn(),
  };
  const prisma = {
    perangkatPush,
    $transaction: jest.fn((run: (tx: unknown) => unknown) =>
      run({ perangkatPush }),
    ),
  };
  const service = new PerangkatPushService(prisma as unknown as PrismaService);
  const pasien: AuthenticatedUser = {
    id: 'pasien-a',
    nama: 'Pasien A',
    email: 'a@example.test',
    peran: 'USER',
    sesiId: 'sesi-a',
  };

  beforeEach(() => {
    jest.clearAllMocks();
    perangkatPush.upsert.mockResolvedValue({});
    perangkatPush.findMany.mockResolvedValue([]);
    perangkatPush.deleteMany.mockResolvedValue({ count: 0 });
  });

  it('mendaftarkan token pada pengguna dan sesi JWT, memindahkan pemilik lama', async () => {
    await expect(service.daftar(pasien, 'tok-1', 'ANDROID')).resolves.toEqual({
      terdaftar: true,
    });
    const args = perangkatPush.upsert.mock.calls[0][0];
    expect(args.where).toEqual({ token: 'tok-1' });
    expect(args.create).toMatchObject({
      penggunaId: 'pasien-a',
      sesiPenggunaId: 'sesi-a',
      token: 'tok-1',
      platform: 'ANDROID',
    });
    expect(args.update).toMatchObject({
      penggunaId: 'pasien-a',
      sesiPenggunaId: 'sesi-a',
    });
    expect(perangkatPush.deleteMany).not.toHaveBeenCalled();
  });

  it(`menyisakan paling banyak ${MAKS_PERANGKAT_PUSH} token terbaru per pengguna`, async () => {
    perangkatPush.findMany.mockResolvedValue([
      { id: 'lama-1' },
      { id: 'lama-2' },
    ]);
    await service.daftar(pasien, 'tok-baru', 'ANDROID');
    const cari = perangkatPush.findMany.mock.calls[0][0];
    expect(cari.where).toEqual({ penggunaId: 'pasien-a' });
    expect(cari.skip).toBe(MAKS_PERANGKAT_PUSH);
    expect(cari.orderBy[0]).toEqual({ diperbaruiPada: 'desc' });
    expect(perangkatPush.deleteMany).toHaveBeenCalledWith({
      where: { id: { in: ['lama-1', 'lama-2'] } },
    });
  });

  it('mengulang sekali saat token yang sama didaftarkan bersamaan', async () => {
    perangkatPush.upsert
      .mockRejectedValueOnce(
        new Prisma.PrismaClientKnownRequestError('unik', {
          code: 'P2002',
          clientVersion: 'test',
        }),
      )
      .mockResolvedValueOnce({});
    await expect(service.daftar(pasien, 'tok-1', 'ANDROID')).resolves.toEqual({
      terdaftar: true,
    });
    expect(perangkatPush.upsert).toHaveBeenCalledTimes(2);
  });

  it('menolak pendaftaran tanpa sesi', async () => {
    await expect(
      service.daftar({ ...pasien, sesiId: undefined }, 'tok-1', 'ANDROID'),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    expect(perangkatPush.upsert).not.toHaveBeenCalled();
  });

  it('hanya menghapus token milik pengguna sendiri', async () => {
    await expect(service.hapus(pasien, 'tok-orang-lain')).resolves.toEqual({
      dihapus: true,
    });
    expect(perangkatPush.deleteMany).toHaveBeenCalledWith({
      where: { token: 'tok-orang-lain', penggunaId: 'pasien-a' },
    });
  });
});
