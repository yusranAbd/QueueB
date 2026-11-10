import {
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
} from '@nestjs/common';
import { PeranPengguna, Prisma, StatusTiket } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { RealtimeBroadcastService } from '../realtime/realtime-broadcast.service';
import { CheckInService } from './check-in.service';
import { CheckInManualDto } from './dto/check-in-manual.dto';
import { ProsesCheckInDto } from './dto/proses-check-in.dto';

type LangkahCheckIn = (
  tx: Prisma.TransactionClient,
  sekarang: Date,
) => Promise<{
  tiketId: string;
  layananId: string;
  nomorAntrean: string;
  status: StatusTiket;
  checkInPada: string;
  loketId: string;
  petugasId: string;
}>;

@Injectable()
export class AutoCheckInService {
  private readonly logger = new Logger(AutoCheckInService.name);
  constructor(
    private readonly prisma: PrismaService,
    private readonly checkIn: CheckInService,
    private readonly queue: QueueService,
    private readonly realtime: RealtimeBroadcastService,
  ) {}

  /** Check-in dari QR SQ1, lalu langsung masuk antrean. */
  proses(dto: ProsesCheckInDto, petugasId: string) {
    return this.jalankan(dto.loketId, petugasId, (tx, sekarang) =>
      this.checkIn.prosesDalamTransaksi(tx, dto, petugasId, sekarang, true),
    );
  }

  /** Check-in manual oleh petugas (tanpa QR), lalu langsung masuk antrean. */
  prosesManual(dto: CheckInManualDto, petugasId: string) {
    return this.jalankan(dto.loketId, petugasId, (tx, sekarang) =>
      this.checkIn.checkInManualDalamTransaksi(tx, dto, petugasId, sekarang),
    );
  }

  private async jalankan(
    loketId: string,
    petugasId: string,
    langkahCheckIn: LangkahCheckIn,
  ) {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const hasil = await this.prisma.$transaction(
          async (tx) => {
            const sekarang = new Date();
            const petugas = await tx.pengguna.findUnique({
              where: { id: petugasId },
              select: { aktif: true, peran: true },
            });
            if (!petugas?.aktif || petugas.peran !== PeranPengguna.PETUGAS) {
              throw new ForbiddenException('Pengguna bukan PETUGAS aktif');
            }
            const checkIn = await langkahCheckIn(tx, sekarang);
            const sudahTerdaftar = checkIn.status === StatusTiket.MENUNGGU;
            if (!sudahTerdaftar) {
              await this.queue.masukAntreanDalamTransaksi(
                tx,
                checkIn.tiketId,
                petugasId,
                loketId,
                sekarang,
              );
            }
            const tiket = await tx.tiketAntrean.findUniqueOrThrow({
              where: { id: checkIn.tiketId },
              select: {
                status: true,
                versi: true,
                urutanMasukAntrean: true,
                masukAntreanPada: true,
                pengguna: { select: { nama: true } },
                layanan: { select: { nama: true } },
              },
            });
            return {
              ...checkIn,
              status: tiket.status,
              versi: tiket.versi,
              urutanMasukAntrean: tiket.urutanMasukAntrean,
              masukAntreanPada: tiket.masukAntreanPada?.toISOString() ?? null,
              namaPasien: tiket.pengguna.nama,
              namaPoliklinik: tiket.layanan.nama,
              sudahTerdaftar,
              pesan: sudahTerdaftar
                ? 'Tiket sudah terdaftar dalam antrean.'
                : 'Check-in berhasil. Pasien masuk antrean.',
            };
          },
          {
            isolationLevel: Prisma.TransactionIsolationLevel.Serializable,
            maxWait: 10000,
            timeout: 15000,
          },
        );
        if (!hasil.sudahTerdaftar) {
          try {
            await this.realtime.kirim({
              aksi: 'ENQUEUE',
              tiketId: hasil.tiketId,
              layananId: hasil.layananId,
              nomorAntrean: hasil.nomorAntrean,
              status: hasil.status,
              loketId: hasil.loketId,
              versi: hasil.versi,
              urutanMasukAntrean: hasil.urutanMasukAntrean,
            });
          } catch {
            this.logger.warn(
              'Broadcast ENQUEUE gagal; transaksi check-in otomatis tetap tersimpan',
            );
          }
        }
        return hasil;
      } catch (e) {
        if (
          e instanceof Prisma.PrismaClientKnownRequestError &&
          e.code === 'P2034'
        ) {
          if (attempt < 2) continue;
          throw new ConflictException(
            'Antrean sedang diproses. Pindai ulang atau periksa daftar menunggu.',
          );
        }
        throw e;
      }
    }
    throw new ConflictException('Check-in otomatis belum dapat diproses');
  }
}
