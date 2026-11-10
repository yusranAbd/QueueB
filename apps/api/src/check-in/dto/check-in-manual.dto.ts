import { IsUUID } from 'class-validator';

/** Check-in oleh petugas setelah tiket ditemukan lewat nomor antrean. */
export class CheckInManualDto {
  @IsUUID('4', { message: 'tiketId harus berupa UUID yang valid' })
  tiketId!: string;

  @IsUUID('4', { message: 'loketId harus berupa UUID yang valid' })
  loketId!: string;
}
