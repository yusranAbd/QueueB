import { IsString, IsUUID, Matches } from 'class-validator';

/** Pencarian tiket hari ini berdasarkan nomor antrean, untuk pasien tanpa QR. */
export class CariTiketNomorDto {
  @IsString()
  @Matches(/^[A-Za-z0-9]{1,5}-\d{1,6}$/, {
    message: 'Format nomor antrean tidak valid (contoh: A-025)',
  })
  nomorAntrean!: string;

  @IsUUID('4', { message: 'loketId harus berupa UUID yang valid' })
  loketId!: string;
}
