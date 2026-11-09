import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/configure-app';
import { AuthService } from '../src/auth/auth.service';
import { PasswordService } from '../src/auth/password.service';
import { PrismaService } from '../src/prisma/prisma.service';
import { ReservasiService } from '../src/reservasi/reservasi.service';
import { PeranPengguna } from '../src/generated/prisma/client';

/**
 * Regression P0-1: reset kata sandi DOKTER/PETUGAS oleh ADMIN.
 * Sebelumnya audit_sesi ditulis dengan nilai di luar CHECK constraint
 * (migrasi 20261102) sehingga transaksi selalu rollback (HTTP 500).
 * Hanya berjalan pada 127.0.0.1:5433/capstone_antrean_test; fixture unik dibersihkan.
 */
describe('ADMIN reset kata sandi staf (isolated e2e)', () => {
  let app: INestApplication, db: PrismaService, auth: AuthService;
  const run = randomUUID().slice(0, 8);
  const password = `R0-${randomUUID()}!`;
  const newPassword = 'Baru1234'; // aturan saat ini: tepat 8 karakter
  const users: Record<
    PeranPengguna,
    { id: string; email: string; ref: string }
  > = {} as never;
  const extraUsers: string[] = [];
  const doctors: string[] = [];
  const tokens = {} as Record<PeranPengguna, string>;
  const server = () => app.getHttpServer() as Parameters<typeof request>[0];
  const resetPath = (id: string) =>
    `/api/v1/auth/admin/accounts/${id}/password`;
  const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });
  const allIds = () => [
    ...Object.values(users).map((u) => u.id),
    ...extraUsers,
  ];
  const allRefs = () => Object.values(users).map((u) => u.ref);
  const auditFor = (akunRef: string) =>
    db.auditSesi.findMany({
      where: { akunRef, aktorRef: users.ADMIN.ref, alasan: 'PASSWORD_CHANGED' },
    });

  beforeAll(async () => {
    const target = new URL(process.env.DATABASE_URL ?? 'http://invalid');
    if (
      target.hostname !== '127.0.0.1' ||
      target.port !== '5433' ||
      target.pathname !== '/capstone_antrean_test'
    )
      throw new Error('E2E requires 127.0.0.1:5433/capstone_antrean_test');
    // Scheduler auto-expire tiket (ReservasiService) tidak relevan untuk tes ini
    // dan akan mengubah data DB uji yang bukan fixture.
    jest
      .spyOn(ReservasiService.prototype, 'onModuleInit')
      .mockImplementation(() => undefined);
    const mod = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = mod.createNestApplication();
    configureApp(app);
    await app.init();
    db = app.get(PrismaService);
    auth = app.get(AuthService);
    expect(
      (await db.$queryRaw<{ db: string }[]>`SELECT current_database() AS db`)[0]
        .db,
    ).toBe('capstone_antrean_test');

    const hash = await app.get(PasswordService).hash(password);
    for (const role of Object.values(PeranPengguna)) {
      const u = await db.pengguna.create({
        data: {
          nama: `Reset ${role}`,
          email: `reset-${role.toLowerCase()}-${run}@reset.test`,
          kataSandiHash: hash,
          peran: role,
        },
      });
      users[role] = { id: u.id, email: u.email, ref: u.auditRef };
      if (role === 'DOKTER') {
        const d = await db.dokter.create({
          data: { kode: `RS${run}`, nama: 'Dokter Reset', penggunaId: u.id },
        });
        doctors.push(d.id);
      }
      tokens[role] = (
        await auth.login({ email: u.email, kataSandi: password })
      ).accessToken;
    }
  });

  afterAll(async () => {
    if (db) {
      const refs = allRefs();
      // Penolakan refresh pada sesi yang dicabut hanya mencatat sesiRef.
      const sesiRefs = (
        await db.sesiPengguna.findMany({
          where: { penggunaId: { in: allIds() } },
          select: { auditRef: true },
        })
      ).map((s) => s.auditRef);
      await db.auditSesi.deleteMany({
        where: {
          OR: [
            { akunRef: { in: refs } },
            { aktorRef: { in: refs } },
            { sesiRef: { in: sesiRefs } },
          ],
        },
      });
      await db.dokter.deleteMany({ where: { id: { in: doctors } } });
      await db.sesiPengguna.deleteMany({
        where: { penggunaId: { in: allIds() } },
      });
      await db.pengguna.deleteMany({ where: { id: { in: allIds() } } });
    }
    jest.restoreAllMocks();
    await app?.close();
  });

  it('mewajibkan JWT dan peran ADMIN', async () => {
    const target = users.PETUGAS.id;
    const before = await db.pengguna.findUniqueOrThrow({
      where: { id: target },
    });
    await request(server())
      .patch(resetPath(target))
      .send({ kataSandiBaru: newPassword })
      .expect(401);
    for (const role of ['USER', 'PETUGAS', 'DOKTER'] as const) {
      await request(server())
        .patch(resetPath(target))
        .set(bearer(tokens[role]))
        .send({ kataSandiBaru: newPassword })
        .expect(403);
    }
    const after = await db.pengguna.findUniqueOrThrow({
      where: { id: target },
    });
    expect(after.kataSandiHash).toBe(before.kataSandiHash);
    expect(await auditFor(users.PETUGAS.ref)).toHaveLength(0);
  });

  it('menolak target tidak sah dan sandi bukan 8 karakter tanpa efek samping', async () => {
    const petugas = users.PETUGAS;
    const sesiAktif = () =>
      db.sesiPengguna.count({
        where: { penggunaId: petugas.id, dicabutPada: null },
      });
    const sesiAwal = await sesiAktif();
    await request(server())
      .patch(resetPath(petugas.id))
      .set(bearer(tokens.ADMIN))
      .send({ kataSandiBaru: 'Pendek1' })
      .expect(400);
    await request(server())
      .patch(resetPath(users.USER.id))
      .set(bearer(tokens.ADMIN))
      .send({ kataSandiBaru: newPassword })
      .expect(404);
    await request(server())
      .patch(resetPath(users.ADMIN.id))
      .set(bearer(tokens.ADMIN))
      .send({ kataSandiBaru: newPassword })
      .expect(403);
    expect(await sesiAktif()).toBe(sesiAwal);
    expect(await auditFor(petugas.ref)).toHaveLength(0);
    expect(await auditFor(users.USER.ref)).toHaveLength(0);
  });

  it('mereset sandi PETUGAS, mencabut semua sesi, dan mencatat audit dalam transaksi', async () => {
    const petugas = users.PETUGAS;
    // Sesi kedua (perangkat lain) harus ikut dicabut.
    const second = await auth.login({
      email: petugas.email,
      kataSandi: password,
    });
    const aktif = await db.sesiPengguna.count({
      where: { penggunaId: petugas.id, dicabutPada: null },
    });
    expect(aktif).toBe(2);

    const res = await request(server())
      .patch(resetPath(petugas.id))
      .set(bearer(tokens.ADMIN))
      .set('x-queueb-client', 'WEB')
      .send({ kataSandiBaru: newPassword })
      .expect(200);
    expect(res.body).toEqual({
      message: 'Kata sandi berhasil direset. Pengguna harus login kembali.',
      sessionsRevoked: 2,
    });
    expect(JSON.stringify(res.body)).not.toContain(newPassword);

    // Pencabutan sesi: access token & refresh token lama tidak berlaku.
    expect(
      await db.sesiPengguna.count({
        where: { penggunaId: petugas.id, dicabutPada: null },
      }),
    ).toBe(0);
    await request(server())
      .get('/api/v1/auth/me')
      .set(bearer(tokens.PETUGAS))
      .expect(401);
    await expect(
      auth.refresh({ refreshToken: second.refreshToken }),
    ).rejects.toMatchObject({
      status: 401,
    });

    // Sandi lama ditolak, sandi baru diterima.
    await expect(
      auth.login({ email: petugas.email, kataSandi: password }),
    ).rejects.toMatchObject({ status: 401 });
    const fresh = await auth.login({
      email: petugas.email,
      kataSandi: newPassword,
    });
    expect(fresh.user.id).toBe(petugas.id);

    // Audit: nilai sesuai CHECK constraint dan tanpa kredensial.
    const audit = await auditFor(petugas.ref);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({
      aksi: 'CABUT_SESI',
      hasil: 'BERHASIL',
      alasan: 'PASSWORD_CHANGED',
      klien: 'WEB',
      sumber: 'UNKNOWN',
      jumlahSesi: 2,
    });
    expect(JSON.stringify(audit[0])).not.toContain(newPassword);

    // Audit terlihat oleh ADMIN melalui endpoint audit sesi yang sudah ada.
    // Endpoint audit memakai tanggal UTC (zonaWaktu: 'UTC').
    const today = new Date().toISOString().slice(0, 10);
    const list = await request(server())
      .get('/api/v1/audit-sesi')
      .query({
        mulai: today,
        selesai: today,
        aksi: 'CABUT_SESI',
        akunRef: petugas.ref,
      })
      .set(bearer(tokens.ADMIN))
      .expect(200);
    expect(
      (list.body as { data: { id: string }[] }).data.map((r) => r.id),
    ).toEqual([audit[0].id]);
  });

  it('mereset sandi DOKTER yang bertaut profil', async () => {
    const dokter = users.DOKTER;
    const res = await request(server())
      .patch(resetPath(dokter.id))
      .set(bearer(tokens.ADMIN))
      .send({ kataSandiBaru: newPassword })
      .expect(200);
    expect(res.body.sessionsRevoked).toBe(1);
    await request(server())
      .get('/api/v1/portal-dokter/profil')
      .set(bearer(tokens.DOKTER))
      .expect(401);
    const audit = await auditFor(dokter.ref);
    expect(audit).toHaveLength(1);
    // Tanpa header klien, nilai tetap valid terhadap CHECK.
    expect(audit[0]).toMatchObject({
      aksi: 'CABUT_SESI',
      klien: 'UNKNOWN',
      jumlahSesi: 1,
    });
    await expect(
      auth.login({ email: dokter.email, kataSandi: newPassword }),
    ).resolves.toMatchObject({ user: { id: dokter.id } });
  });
});
