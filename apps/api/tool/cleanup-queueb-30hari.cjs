'use strict';
/**
 * QueueB 30 Hari - pembersihan terbatas (PostgreSQL lokal).
 * Preview -> backup -> apply -> verify -> jadwal-preview -> jadwal-apply.
 * Tambahan: sesi-preview -> sesi-apply -> sesi-verify (slot & sesi praktik lama).
 * Tidak menghapus pengguna, dokter, loket, layanan atau jadwal layanan mingguan.
 * Dibuat untuk struktur schema.prisma yang ditinjau 8 November 2026.
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { Client } = require('pg');
const dotenv = require('dotenv');

const ROOT = path.resolve(__dirname, '..');
for (const f of [path.join(ROOT, '.env'), path.join(ROOT, '..', '..', '.env')]) {
  if (fs.existsSync(f)) dotenv.config({ path: f, quiet: true });
}
const DATA_FILE = path.join(__dirname, 'queueb-data-30hari.json');
const MODE = process.argv[2] || 'preview';
const ARGS = process.argv.slice(3);
const flag = (name) => ARGS.find((arg) => arg.startsWith(`${name}=`))?.slice(name.length + 1);
const TARGET_DB = 'capstone_antrean';
const DATA_ID = 'QUEUEB-30HARI-20261107';
const SERVICES = ['PU01', 'PG01', 'APT01'];
const DAYS = ['SENIN', 'SELASA', 'RABU', 'KAMIS', 'JUMAT', 'SABTU', 'MINGGU'];
const EXPECTED = {
  PU01: { open: '08:00', close: '16:00', capacity: 50 },
  PG01: { open: '08:00', close: '18:00', capacity: 50 },
  APT01: { open: '08:00', close: '16:00', capacity: 50 },
};
const CLEAN_CONFIRM = 'HAPUS-TIKET-LAMA-QUEUEB-30HARI';
const SCHEDULE_CONFIRM = 'UBAH-JADWAL-MINGGUAN-QUEUEB-30HARI';
const SESSION_CONFIRM = 'HAPUS-SESI-PRAKTIK-QUEUEB-30HARI';
const fingerprint = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex').slice(0, 24);
const pretty = (value) => new Intl.NumberFormat('id-ID').format(value);
const asDate = (value) => String(value).slice(0, 10);

function dataset() {
  if (!fs.existsSync(DATA_FILE)) {
    throw Error(`Dataset tidak ditemukan: ${DATA_FILE}. Letakkan queueb-data-30hari.json di folder tool.`);
  }
  const raw = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  if (raw.meta?.id !== DATA_ID || raw.meta?.start !== '2026-11-07' || raw.meta?.end !== '2026-12-06'
    || !Array.isArray(raw.tickets) || raw.tickets.length !== 3624) {
    throw Error('Dataset 30 hari tidak cocok dengan versi yang ditinjau. Proses dibatalkan.');
  }
  return raw;
}
function backupReady() {
  const backup = flag('--backup');
  if (!backup) throw Error('Wajib menyebut backup PostgreSQL yang sudah dibuat: --backup="D:\\Backups\\QueueB.backup"');
  const file = path.resolve(backup);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile() || fs.statSync(file).size < 1024
    || !/\.(backup|dump|sql)$/i.test(file)) {
    throw Error('Backup tidak ditemukan / terlalu kecil / format bukan .backup, .dump atau .sql.');
  }
  console.log(`Backup ditemukan: ${file} (${pretty(fs.statSync(file).size)} byte). Isi backup belum dapat diverifikasi otomatis.`);
}
function dbUrl() {
  if (!process.env.DATABASE_URL) throw Error('DATABASE_URL belum tersedia di .env atau terminal.');
  const url = new URL(process.env.DATABASE_URL);
  const name = decodeURIComponent(url.pathname.slice(1));
  if (!['127.0.0.1', 'localhost', '::1', '[::1]'].includes(url.hostname) || name !== TARGET_DB) {
    throw Error(`DITOLAK: skrip hanya untuk PostgreSQL lokal bernama ${TARGET_DB}. Target saat ini: ${url.hostname}/${name}`);
  }
  if (process.env.NODE_ENV === 'production') throw Error('NODE_ENV=production tidak diperbolehkan.');
  console.log(`Database tujuan: ${url.hostname}:${url.port || '5432'}/${name} (kredensial tidak ditampilkan)`);
  return process.env.DATABASE_URL;
}
async function ensureTables(db) {
  for (const name of ['pengguna', 'layanan', 'loket', 'jadwal_layanan', 'tiket_antrean',
    'urutan_antrean_harian', 'peristiwa_antrean', 'notifikasi', 'janji_temu', 'slot_praktik', 'jadwal_praktik', 'dokter_layanan', 'dokter']) {
    const r = await db.query('SELECT to_regclass($1) AS relation', [`public.${name}`]);
    if (!r.rows[0]?.relation) throw Error(`Tabel ${name} belum tersedia. Jangan gunakan skrip pada skema yang berbeda.`);
  }
}
async function collect(db, data) {
  const sv = (await db.query('SELECT id,kode,nama FROM layanan WHERE kode = ANY($1::text[]) ORDER BY kode', [SERVICES])).rows;
  if (sv.length !== SERVICES.length) throw Error('Layanan PU01, PG01, APT01 harus tersedia sebelum pembersihan.');
  const tickets = (await db.query(`
    SELECT t.id, l.kode AS layanan, t.tanggal_antrean::text AS tanggal,
      t.nomor_urut AS nomor, t.kode_tiket AS kode, t.status::text AS status,
      t.versi, t.pengguna_id AS pengguna, u.email,
      EXISTS (SELECT 1 FROM peristiwa_antrean p WHERE p.tiket_antrean_id=t.id
        AND p.data_tambahan->>'dataset'=$4) AS audit_dataset
    FROM tiket_antrean t
    JOIN layanan l ON l.id=t.layanan_id
    JOIN pengguna u ON u.id=t.pengguna_id
    WHERE l.kode=ANY($1::text[])
      AND t.tanggal_antrean BETWEEN $2::date AND $3::date
    ORDER BY l.kode,t.tanggal_antrean,t.nomor_urut,t.id`,
    [SERVICES, data.meta.start, data.meta.end, DATA_ID])).rows;
  const counters = (await db.query(`
    SELECT c.id,l.kode AS layanan,c.tanggal::text AS tanggal,
      c.nomor_terakhir,c.urutan_masuk_terakhir
    FROM urutan_antrean_harian c JOIN layanan l ON l.id=c.layanan_id
    WHERE l.kode=ANY($1::text[]) AND c.tanggal BETWEEN $2::date AND $3::date
    ORDER BY l.kode,c.tanggal,c.id`, [SERVICES, data.meta.start, data.meta.end])).rows;
  const schedules = (await db.query(`
    SELECT j.id,l.kode AS layanan,j.hari::text AS hari,j.jam_buka::text AS buka,
      j.jam_tutup::text AS tutup,j.kapasitas_harian AS kapasitas,j.aktif
    FROM jadwal_layanan j JOIN layanan l ON l.id=j.layanan_id
    WHERE l.kode=ANY($1::text[]) ORDER BY l.kode,j.hari`, [SERVICES])).rows;
  const ids = tickets.map((t) => t.id);
  const count = async (sql, args = [ids]) => Number((await db.query(sql, args)).rows[0].n);
  const children = {
    janjiTemu: await count('SELECT count(*)::int n FROM janji_temu WHERE tiket_id=ANY($1::uuid[])'),
    peristiwa: await count('SELECT count(*)::int n FROM peristiwa_antrean WHERE tiket_antrean_id=ANY($1::uuid[])'),
    notifikasi: await count(`SELECT count(*)::int n FROM notifikasi n WHERE n.tiket_antrean_id=ANY($1::uuid[])
      OR n.peristiwa_antrean_id IN(SELECT p.id FROM peristiwa_antrean p WHERE p.tiket_antrean_id=ANY($1::uuid[]))`),
  };
  const deterministicCodes = new Set(data.tickets.map((t) => `TK${crypto.createHash('sha256')
    .update(`${DATA_ID}|${t.date}|${t.service}|${t.line}|${t.patientId}`)
    .digest('hex').slice(0, 24).toUpperCase()}`));
  const untagged = tickets.filter((t) => !t.audit_dataset && !deterministicCodes.has(t.kode));
  const changed = [];
  for (const code of SERVICES) {
    for (const day of DAYS) {
      const r = schedules.find((x) => x.layanan === code && x.hari === day);
      if (!r) { changed.push({ layanan: code, hari: day, kondisi: 'TIDAK ADA' }); continue; }
      const e = EXPECTED[code];
      if (!r.aktif || r.buka.slice(0, 5) !== e.open || r.tutup.slice(0, 5) !== e.close || Number(r.kapasitas) !== e.capacity) {
        changed.push({ layanan: code, hari: day, kondisi: `${r.buka.slice(0, 5)}-${r.tutup.slice(0, 5)}, kuota ${r.kapasitas}, aktif=${r.aktif}`,
          target: `${e.open}-${e.close}, kuota ${e.capacity}, aktif=true` });
      }
    }
  }
  const signature = fingerprint({ db: TARGET_DB, dataset: DATA_ID,
    services: sv.map((r) => [r.id, r.kode]),
    tickets: tickets.map(({ id, layanan, tanggal, nomor, kode, status, versi, pengguna, audit_dataset }) => [id, layanan, tanggal, nomor, kode, status, versi, pengguna, audit_dataset]),
    counters, schedules, children });
  return { sv, tickets, counters, schedules, children, untagged, changed, signature };
}
function printPlan(plan, data) {
  console.log(`\nCAKUPAN: ${data.meta.start} s.d. ${data.meta.end}, layanan ${SERVICES.join(', ')}`);
  console.log(`Tiket lama: ${pretty(plan.tickets.length)} | Janji temu: ${plan.children.janjiTemu} | Audit: ${plan.children.peristiwa} | Notifikasi: ${plan.children.notifikasi} | Counter: ${plan.counters.length}`);
  for (const code of SERVICES) {
    const rows = plan.tickets.filter((t) => t.layanan === code);
    const byStatus = {};
    for (const t of rows) byStatus[t.status] = (byStatus[t.status] || 0) + 1;
    console.log(`  ${code}: ${rows.length} tiket; status: ${JSON.stringify(byStatus)}`);
  }
  console.log(`Tiket tidak bertanda dataset: ${plan.untagged.length}. Termasuk tiket demo/lama; WAJIB ditinjau sebelum dihapus.`);
  console.log('Contoh tiket yang menjadi sasaran (maksimal 12, tanpa identitas pasien):');
  for (const t of plan.tickets.slice(0, 12)) console.log(`  ${t.layanan} ${asDate(t.tanggal)} #${t.nomor} ${t.status} ${t.kode}`);
  console.log(`Jadwal mingguan tidak cocok: ${plan.changed.length}/21. TIDAK akan diubah oleh perintah cleanup apply.`);
  for (const item of plan.changed) console.log(`  ${item.layanan} ${item.hari}: ${item.kondisi} -> ${item.target || 'atur manual'}`);
  console.log(`\nSIDIK DATA / fingerprint: ${plan.signature}`);
  console.log('PREVIEW: database tidak diubah. Hentikan API dan buat backup sebelum apply.');
}
async function cleanupApply(db, data) {
  backupReady();
  if (flag('--confirm') !== CLEAN_CONFIRM) throw Error(`Konfirmasi wajib --confirm=${CLEAN_CONFIRM}`);
  if (!/^[0-9a-f]{24}$/.test(flag('--fingerprint') || '')) throw Error('Wajib --fingerprint=<SIDIK DATA dari preview terbaru>');
  await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  try {
    await db.query("SET LOCAL lock_timeout='5000ms'");
    await db.query("SET LOCAL statement_timeout='120000ms'");
    // Kunci penulisan pada seluruh tabel transaksi, bukan pada tabel master.
    await db.query(`LOCK TABLE notifikasi, janji_temu, peristiwa_antrean,
      tiket_antrean, urutan_antrean_harian IN SHARE ROW EXCLUSIVE MODE`);
    const plan = await collect(db, data);
    if (plan.signature !== flag('--fingerprint')) throw Error('Sidik data berubah sejak preview. Jalankan preview ulang; tidak ada data dihapus.');
    if (plan.untagged.length && flag('--include-untagged') !== 'YES') {
      throw Error(`${plan.untagged.length} tiket belum bertanda dataset. Untuk menghapus SEMUA tiket tanggal/layanan target secara sadar, tambahkan --include-untagged=YES.`);
    }
    const ids = plan.tickets.map((t) => t.id);
    const deleted = {};
    const del = async (sql, values) => Number((await db.query(sql, values)).rowCount);
    deleted.notifikasi = await del(`DELETE FROM notifikasi n WHERE n.tiket_antrean_id=ANY($1::uuid[])
      OR n.peristiwa_antrean_id IN(SELECT p.id FROM peristiwa_antrean p WHERE p.tiket_antrean_id=ANY($1::uuid[]))`, [ids]);
    deleted.janjiTemu = await del('DELETE FROM janji_temu WHERE tiket_id=ANY($1::uuid[])', [ids]);
    deleted.peristiwa = await del('DELETE FROM peristiwa_antrean WHERE tiket_antrean_id=ANY($1::uuid[])', [ids]);
    deleted.tiket = await del('DELETE FROM tiket_antrean WHERE id=ANY($1::uuid[])', [ids]);
    if (deleted.tiket !== ids.length || deleted.janjiTemu !== plan.children.janjiTemu ||
      deleted.peristiwa !== plan.children.peristiwa || deleted.notifikasi !== plan.children.notifikasi) {
      throw Error('Jumlah penghapusan berbeda dari preview. Semua perubahan dibatalkan (ROLLBACK).');
    }
    // Hanya counter di rentang tanggal & layanan yang bersangkutan; pastikan tidak ada tiket tersisa.
    deleted.counter = await del(`DELETE FROM urutan_antrean_harian c USING layanan l
      WHERE c.layanan_id=l.id AND l.kode=ANY($1::text[])
        AND c.tanggal BETWEEN $2::date AND $3::date
        AND NOT EXISTS(SELECT 1 FROM tiket_antrean t
          WHERE t.layanan_id=c.layanan_id AND t.tanggal_antrean=c.tanggal)`,
      [SERVICES, data.meta.start, data.meta.end]);
    if (deleted.counter !== plan.counters.length) throw Error('Counter masih dirujuk tiket lain. ROLLBACK.');
    await db.query('COMMIT');
    console.log('CLEANUP BERHASIL (commit):', deleted);
    console.log('Akun pasien, dokter, petugas, loket, sesi praktik dan slot TIDAK dihapus.');
    console.log('Selanjutnya jalankan: node .\\tool\\cleanup-queueb-30hari.cjs verify');
  } catch (err) {
    try { await db.query('ROLLBACK'); } catch {}
    throw err;
  }
}
async function jadwalApply(db, data) {
  backupReady();
  if (flag('--confirm') !== SCHEDULE_CONFIRM) throw Error(`Konfirmasi wajib --confirm=${SCHEDULE_CONFIRM}`);
  if (!/^[0-9a-f]{24}$/.test(flag('--fingerprint') || '')) throw Error('Wajib --fingerprint=<SIDIK DATA dari jadwal-preview terbaru>');
  await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  let snapshotPath;
  try {
    await db.query("SET LOCAL lock_timeout='5000ms'");
    await db.query("SET LOCAL statement_timeout='120000ms'");
    await db.query('LOCK TABLE jadwal_layanan, tiket_antrean IN SHARE ROW EXCLUSIVE MODE');
    const plan = await collect(db, data);
    if (plan.signature !== flag('--fingerprint')) throw Error('Sidik data berubah. Jalankan jadwal-preview ulang.');
    if (plan.tickets.length) throw Error('Masih ada tiket lama; jalankan cleanup dan verify lebih dahulu.');
    if (plan.schedules.length !== 21 || plan.changed.some((x) => x.kondisi === 'TIDAK ADA')) {
      throw Error('Jadwal belum lengkap 21 baris. Buat hari operasional yang hilang melalui Admin sebelum mengubah jadwal.');
    }
    if (!plan.changed.length) {
      await db.query('ROLLBACK');
      console.log('Jadwal sudah sesuai dataset. Tidak ada perubahan.');
      return;
    }
    const folder = path.join(os.homedir(), 'QueueB-private');
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
    snapshotPath = path.join(folder, `jadwal-asli-${TARGET_DB}-${Date.now()}.json`);
    fs.writeFileSync(snapshotPath, JSON.stringify({ database: TARGET_DB, dataset: DATA_ID,
      dibuatPada: new Date().toISOString(), jadwalSebelum: plan.schedules }, null, 2), { flag: 'wx', mode: 0o600 });
    let affected = 0;
    for (const r of plan.schedules) {
      const e = EXPECTED[r.layanan];
      const result = await db.query(`UPDATE jadwal_layanan
        SET jam_buka=$2::time, jam_tutup=$3::time, kapasitas_harian=$4,
          aktif=true, diperbarui_pada=now() WHERE id=$1`, [r.id, e.open, e.close, e.capacity]);
      affected += result.rowCount;
    }
    if (affected !== 21) throw Error('Jumlah jadwal yang diperbarui tidak tepat, ROLLBACK.');
    await db.query('COMMIT');
    console.log('JADWAL BERHASIL DISESUAIKAN: 21 hari layanan mingguan.');
    console.log('Salinan konfigurasi sebelumnya:', snapshotPath);
    console.log('PENTING: Jadwal mingguan memengaruhi layanan DI LUAR periode 30 hari. Pulihkan setelah selesai pengujian.');
  } catch (err) {
    try { await db.query('ROLLBACK'); } catch {}
    if (snapshotPath) { try { fs.unlinkSync(snapshotPath); } catch {} }
    throw err;
  }
}
/**
 * Sesi praktik adalah baris jadwal_praktik bertanggal (BUKAN jadwal_layanan
 * mingguan). Cakupan sengaja dibatasi pada 3 layanan dan 30 hari dataset.
 * Semua sesi, termasuk nonaktif, ditampilkan agar tidak ada slot tersisa.
 */
