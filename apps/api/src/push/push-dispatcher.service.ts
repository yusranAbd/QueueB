import { Injectable, Logger } from '@nestjs/common';
import type { OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { FcmClient } from './fcm.client';

export const INTERVAL_DISPATCH_PUSH_MS = 2_000;
export const BATAS_BATCH_PUSH = 100;

interface BarisKlaim {
  id: string;
  penggunaId: string;
  tiketAntreanId: string | null;
  jenis: string;
  judul: string;
  pesan: string;
  basi: boolean;
}

/**
 * Menyalin notifikasi baru menjadi push FCM.
 *
 * Baris diklaim dengan `FOR UPDATE SKIP LOCKED` dan langsung ditandai
 * `push_diproses_pada`, sehingga aman untuk beberapa instance API dan setiap
 * notifikasi dikirim paling banyak sekali. Inbox tetap sumber kebenaran;
 * push yang gagal tidak diulang. Notifikasi berumur lebih dari 10 menit, atau
 * yang muncul saat FCM nonaktif, hanya ditandai tanpa dikirim.
 */
@Injectable()
export class PushDispatcherService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PushDispatcherService.name);
  private jadwal?: ReturnType<typeof setInterval>;
  private berjalan?: Promise<number>;

  constructor(
    private readonly prisma: PrismaService,
    private readonly fcm: FcmClient,
  ) {}

  onModuleInit(): void {
    this.jadwal = setInterval(() => this.picu(), INTERVAL_DISPATCH_PUSH_MS);
    this.jadwal.unref?.();
  }

  onModuleDestroy(): void {
    if (this.jadwal) {
      clearInterval(this.jadwal);
      this.jadwal = undefined;
    }
  }

  private picu(): void {
    if (this.berjalan) return;
    const tracked = this.prosesSekali().finally(() => {
      if (this.berjalan === tracked) this.berjalan = undefined;
    });
    this.berjalan = tracked;
    void tracked
      .then((jumlah) => {
        // Backlog penuh: lanjutkan segera tanpa menunggu interval berikutnya.
        if (jumlah >= BATAS_BATCH_PUSH && this.jadwal) this.picu();
      })
      .catch((error: unknown) => {
        this.logger.error('Dispatch push notifikasi gagal', error);
      });
  }

  /** Memproses satu batch; mengembalikan jumlah baris yang diklaim. */
  async prosesSekali(): Promise<number> {
    const rows = await this.prisma.$queryRaw<BarisKlaim[]>`
      UPDATE notifikasi n
         SET push_diproses_pada = clock_timestamp()
       WHERE n.id IN (
         SELECT id FROM notifikasi
          WHERE push_diproses_pada IS NULL
          ORDER BY dibuat_pada, id
          LIMIT ${BATAS_BATCH_PUSH}
          FOR UPDATE SKIP LOCKED
       )
      RETURNING n.id,
                n.pengguna_id AS "penggunaId",
                n.tiket_antrean_id AS "tiketAntreanId",
                n.jenis::text AS jenis,
                n.judul,
                n.pesan,
                (n.dibuat_pada < clock_timestamp() - interval '10 minutes') AS basi`;
    if (rows.length === 0 || !this.fcm.aktif) return rows.length;

    const segar = rows.filter((row) => !row.basi);
    if (segar.length === 0) return rows.length;

    const perangkat = await this.prisma.perangkatPush.findMany({
      where: {
        penggunaId: { in: [...new Set(segar.map((row) => row.penggunaId))] },
        pengguna: { aktif: true },
        sesiPengguna: {
          dicabutPada: null,
          kedaluwarsaPada: { gt: new Date() },
        },
      },
      select: { token: true, penggunaId: true },
    });
    const tokenPerPengguna = new Map<string, string[]>();
    for (const { token, penggunaId } of perangkat) {
      tokenPerPengguna.set(penggunaId, [
        ...(tokenPerPengguna.get(penggunaId) ?? []),
        token,
      ]);
    }

    const tokenTidakValid = new Set<string>();
    for (const row of segar) {
      const tokens = tokenPerPengguna.get(row.penggunaId);
      if (!tokens?.length) continue;
      try {
        const hasil = await this.fcm.kirim(tokens, {
          judul: row.judul,
          pesan: row.pesan,
          data: {
            notifikasiId: row.id,
            tiketAntreanId: row.tiketAntreanId ?? '',
            jenis: row.jenis,
          },
        });
        hasil.tokenTidakValid.forEach((token) => tokenTidakValid.add(token));
      } catch (error) {
        this.logger.warn(
          `Push notifikasi ${row.id} gagal dikirim: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
    if (tokenTidakValid.size > 0) {
      await this.prisma.perangkatPush.deleteMany({
        where: { token: { in: [...tokenTidakValid] } },
      });
    }
    return rows.length;
  }
}
