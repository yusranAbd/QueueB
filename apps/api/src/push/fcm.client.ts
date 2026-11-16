import { Injectable, Logger } from '@nestjs/common';
import type { OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { readFileSync } from 'node:fs';

export interface PesanPush {
  judul: string;
  pesan: string;
  data: Record<string, string>;
}

export interface HasilKirimPush {
  terkirim: number;
  gagal: number;
  /** Token yang ditolak FCM secara permanen; aman dihapus dari database. */
  tokenTidakValid: string[];
}

/** Kanal Android yang dibuat aplikasi klien untuk notifikasi antrean. */
export const KANAL_ANDROID_ANTREAN = 'queueb_antrean';

const KODE_TOKEN_TIDAK_VALID = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

type KirimMulticast = (pesan: {
  tokens: string[];
  notification: { title: string; body: string };
  data: Record<string, string>;
  android: {
    priority: 'high';
    notification: { channelId: string };
  };
}) => Promise<{
  successCount: number;
  failureCount: number;
  responses: Array<{ success: boolean; error?: { code?: string } }>;
}>;

/**
 * Pembungkus Firebase Admin Messaging. Tanpa FIREBASE_SERVICE_ACCOUNT_PATH
 * klien berstatus nonaktif dan firebase-admin tidak dimuat sama sekali.
 */
@Injectable()
export class FcmClient implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(FcmClient.name);
  private kirimMulticast?: KirimMulticast;
  private hapusApp?: () => Promise<void>;

  constructor(private readonly config: ConfigService) {}

  get aktif(): boolean {
    return this.kirimMulticast !== undefined;
  }

  async onModuleInit(): Promise<void> {
    const path = this.config
      .get<string>('FIREBASE_SERVICE_ACCOUNT_PATH')
      ?.trim();
    if (!path) {
      this.logger.log(
        'Push FCM nonaktif: FIREBASE_SERVICE_ACCOUNT_PATH belum diisi',
      );
      return;
    }
    try {
      const serviceAccount = JSON.parse(readFileSync(path, 'utf8')) as Record<
        string,
        string | undefined
      >;
      const { cert, initializeApp, deleteApp } =
        await import('firebase-admin/app');
      const { getMessaging } = await import('firebase-admin/messaging');
      const app = initializeApp(
        { credential: cert(serviceAccount) },
        'queueb-push',
      );
      const messaging = getMessaging(app);
      this.kirimMulticast = (pesan) => messaging.sendEachForMulticast(pesan);
      this.hapusApp = () => deleteApp(app);
      this.logger.log(
        `Push FCM aktif untuk proyek ${serviceAccount.project_id ?? '(tanpa project_id)'}`,
      );
    } catch (error) {
      // Konfigurasi push yang rusak tidak boleh menghentikan layanan antrean.
      this.logger.error(
        'Push FCM nonaktif: service account tidak dapat dimuat',
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  async onModuleDestroy(): Promise<void> {
    const hapus = this.hapusApp;
    this.kirimMulticast = undefined;
    this.hapusApp = undefined;
    await hapus?.().catch(() => undefined);
  }

  async kirim(tokens: string[], pesan: PesanPush): Promise<HasilKirimPush> {
    const kirim = this.kirimMulticast;
    if (!kirim || tokens.length === 0) {
      return { terkirim: 0, gagal: 0, tokenTidakValid: [] };
    }
    const hasil = await kirim({
      tokens,
      notification: { title: pesan.judul, body: pesan.pesan },
      data: pesan.data,
      android: {
        priority: 'high',
        notification: { channelId: KANAL_ANDROID_ANTREAN },
      },
    });
    const tokenTidakValid = hasil.responses.flatMap((respons, index) =>
      !respons.success && KODE_TOKEN_TIDAK_VALID.has(respons.error?.code ?? '')
        ? [tokens[index]]
        : [],
    );
    return {
      terkirim: hasil.successCount,
      gagal: hasil.failureCount,
      tokenTidakValid,
    };
  }
}