async function collectPracticeSessions(db, data) {
  const sessions = (await db.query(`
    SELECT jp.id, l.kode AS layanan, d.kode AS dokter, lo.kode AS loket,
           jp.tanggal::text AS tanggal, jp.mulai_pada, jp.selesai_pada, jp.aktif
    FROM jadwal_praktik jp
    JOIN dokter_layanan dl ON dl.id = jp.dokter_layanan_id
    JOIN dokter d ON d.id = dl.dokter_id
    JOIN layanan l ON l.id = dl.layanan_id
    JOIN loket lo ON lo.id = jp.loket_id
    WHERE l.kode = ANY($1::text[]) AND jp.tanggal BETWEEN $2::date AND $3::date
    ORDER BY l.kode, jp.tanggal, jp.mulai_pada, jp.id`,
    [SERVICES, data.meta.start, data.meta.end])).rows;
  const existingTickets = (await db.query(`
    SELECT t.id, t.status::text AS status
    FROM tiket_antrean t JOIN layanan l ON l.id=t.layanan_id
    WHERE l.kode=ANY($1::text[]) AND t.tanggal_antrean BETWEEN $2::date AND $3::date
    ORDER BY t.id`, [SERVICES, data.meta.start, data.meta.end])).rows;
  const ids = sessions.map((r) => r.id);
  const slots = (await db.query(`
    SELECT sp.id, sp.jadwal_praktik_id AS sesi_id, sp.mulai_pada,
           sp.selesai_pada, sp.kapasitas, sp.aktif,
           (SELECT count(*)::int FROM janji_temu jt
            WHERE jt.slot_praktik_id = sp.id) AS jumlah_janji
    FROM slot_praktik sp
    WHERE sp.jadwal_praktik_id = ANY($1::uuid[])
    ORDER BY sp.jadwal_praktik_id, sp.mulai_pada, sp.id`, [ids])).rows;
  const bookedSlots = slots.filter((r) => Number(r.jumlah_janji) > 0);
  const serializeDate = (v) => v instanceof Date ? v.toISOString() : String(v);
  const signature = fingerprint({
    db: TARGET_DB, dataset: DATA_ID, cakupan: [data.meta.start, data.meta.end],
    existingTickets: existingTickets.map((r) => [r.id, r.status]),
    sessions: sessions.map((r) => [r.id, r.layanan, r.dokter, r.loket,
      asDate(r.tanggal), serializeDate(r.mulai_pada), serializeDate(r.selesai_pada), r.aktif]),
    slots: slots.map((r) => [r.id, r.sesi_id,
      serializeDate(r.mulai_pada), serializeDate(r.selesai_pada),
      r.kapasitas, r.aktif, Number(r.jumlah_janji)]),
  });
  return { sessions, slots, bookedSlots, existingTickets, signature };
}
function printPracticeSessions(plan, data) {
  console.log(`\nSESI PRAKTIK: ${data.meta.start} s.d. ${data.meta.end}; layanan ${SERVICES.join(', ')}`);
  console.log(`Sesi: ${plan.sessions.length} | Slot: ${plan.slots.length} | Slot dengan janji temu: ${plan.bookedSlots.length} | Tiket dalam periode: ${plan.existingTickets.length}`);
  for (const code of SERVICES) {
    const all = plan.sessions.filter((r) => r.layanan === code);
    const perRoom = {};
    for (const r of all) perRoom[r.loket] = (perRoom[r.loket] || 0) + 1;
    console.log(`  ${code}: ${all.length} sesi, ruang: ${JSON.stringify(perRoom)}`);
  }
  console.log('Contoh sesi yang akan dihapus (maksimal 15):');
  for (const r of plan.sessions.slice(0, 15)) {
    const time = (v) => new Intl.DateTimeFormat('en-GB', {
      timeZone: 'Asia/Jakarta', hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(new Date(v));
    console.log(`  ${r.layanan} ${r.loket} ${r.dokter} ${asDate(r.tanggal)} ${time(r.mulai_pada)}-${time(r.selesai_pada)} aktif=${r.aktif}`);
  }
  if (plan.bookedSlots.length) {
    console.log(`DIBLOKIR: ${plan.bookedSlots.length} slot masih direferensikan janji temu. Tidak boleh dihapus.`);
  }
  if (plan.existingTickets.length) {
    console.log(`DIBLOKIR: ${plan.existingTickets.length} tiket pada periode tersebut; selesaikan data terkait sebelum menghapus sesi.`);
  }
  console.log(`SIDIK SESI / fingerprint: ${plan.signature}`);
  console.log('SESI PREVIEW: tidak mengubah database. Backup baru dan hentikan API sebelum apply.');
  console.log('Jadwal mingguan, dokter, ruang, tiket, akun, dan perangkat TIDAK akan dihapus.');
}
async function practiceApply(db, data) {
  backupReady();
  if (flag('--confirm') !== SESSION_CONFIRM) throw Error(`Konfirmasi wajib --confirm=${SESSION_CONFIRM}`);
  if (!/^[0-9a-f]{24}$/.test(flag('--fingerprint') || '')) {
    throw Error('Wajib --fingerprint=<SIDIK SESI dari sesi-preview terbaru>');
  }
  await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  try {
    await db.query("SET LOCAL lock_timeout='5000ms'");
    await db.query("SET LOCAL statement_timeout='120000ms'");
    // Memblokir insert/update sesi atau booking secara bersamaan hingga COMMIT.
    await db.query(`LOCK TABLE tiket_antrean, janji_temu, slot_praktik, jadwal_praktik
      IN SHARE ROW EXCLUSIVE MODE`);
    const plan = await collectPracticeSessions(db, data);
    if (plan.signature !== flag('--fingerprint')) {
      throw Error('Sidik sesi berubah sejak preview. Jalankan sesi-preview ulang. Tidak ada perubahan DB.');
    }
    if (plan.bookedSlots.length) {
      throw Error(`${plan.bookedSlots.length} slot masih dipakai janji temu. Tidak menghapus sesi/slot apa pun.`);
    }
    if (plan.existingTickets.length) {
      throw Error(`${plan.existingTickets.length} tiket masih ada dalam cakupan periode dan layanan. Hentikan, tinjau transaksi, dan jalankan cleanup tiket bila sesuai.`);
    }
    const slotIds = plan.slots.map((r) => r.id);
    const sessionIds = plan.sessions.map((r) => r.id);
    const deletedSlots = await db.query('DELETE FROM slot_praktik WHERE id = ANY($1::uuid[])', [slotIds]);
    if (deletedSlots.rowCount !== slotIds.length) {
      throw Error('Jumlah slot yang dihapus tidak sama dengan preview. ROLLBACK.');
    }
    const deletedSessions = await db.query('DELETE FROM jadwal_praktik WHERE id = ANY($1::uuid[])', [sessionIds]);
    if (deletedSessions.rowCount !== sessionIds.length) {
      throw Error('Jumlah sesi yang dihapus tidak sama dengan preview. ROLLBACK.');
    }
    await db.query('COMMIT');
    console.log(`SESI CLEANUP BERHASIL: ${deletedSessions.rowCount} sesi praktik, ${deletedSlots.rowCount} slot praktik.`);
    console.log('Jadwal mingguan, profil dokter, relasi dokter-layanan, loket dan tiket dipertahankan.');
    console.log('Selanjutnya: node .\\tool\\cleanup-queueb-30hari.cjs sesi-verify');
  } catch (err) {
    try { await db.query('ROLLBACK'); } catch {}
    throw err;
  }
}

async function main() {
  const valid = ['preview', 'apply', 'verify', 'jadwal-preview', 'jadwal-apply', 'sesi-preview', 'sesi-apply', 'sesi-verify'];
  if (!valid.includes(MODE)) throw Error(`Mode harus salah satu dari: ${valid.join(', ')}`);
  const data = dataset();
  const raw = dbUrl();
  const db = new Client({ connectionString: raw });
  await db.connect();
  try {
    await ensureTables(db);
    if (MODE === 'apply') return await cleanupApply(db, data);
    if (MODE === 'jadwal-apply') return await jadwalApply(db, data);
    if (MODE === 'sesi-apply') return await practiceApply(db, data);
    if (MODE === 'sesi-preview' || MODE === 'sesi-verify') {
      const sessions = await collectPracticeSessions(db, data);
      if (MODE === 'sesi-preview') printPracticeSessions(sessions, data);
      else if (sessions.sessions.length || sessions.slots.length) {
        console.log(`SESI VERIFY GAGAL: masih ada ${sessions.sessions.length} sesi dan ${sessions.slots.length} slot dalam cakupan.`);
        process.exitCode = 2;
      } else console.log('SESI VERIFY OK: 0 sesi dan 0 slot lama dalam cakupan 30 hari.');
      return;
    }
    const plan = await collect(db, data);
    if (MODE === 'preview' || MODE === 'jadwal-preview') {
      printPlan(plan, data);
      if (MODE === 'jadwal-preview') console.log('PERINGATAN: penyesuaian jadwal bersifat GLOBAL per hari dalam seminggu, bukan khusus 30 hari.');
    } else {
      console.log(`Verifikasi cleanup: ${plan.tickets.length} tiket dan ${plan.counters.length} counter masih ada dalam rentang dataset.`);
      console.log(`Jadwal belum cocok: ${plan.changed.length}/21.`);
      if (plan.tickets.length || plan.counters.length) process.exitCode = 2;
      else console.log('VERIFY OK: tiket lama dan counter pada periode uji sudah bersih.');
    }
  } finally { await db.end(); }
}
main().catch((error) => { console.error('QUEUEB CLEANUP GAGAL:', error.message); process.exitCode = 1; });
