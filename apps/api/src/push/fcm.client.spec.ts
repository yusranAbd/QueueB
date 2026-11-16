import { ConfigService } from '@nestjs/config';
import { FcmClient, KANAL_ANDROID_ANTREAN } from './fcm.client';

describe('FcmClient (tanpa jaringan)', () => {
  const config = (path?: string) =>
    ({ get: jest.fn(() => path) }) as unknown as ConfigService;

  it('nonaktif tanpa path service account dan tidak mengirim apa pun', async () => {
    const client = new FcmClient(config(undefined));
    await client.onModuleInit();
    expect(client.aktif).toBe(false);
    await expect(
      client.kirim(['tok'], { judul: 'x', pesan: 'y', data: {} }),
    ).resolves.toEqual({ terkirim: 0, gagal: 0, tokenTidakValid: [] });
  });

  it('tetap nonaktif tanpa melempar bila service account rusak', async () => {
    // File ini bukan JSON service account.
    const client = new FcmClient(config(__filename));
    await expect(client.onModuleInit()).resolves.toBeUndefined();
    expect(client.aktif).toBe(false);
  });

  it('memetakan token tidak valid dari respons FCM ke daftar hapus', async () => {
    const client = new FcmClient(config(undefined));
    const kirim = jest.fn().mockResolvedValue({
      successCount: 1,
      failureCount: 2,
      responses: [
        { success: true },
        {
          success: false,
          error: { code: 'messaging/registration-token-not-registered' },
        },
        { success: false, error: { code: 'messaging/internal-error' } },
      ],
    });
    (client as unknown as { kirimMulticast: unknown }).kirimMulticast = kirim;

    await expect(
      client.kirim(['ok', 'mati', 'sementara'], {
        judul: 'Judul',
        pesan: 'Isi',
        data: { notifikasiId: 'n1' },
      }),
    ).resolves.toEqual({ terkirim: 1, gagal: 2, tokenTidakValid: ['mati'] });
    expect(kirim).toHaveBeenCalledWith({
      tokens: ['ok', 'mati', 'sementara'],
      notification: { title: 'Judul', body: 'Isi' },
      data: { notifikasiId: 'n1' },
      android: {
        priority: 'high',
        notification: { channelId: KANAL_ANDROID_ANTREAN },
      },
    });
  });
});
