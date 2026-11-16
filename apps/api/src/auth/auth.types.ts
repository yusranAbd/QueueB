import type { PeranPengguna } from '../generated/prisma/client';

export interface AccessTokenPayload {
  sub: string;
  sid: string;
  email: string;
  role: PeranPengguna;
}

export interface RefreshTokenPayload {
  sub: string;
  sid: string;
  type: 'refresh';
  jti: string;
}

export interface AuthenticatedUser {
  id: string;
  nama: string;
  email: string;
  peran: PeranPengguna;
  /** ID sesi_pengguna dari klaim `sid`; diisi oleh JwtStrategy. */
  sesiId?: string;
}
