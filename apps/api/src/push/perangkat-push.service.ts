import { Injectable, UnauthorizedException } from '@nestjs/common';
import type { AuthenticatedUser } from '../auth/auth.types';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';

/** Batas token aktif per pengguna; token terlama dihapus lebih dulu. */
export const MAKS_PERANGKAT_PUSH = 5;

@Injectable()
export class PerangkatPushService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Daftarkan token FCM untuk sesi login saat ini. Token yang sama dari akun
   * atau sesi lain dipindahkan, karena satu perangkat hanya memiliki satu
   * penerima aktif.
   */
  async daftar(user: AuthenticatedUser, token: string, platform: 'ANDROID') {
    if (!user.sesiId) throw new UnauthorizedException('Sesi tidak valid');
    const sesiId = user.sesiId;
    const simpan = () =>
      this.prisma.$transaction(async (tx) => {
        await tx.perangkatPush.upsert({
          where: { token },
          create: {
            penggunaId: user.id,
            sesiPenggunaId: sesiId,
            token,
            platform,
          },
          update: {
            penggunaId: user.id,
            sesiPenggunaId: sesiId,
            platform,
            diperbaruiPada: new Date(),
          },
        });
        const kelebihan = await tx.perangkatPush.findMany({
          where: { penggunaId: user.id },
          orderBy: [{ diperbaruiPada: 'desc' }, { id: 'desc' }],
          skip: MAKS_PERANGKAT_PUSH,
          select: { id: true },
        });
        if (kelebihan.length > 0) {
          await tx.perangkatPush.deleteMany({
            where: { id: { in: kelebihan.map((row) => row.id) } },
          });
        }
      });
    try {
      await simpan();
    } catch (error) {
      // Dua pendaftaran token yang sama secara bersamaan: ulangi sekali,
      // kali ini upsert akan menemukan baris yang sudah dibuat.
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2002'
      ) {
        await simpan();
      } else {
        throw error;
      }
    }
    return { terdaftar: true };
  }

  /** Hapus token milik pengguna sendiri. Respons sama walau token tidak ada. */
  async hapus(user: AuthenticatedUser, token: string) {
    await this.prisma.perangkatPush.deleteMany({
      where: { token, penggunaId: user.id },
    });
    return { dihapus: true };
  }
}
