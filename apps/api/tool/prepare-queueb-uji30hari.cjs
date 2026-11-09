'use strict';
/**
 * Bootstrap konfigurasi untuk DB lokal UJI TERPISAH (bukan DB QueueB utama).
 * Target DB dipaksa: capstone_antrean_uji30hari.
 * Dipakai bersama import-queueb-30hari.cjs. Tidak menghapus data.
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomBytes, randomUUID } = require('node:crypto');
const { Client } = require('pg');
const bcrypt = require('bcryptjs');
const dotenv = require('dotenv');
const ROOT = path.resolve(__dirname, '..');
for (const file of [path.join(ROOT, '.env'), path.join(ROOT, '..', '..', '.env')]) {
  if (fs.existsSync(file)) dotenv.config({ path: file, quiet: true });
}
const DB_NAME = 'capstone_antrean_uji30hari';
const MODE = process.argv[2] || 'preview';
const CONFIRM = '--confirm=SIAPKAN-DB-UJI30';
const tables = ['pengguna','layanan','loket','jadwal_layanan','dokter','dokter_layanan','jadwal_praktik','slot_praktik','tiket_antrean','urutan_antrean_harian','janji_temu','peristiwa_antrean'];
const layanan = [
  {kode:'PU01',nama:'Poli Umum',kategori:'POLIKLINIK',mode:'HIBRIDA',prefix:'U',buka:'08:00',tutup:'16:00',durasi:15},
  {kode:'PG01',nama:'Poli Gigi',kategori:'POLIKLINIK',mode:'JANJI_TEMU_DOKTER',prefix:'G',buka:'08:00',tutup:'18:00',durasi:20},
  {kode:'APT01',nama:'Apotek',kategori:'APOTEK',mode:'ANTREAN_HARIAN',prefix:'AP',buka:'08:00',tutup:'16:00',durasi:10},
];
const rooms = [
  {kode:'RU01', nama:'Ruang Periksa Umum', lokasi:'Lantai 1',layanan:'PU01'},
  {kode:'RG01', nama:'Ruang Periksa Gigi 1', lokasi:'Lantai 1',layanan:'PG01'},
  {kode:'RG02', nama:'Ruang Periksa Gigi 2', lokasi:'Lantai 1',layanan:'PG01'},
  {kode:'FA01', nama:'Loket Pengambilan Obat', lokasi:'Lantai 1',layanan:'APT01'},
];
const doctors = [
  {kode:'DR-PU01',nama:'dr. Nabila Aryani',spesialisasi:'Dokter umum'},
  {kode:'DR-PU02',nama:'dr. Rafi Mahendra',spesialisasi:'Dokter umum'},
  {kode:'DR-PG01',nama:'drg. Fadli Pranata',spesialisasi:'Dokter Gigi'},
  {kode:'DR-PG02',nama:'drg. Intan Pertiwi',spesialisasi:'Dokter Gigi'},
];
const hari = ['SENIN','SELASA','RABU','KAMIS','JUMAT','SABTU','MINGGU'];
const one = async (db,sql,p=[]) => (await db.query(sql,p)).rows[0];
async function auditEmpty(db) {
  const found = [];
  for (const table of tables) {
    const name = await one(db,'SELECT to_regclass($1) AS reg',['public.'+table]);
    if (!name?.reg) throw Error(`Tabel ${table} belum ada. Jalankan npx prisma migrate deploy dengan DATABASE_URL menuju ${DB_NAME} terlebih dahulu.`);
    const row = await one(db,`SELECT COUNT(*)::integer AS n FROM ${table}`);
    found.push([table,row.n]);
  }
  return found;
}
async function doApply(db) {
  if (!process.argv.includes(CONFIRM)) throw Error('Tambahkan '+CONFIRM+' setelah perintah apply.');
  const credentialsFile = path.join(os.homedir(),'QueueB-private','admin-uji30hari.csv');
  if (fs.existsSync(credentialsFile)) throw Error('File login uji sudah ada: '+credentialsFile+'; jangan ditimpa.');
  await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  let fileWritten=false;
  try {
    await db.query("SET LOCAL lock_timeout = '5000ms'");
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[DB_NAME]);
    const all = await auditEmpty(db);
    if (all.some(([,count])=>count!==0)) throw Error('Database uji tidak kosong; bootstrap ditolak. Rincian: '+JSON.stringify(all.filter(([,n])=>n>0)));
    const byService = {};
    for (const s of layanan) {
      const id = randomUUID();
      await db.query(`INSERT INTO layanan(id,kode,nama,kategori,mode_reservasi,prefix_antrean,durasi_dasar_menit,aktif,dibuat_pada,diperbarui_pada)
        VALUES($1,$2,$3,$4::kategori_layanan,$5::mode_reservasi,$6,$7,true,now(),now())`,
        [id,s.kode,s.nama,s.kategori,s.mode,s.prefix,s.durasi]);
      byService[s.kode]=id;
      for (const day of hari) {
        await db.query(`INSERT INTO jadwal_layanan(id,layanan_id,hari,jam_buka,jam_tutup,kapasitas_harian,aktif,dibuat_pada,diperbarui_pada)
          VALUES($1,$2,$3::hari_layanan,$4::time,$5::time,50,true,now(),now())`,
          [randomUUID(),id,day,s.buka,s.tutup]);
      }
    }
    for (const r of rooms) {
      await db.query(`INSERT INTO loket(id,layanan_id,kode,nama,lokasi,aktif,dibuat_pada,diperbarui_pada)
        VALUES($1,$2,$3,$4,$5,true,now(),now())`,
        [randomUUID(),byService[r.layanan],r.kode,r.nama,r.lokasi]);
    }
    for (const d of doctors) {
      await db.query(`INSERT INTO dokter(id,kode,nama,spesialisasi,aktif,dibuat_pada,diperbarui_pada)
        VALUES($1,$2,$3,$4,true,now(),now())`,
        [randomUUID(),d.kode,d.nama,d.spesialisasi]);
    }
    const email='admin-uji30hari@kliinik.test';
    const pass=randomBytes(24).toString('base64url');
    const hash=await bcrypt.hash(pass,10);
    await db.query(`INSERT INTO pengguna(id,nama,email,kata_sandi_hash,peran,aktif,dibuat_pada,diperbarui_pada)
      VALUES($1,'Admin QueueB Simulasi',$2,$3,'ADMIN'::peran_pengguna,true,now(),now())`,
      [randomUUID(),email,hash]);
    fs.mkdirSync(path.dirname(credentialsFile),{recursive:true,mode:0o700});
    fs.writeFileSync(credentialsFile,`email,password\n${email},${pass}\n`,{flag:'wx',mode:0o600});
    fileWritten=true;
    await db.query('COMMIT');
    console.log('BERHASIL: 3 layanan, 4 loket, 4 dokter, 21 jadwal mingguan, 1 admin demo.');
    console.log('Login admin disimpan privat pada:',credentialsFile);
    console.log('Berikutnya: node .\\tool\\import-queueb-30hari.cjs preview');
  } catch(err) {
    try { await db.query('ROLLBACK'); } catch {}
    if (fileWritten) { try{fs.unlinkSync(credentialsFile);}catch{} }
    throw err;
  }
}
async function main() {
  if (!['preview','apply','verify'].includes(MODE)) throw Error('Mode: preview | apply --confirm=SIAPKAN-DB-UJI30 | verify');
  const raw = process.env.DATABASE_URL;
  if (!raw) throw Error('DATABASE_URL kosong');
  const url = new URL(raw);
  if (!['127.0.0.1','localhost','::1','[::1]'].includes(url.hostname) || decodeURIComponent(url.pathname.slice(1))!==DB_NAME) {
    throw Error(`DITOLAK: hanya boleh ke database lokal bernama ${DB_NAME}. Target sekarang: ${url.hostname}/${decodeURIComponent(url.pathname.slice(1))}`);
  }
  if (process.env.NODE_ENV==='production') throw Error('Tidak boleh NODE_ENV=production.');
  console.log('Target aman:',url.hostname+':'+(url.port||5432)+'/'+DB_NAME);
  const db=new Client({connectionString:raw});
  await db.connect();
  try {
    if (MODE==='apply') await doApply(db);
    else {
      const counts=await auditEmpty(db);
      const nonzero=counts.filter(([,n])=>n);
      console.log(JSON.stringify(counts));
      if (MODE==='preview') console.log(nonzero.length?'PREFLIGHT: database sudah memiliki data. Bootstrap tidak akan dijalankan.':'PREFLIGHT OK: tabel tersedia dan database kosong.');
      else console.log('VERIFIKASI: ',nonzero.length?nonzero:'belum di-bootstrap.');
    }
  } finally { await db.end(); }
}
main().catch(e=>{console.error('GAGAL:',e.message);process.exitCode=1;});
