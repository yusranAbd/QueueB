'use strict';
/**
 * QueueB - data UJI 50% MENUNGGU / 50% DIPESAN untuk HARI INI (WIB).
 * Hanya tiket impor 30 hari, hanya status DIPESAN hari pelayanan sekarang.
 * Tidak mengubah tiket tanggal lampau/mendatang dan status final.
 * Semua perubahan berada dalam transaksi SERIALIZABLE dan memiliki audit simulasi.
 * Mode: preview | apply | verify
 * Dipakai dari apps/api/tool bersama queueb-data-30hari.json.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Client } = require('pg');
const dotenv = require('dotenv');
const ROOT = path.resolve(__dirname, '..');
for (const file of [path.join(ROOT,'.env'), path.join(ROOT,'..','..','.env')]) {
  if (fs.existsSync(file)) dotenv.config({path:file,quiet:true});
}
const dataPath = path.join(__dirname,'queueb-data-30hari.json');
const DATA = JSON.parse(fs.readFileSync(dataPath,'utf8'));
const IDENT = 'QUEUEB-30HARI-20261107';
const SIM = 'QUEUEB-SPLIT-50-50';
const SERVICES = ['APT01','PG01','PU01'];
const MODE = process.argv[2] || 'preview';
const args = process.argv.slice(3);
const arg = name => args.find(s => s.startsWith(`${name}=`))?.slice(name.length+1);
const digest = obj => crypto.createHash('sha256').update(JSON.stringify(obj)).digest('hex').slice(0,24);
const ticketCode = t => 'TK'+crypto.createHash('sha256').update(`${IDENT}|${t.date}|${t.service}|${t.line}|${t.patientId}`).digest('hex').slice(0,24).toUpperCase();
const todayWib = () => {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US',{
    timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'
  }).formatToParts(new Date()).map(p=>[p.type,p.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
};
const dateNow = todayWib();
function secureDbUrl(){
  if(DATA.meta?.id !== IDENT || DATA.tickets?.length !== 3624) throw Error('Dataset tidak cocok.');
  if(!process.env.DATABASE_URL) throw Error('DATABASE_URL tidak ditemukan.');
  const u = new URL(process.env.DATABASE_URL);
  const dbname = decodeURIComponent(u.pathname.slice(1));
  if(!['127.0.0.1','localhost','::1','[::1]'].includes(u.hostname) || dbname!=='capstone_antrean' || process.env.NODE_ENV==='production')
    throw Error('DIBLOKIR: hanya database lokal capstone_antrean, bukan produksi.');
  if(dateNow < DATA.meta.start || dateNow > DATA.meta.end) throw Error(`Tanggal WIB ${dateNow} di luar periode uji. Tidak ada perubahan.`);
  console.log(`Target: ${u.hostname}:${u.port||'5432'}/${dbname}; tanggal WIB ${dateNow}`);
  return process.env.DATABASE_URL;
}
function ensureBackup(){
  const f=arg('--backup');
  if(!f)throw Error('Backup baru setelah impor wajib disertakan, --backup="D:\\...\\.backup"');
  const target=path.resolve(f);
  if(!fs.existsSync(target)||!fs.statSync(target).isFile()||fs.statSync(target).size<1024||! /\.(backup|dump|sql)$/i.test(target))
    throw Error('File backup terbaru tidak ditemukan / invalid.');
  // Pencegahan penggunaan backup yang berasal sebelum impor.
  if(fs.statSync(target).mtimeMs < Date.now()-24*60*60*1000)
    throw Error('Backup lebih dari 24 jam. Buat backup terbaru dahulu.');
  console.log(`Backup terdeteksi: ${target} (${fs.statSync(target).size} bytes). Periksa juga pg_restore --list.`);
}
async function load(db){
  const planned=DATA.tickets.filter(t=>t.date===dateNow&&SERVICES.includes(t.service));
  if(!planned.length) throw Error('Tidak ada tiket pada tanggal ini di dataset.');
  const codes=planned.map(ticketCode);
  const result=await db.query(`
    SELECT t.id,t.kode_tiket,t.status::text AS status,t.versi,t.nomor_urut,
           t.tanggal_antrean::text AS tanggal,t.check_in_pada,t.masuk_antrean_pada,
           t.urutan_masuk_antrean,t.pengguna_id,t.layanan_id,l.kode AS layanan
    FROM tiket_antrean t JOIN layanan l ON l.id=t.layanan_id
    WHERE t.kode_tiket = ANY($1::text[])
    ORDER BY l.kode,t.nomor_urut,t.id`,[codes]);
  if(result.rows.length!==planned.length)throw Error(`Tiket impor hari ini tidak lengkap: ditemukan ${result.rows.length}/${planned.length}.`);
  const rs=result.rows;
  const matched=new Map(planned.map(t=>[ticketCode(t),t]));
  for(const r of rs){
    const source=matched.get(r.kode_tiket);
    if(!source || r.layanan!==source.service || r.tanggal!==source.date)throw Error('Ada tiket impor dengan identitas berubah.');
    if(!['DIPESAN','DIBATALKAN','MENUNGGU'].includes(r.status))throw Error(`Status ${r.status} terdeteksi. Jangan jalankan ketika ada pelayanan aktif.`);
    if(r.status==='DIPESAN' && (r.check_in_pada||r.masuk_antrean_pada||r.urutan_masuk_antrean!==null))
      throw Error(`Tiket ${r.kode_tiket} sudah memiliki data check-in atau urutan. Tidak aman diubah.`);
  }
  const currentWaiting=rs.filter(r=>r.status==='MENUNGGU');
  if(currentWaiting.length){
    // Apabila sudah pernah berhasil, jangan mengalokasikan dua kali.
    const tagged=await db.query(`SELECT count(DISTINCT tiket_antrean_id)::int AS n FROM peristiwa_antrean
      WHERE tiket_antrean_id = ANY($1::uuid[]) AND data_tambahan->>'skenario'=$2 AND tipe='ENQUEUE'`,[currentWaiting.map(r=>r.id),SIM]);
    if(Number(tagged.rows[0].n)!==currentWaiting.length)throw Error('Ada tiket MENUNGGU yang diproses di luar simulasi. Pemeriksaan manual diperlukan.');
  }
  const counters=await db.query(`SELECT l.kode AS layanan,c.id,c.urutan_masuk_terakhir
    FROM urutan_antrean_harian c JOIN layanan l ON l.id=c.layanan_id
    WHERE c.tanggal=$1::date AND l.kode=ANY($2::text[]) ORDER BY l.kode`,[dateNow,SERVICES]);
  if(counters.rows.length!==SERVICES.length)throw Error('Counter layanan hari ini tidak lengkap.');
  // Target 50:50 secara keseluruhan, dibagi proporsional di tiga layanan.
  const booked=rs.filter(r=>r.status==='DIPESAN');
  const waitingCount=currentWaiting.length;
  const total=booked.length+waitingCount;
  const desired=Math.floor(total/2);
  if(waitingCount>desired)throw Error('Jumlah MENUNGGU sudah melebihi target 50%.');
  const byService=SERVICES.map(code=>({code,
    all:rs.filter(r=>r.layanan===code && ['DIPESAN','MENUNGGU'].includes(r.status)),
    booked:booked.filter(r=>r.layanan===code),
    waiting:currentWaiting.filter(r=>r.layanan===code)}));
  // Dasar alokasi floor per layanan. Sisa dibagikan ke layanan dengan jumlah ganjil.
  const targets=Object.fromEntries(byService.map(x=>[x.code,Math.floor(x.all.length/2)]));
  let remainder=desired-Object.values(targets).reduce((a,b)=>a+b,0);
  for(const x of byService.filter(x=>x.all.length%2===1).sort((a,b)=>a.code.localeCompare(b.code))){
    if(remainder<=0)break;
    targets[x.code]++;
    remainder--;
  }
  const selected=[];
  for(const x of byService){
    const needed=targets[x.code]-x.waiting.length;
    if(needed<0||needed>x.booked.length)throw Error(`Alokasi tidak cocok untuk ${x.code}.`);
    // Urutan reservasi sesuai nomor tiket, FIFO tetap ditentukan pada masuk antrean.
    selected.push(...x.booked.slice(0,needed));
  }
  const signature=digest({date:dateNow,ids:rs.map(x=>[x.id,x.status,x.versi,x.urutan_masuk_antrean]),counters:counters.rows,
    selected:selected.map(r=>r.id)});
  return {rs,booked,currentWaiting,counters,byService,targets,selected,total,desired,signature};
}
function printState(s){
  console.log(`Tiket hasil impor hari ini: ${s.rs.length}; status aktif DIPESAN/MENUNGGU: ${s.total}`);
  console.log(`MENUNGGU sekarang: ${s.currentWaiting.length}; DIPESAN sekarang: ${s.booked.length}`);
  for(const x of s.byService){
    const count=s.selected.filter(r=>r.layanan===x.code).length;
    console.log(`  ${x.code}: ${x.waiting.length} MENUNGGU, ${x.booked.length} DIPESAN | akan berubah ${count} => target MENUNGGU ${s.targets[x.code]}`);
  }
  console.log(`TARGET AKHIR: ${s.currentWaiting.length+s.selected.length} MENUNGGU, ${s.booked.length-s.selected.length} DIPESAN`);
  console.log(`SIDIK STATUS / fingerprint: ${s.signature}`);
}
async function change(db,s){
  const counterByCode=new Map(s.counters.rows.map(x=>[x.layanan,x]));
  let changed=0;
  const start=Date.now()-Math.max(60000,s.selected.length*1000);
  // Lakukan per layanan untuk nomor antrean FIFO yang unik.
  for(const code of SERVICES){
    const target=s.selected.filter(r=>r.layanan===code);
    const counter=counterByCode.get(code);
    if(!target.length)continue;
    const max=await db.query(`SELECT COALESCE(MAX(urutan_masuk_antrean),0)::int AS m FROM tiket_antrean
      WHERE layanan_id=$1 AND tanggal_antrean=$2::date`,[target[0].layanan_id,dateNow]);
    let last=Math.max(Number(counter.urutan_masuk_terakhir),Number(max.rows[0].m));
    for(const r of target){
      const checkTime=new Date(start+changed*1000);
      const enterTime=new Date(checkTime.getTime()+100);
      // Mengikuti state machine DIPESAN -> CHECK_IN -> MENUNGGU; kedua langkah hanya simulasi.
      const one=await db.query(`UPDATE tiket_antrean SET status='CHECK_IN'::status_tiket,
          check_in_pada=$2,versi=versi+1,diperbarui_pada=now()
        WHERE id=$1 AND status='DIPESAN'::status_tiket AND urutan_masuk_antrean IS NULL
          AND check_in_pada IS NULL RETURNING id`,[r.id,checkTime]);
      if(one.rowCount!==1)throw Error(`Tiket ${r.kode_tiket} berubah selama impor.`);
      await db.query(`INSERT INTO peristiwa_antrean(id,tiket_antrean_id,tipe,status_sebelum,status_sesudah,data_tambahan,terjadi_pada)
        VALUES($1,$2,'CHECK_IN','DIPESAN'::status_tiket,'CHECK_IN'::status_tiket,$3::jsonb,$4)`,
        [crypto.randomUUID(),r.id,JSON.stringify({simulasi:true,dataset:IDENT,skenario:SIM,catatan:'check-in sintetis hari ini, bukan hasil scan QR'}),checkTime]);
      last++;
      const two=await db.query(`UPDATE tiket_antrean SET status='MENUNGGU'::status_tiket,
          urutan_masuk_antrean=$2,masuk_antrean_pada=$3,versi=versi+1,diperbarui_pada=now()
        WHERE id=$1 AND status='CHECK_IN'::status_tiket AND urutan_masuk_antrean IS NULL RETURNING id`,[r.id,last,enterTime]);
      if(two.rowCount!==1)throw Error(`Tiket ${r.kode_tiket} gagal masuk antrean.`);
      await db.query(`INSERT INTO peristiwa_antrean(id,tiket_antrean_id,tipe,status_sebelum,status_sesudah,data_tambahan,terjadi_pada)
        VALUES($1,$2,'ENQUEUE','CHECK_IN'::status_tiket,'MENUNGGU'::status_tiket,$3::jsonb,$4)`,
        [crypto.randomUUID(),r.id,JSON.stringify({simulasi:true,dataset:IDENT,skenario:SIM,urutanMasukAntrean:last}),enterTime]);
      changed++;
    }
    await db.query(`UPDATE urutan_antrean_harian SET urutan_masuk_terakhir=GREATEST(urutan_masuk_terakhir,$2),
      diperbarui_pada=now() WHERE id=$1`,[counter.id,last]);
  }
  return changed;
}
async function main(){
  const connectionString=secureDbUrl();
  const db=new Client({connectionString});
  await db.connect();
  try{
    if(!['preview','apply','verify'].includes(MODE))throw Error('Mode: preview | apply | verify');
    if(MODE==='apply'){
      if(arg('--confirm')!=='SIMULASI-QUEUEB-50-50')throw Error('Wajib --confirm=SIMULASI-QUEUEB-50-50');
      if(!arg('--fingerprint'))throw Error('Wajib --fingerprint=<dari preview terbaru>');
      ensureBackup();
      await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
      try{
        await db.query("SET LOCAL statement_timeout='300000ms'");
        await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[`${IDENT}|${dateNow}|${SIM}`]);
        const s=await load(db); printState(s);
        if(s.signature!==arg('--fingerprint'))throw Error('Fingerprint tidak cocok. Jalankan preview ulang sebelum apply.');
        if(s.currentWaiting.length!==0)throw Error('Sudah ada antrean MENUNGGU. Jangan jalankan apply ulang.');
        const n=await change(db,s);
        await db.query('COMMIT');
        console.log(`SUKSES: ${n} tiket DIPESAN menjadi MENUNGGU. Hanya hari ini, dan hanya data impor.`);
      }catch(e){await db.query('ROLLBACK');throw e;}
    }else{
      const s=await load(db);printState(s);
      if(MODE==='preview')console.log('PREVIEW: tidak ada data database yang diubah.');
      else console.log(`VERIFY: ${s.currentWaiting.length} MENUNGGU / ${s.booked.length} DIPESAN pada hari ini; ${s.currentWaiting.length===s.desired&&s.selected.length===0?'TARGET 50:50 TERCAPAI':'TARGET BELUM TERCAPAI'}.`);
    }
  }finally{await db.end();}
}
main().catch(err=>{console.error('GAGAL:',err.message);process.exitCode=1;});
