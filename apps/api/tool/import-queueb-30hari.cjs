'use strict';
/**
 * QueueB / dataset pengujian 7 Nov - 6 Des 2026.
 * Simulasi lokal. Tidak melakukan reset, truncate, delete, maupun update tiket lama.
 * Jalankan dari apps/api (lihat README). Dependensi pg, bcryptjs, dotenv sudah ada.
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Client } = require('pg');
const bcrypt = require('bcryptjs');
const dotenv = require('dotenv');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(__dirname, 'queueb-data-30hari.json');
const DATA = JSON.parse(fs.readFileSync(FILE, 'utf8'));
for (const fp of [path.join(ROOT, '.env'), path.join(ROOT, '..', '..', '.env')]) {
  if (fs.existsSync(fp)) dotenv.config({ path: fp, quiet: true });
}
const MODE = process.argv[2] || 'validate';
const ARGS = process.argv.slice(3);
const flag = (k) => ARGS.find(x => x.startsWith(`${k}=`))?.slice(k.length + 1);
const CONFIRM = 'IMPORT-QUEUEB-30HARI';
const expected = {PU01: ['HIBRIDA','U','POLIKLINIK','08:00','16:00'], PG01:['JANJI_TEMU_DOKTER','G','POLIKLINIK','08:00','18:00'], APT01:['ANTREAN_HARIAN','AP','APOTEK','08:00','16:00']};
const serviceKeys = Object.keys(expected);
const doctorRooms = {
  RU01: [{ doctor:'DR-PU01', open:'08:00', close:'12:00' },{doctor:'DR-PU02', open:'12:00', close:'16:00'}],
  RG01: [{ doctor:'DR-PG01', open:'08:00', close:'13:00' },{doctor:'DR-PG01', open:'14:00', close:'18:00'}],
  RG02: [{ doctor:'DR-PG02', open:'08:00', close:'13:00' },{doctor:'DR-PG02', open:'14:00', close:'18:00'}],
};
const doctorService = {'DR-PU01':'PU01','DR-PU02':'PU01','DR-PG01':'PG01','DR-PG02':'PG01'};
const roomService = {RU01:'PU01',RG01:'PG01',RG02:'PG01',FA01:'APT01'};
const zone = 'Asia/Jakarta';
const dateDb = d => d;
const localDate = () => {
  const f = new Intl.DateTimeFormat('en-CA',{ timeZone: zone, year:'numeric',month:'2-digit',day:'2-digit' });
  const p = Object.fromEntries(f.formatToParts(new Date()).map(x=>[x.type,x.value]));
  return `${p.year}-${p.month}-${p.day}`;
};
const utcDay = d => new Date(`${d}T00:00:00.000Z`).getUTCDay();
const days = ['MINGGU','SENIN','SELASA','RABU','KAMIS','JUMAT','SABTU'];
const inst = (d,t) => new Date(`${d}T${t}:00+07:00`);
const dayShift = (d,n) => new Date(Date.parse(`${d}T00:00:00.000Z`) + n*86400000).toISOString().slice(0,10);
const dbDate = value => String(value instanceof Date ? value.toISOString().slice(0,10) : value).slice(0,10);
const qOne = async (client,sql,args=[]) => (await client.query(sql,args)).rows[0] || null;
const uid = () => crypto.randomUUID();
const quoteCsv = str => `"${String(str).replaceAll('"','""')}"`;
const ticketCode = r => 'TK'+crypto.createHash('sha256').update(`${DATA.meta.id}|${r.date}|${r.service}|${r.line}|${r.patientId}`).digest('hex').slice(0,24).toUpperCase();
function validate(){
  if (DATA.meta.id !== 'QUEUEB-30HARI-20261107') throw Error('Dataset salah.');
  if (DATA.patients.length!==540 || DATA.staff.length!==4 || DATA.doctors.length!==4 || DATA.tickets.length!==3624 || DATA.summaryByDate.length!==30) throw Error('Jumlah dataset tidak sesuai dokumen.');
  const pids=new Set(), emails=new Set();
  for (const p of DATA.patients){
    if(!/^P\d{4}$/.test(p.id)||!p.nama||!p.email.endsWith('@kliinik.test')||pids.has(p.id)||emails.has(p.email)) throw Error('Data pasien tidak valid.');
    pids.add(p.id); emails.add(p.email);
  }
  const seen=new Set(), slotSeen=new Set(), totals=new Map();
  for (const t of DATA.tickets){
    const k=`${t.date}|${t.service}|${t.line}`, pk=`${t.date}|${t.service}|${t.patientId}`;
    if(seen.has(k)||seen.has(pk)||!pids.has(t.patientId)||!expected[t.service]||!/^([WA])[1-4]$/.test(t.flow)) throw Error(`Tiket tidak valid: ${k}`);
    seen.add(k); seen.add(pk);
    if(t.service==='PG01'){
      const sk=`${t.date}|${t.room}|${t.time}`;
      if(slotSeen.has(sk)||!['RG01','RG02'].includes(t.room)) throw Error('Benturan slot dokumen '+sk);
      slotSeen.add(sk);
    }
    const dayKey=`${t.date}|${t.service}`;
    totals.set(dayKey,(totals.get(dayKey)||0)+1);
  }
  for(const d of DATA.summaryByDate){
    for(const s of serviceKeys){ if(totals.get(`${d.date}|${s}`)!==d[s]) throw Error('Rekap tidak cocok: '+d.date+' '+s); }
  }
  console.log('Valid: 540 akun, 3.624 tiket, 30 hari; 0 duplikasi pada dokumen.');
  return totals;
}
const sleep = m => new Promise(resolve=>setTimeout(resolve,m));
function statusFor(t,today){
  if(t.flow==='A2') return 'DIBATALKAN';
  if(t.date>=today) return 'DIPESAN';
  if(['W1','W2','A1'].includes(t.flow)) return 'SELESAI';
  return 'DILEWATI';
}
function chronologyFor(t,today,queueNum){
  const status=statusFor(t,today);
  const historical=t.date<today;
  const appointment=t.service==='PG01';
  const arrival=inst(t.date,t.time);
  const checkin=appointment ? new Date(arrival.getTime()-5*60000) : arrival;
  const entered=new Date(checkin.getTime()+10*1000);
  const called=new Date(entered.getTime()+35*1000);
  const started=new Date(called.getTime()+30*1000);
  const finished=new Date(started.getTime()+(appointment?18:7)*60000);
  const skip= new Date(called.getTime()+15*1000);
  const laterCall=new Date(skip.getTime()+80*1000);
  const laterStarted=new Date(laterCall.getTime()+20*1000);
  const laterFinished=new Date(laterStarted.getTime()+7*60000);
  const booked=appointment? inst(dayShift(t.date,-1),'17:00') : new Date(arrival.getTime()-15*60000);
  const reservedOn=booked>new Date()?new Date():booked;
  const events=[{type:'RESERVATION_BOOK',status:'DIPESAN',at:reservedOn}];
  const checkinned=historical&&!['A2','A4'].includes(t.flow);
  if(t.flow==='A2') events.push({type:'CANCEL_APPOINTMENT',status:'DIBATALKAN',at:new Date(reservedOn.getTime()+60000)});
  if(checkinned){
    events.push({type:'CHECK_IN',status:'CHECK_IN',at:checkin},{type:'ENQUEUE',status:'MENUNGGU',at:entered});
    if(['W1','W2','W3','A1'].includes(t.flow)){
      events.push({type:'CALL',status:'DIPANGGIL',at:called});
      if(t.flow==='W2'){
        events.push({type:'SKIP',status:'DILEWATI',at:skip},{type:'REQUEUE',status:'MENUNGGU',at:new Date(skip.getTime()+40000)}, {type:'CALL',status:'DIPANGGIL',at:laterCall}, {type:'START_SERVICE',status:'DILAYANI',at:laterStarted}, {type:'COMPLETE_SERVICE',status:'SELESAI',at:laterFinished});
      }else if(t.flow==='W3') events.push({type:'SKIP',status:'DILEWATI',at:skip});
      else events.push({type:'START_SERVICE',status:'DILAYANI',at:started},{type:'COMPLETE_SERVICE',status:'SELESAI',at:finished});
    } else events.push({type:'AUTO_EXPIRE',status:'DILEWATI',at:inst(dayShift(t.date,1),'00:01')});
  } else if(historical && t.flow==='A4') events.push({type:'AUTO_EXPIRE',status:'DILEWATI',at:inst(dayShift(t.date,1),'00:01')});
  const serviceFinished=historical && ['W1','W2','A1'].includes(t.flow);
  const wasCalled=historical && ['W1','W2','W3','A1'].includes(t.flow);
  const lastStart=t.flow==='W2'?laterStarted:started;
  const lastFinish=t.flow==='W2'?laterFinished:finished;
  return {status,events,bookedAt:reservedOn,checkInAt:checkinned?checkin:null,enteredAt:checkinned?entered:null,calledAt:wasCalled?(t.flow==='W2'?laterCall:called):null,startAt:serviceFinished?lastStart:null,finishAt:serviceFinished?lastFinish:null,queueNum:checkinned?queueNum:null};
}

async function fetchState(db){
  const [sv,rm,dr,js,users,existing,staff] = await Promise.all([
    db.query('SELECT id,kode,nama,kategori,mode_reservasi,prefix_antrean,aktif FROM layanan WHERE kode = ANY($1::text[])',[serviceKeys]),
    db.query('SELECT id,kode,layanan_id,aktif FROM loket WHERE kode = ANY($1::text[])',[Object.keys(roomService)]),
    db.query('SELECT id,kode,nama,aktif FROM dokter WHERE kode = ANY($1::text[])',[Object.keys(doctorService)]),
    db.query('SELECT jl.*,l.kode as layanan_kode FROM jadwal_layanan jl JOIN layanan l ON l.id=jl.layanan_id WHERE l.kode=ANY($1::text[])',[serviceKeys]),
    db.query('SELECT id,nama,email,peran,aktif FROM pengguna WHERE email=ANY($1::text[])',[DATA.patients.map(p=>p.email)]),
    db.query('SELECT t.id,t.kode_tiket,t.nomor_urut,t.urutan_masuk_antrean,t.tanggal_antrean::text as tanggal_antrean,t.status,t.layanan_id,t.pengguna_id, l.kode as layanan_kode,u.email FROM tiket_antrean t JOIN layanan l ON l.id=t.layanan_id JOIN pengguna u ON u.id=t.pengguna_id WHERE l.kode=ANY($1::text[]) AND t.tanggal_antrean >= $2::date AND t.tanggal_antrean <= $3::date',[serviceKeys,DATA.meta.start,DATA.meta.end]),
    db.query("SELECT id,nama,email,peran,aktif FROM pengguna WHERE email LIKE '%@kliinik.test' AND peran='PETUGAS'")
  ]);
  return {services:sv.rows, rooms:rm.rows, doctors:dr.rows, schedules:js.rows, users:users.rows, existing:existing.rows, staff:staff.rows};
}
function stateCheck(s){
  const errors=[];const warnings=[];
  const sm=new Map(s.services.map(x=>[x.kode,x]));const rm=new Map(s.rooms.map(x=>[x.kode,x]));
  const dm=new Map(s.doctors.map(x=>[x.kode,x]));
  for(const [k,[mode,prefix,category]] of Object.entries(expected)){
    const a=sm.get(k);
    if(!a) errors.push(`Layanan ${k} belum ada (siapkan melalui Admin).`);
    else if(!a.aktif||a.mode_reservasi!==mode||a.prefix_antrean.trim()!==prefix||a.kategori!==category) errors.push(`Layanan ${k}: mode/prefix/kategori/status tidak sesuai dokumen.`);
  }
  for(const [k,sname] of Object.entries(roomService)){
    const r=rm.get(k),sv=sm.get(sname);
    if(!r||!r.aktif||r.layanan_id!==sv?.id) errors.push(`Ruang/loket ${k} harus aktif pada ${sname}.`);
  }
  for(const [d,sname] of Object.entries(doctorService)) if(!dm.get(d)?.aktif) errors.push(`Profil dokter ${d} harus tersedia dan aktif (${sname}).`);
  for(const svc of serviceKeys) {
    const a=sm.get(svc);if(!a)continue;
    const byDays=s.schedules.filter(row=>row.layanan_id===a.id);
    for(const day of days){
      const r=byDays.find(v=>v.hari===day);const cfg=expected[svc];
      if(!r) {errors.push(`Jadwal ${svc} ${day} belum diatur.`);continue;}
      const h=t=>t instanceof Date ? t.toISOString().slice(11,16) : String(t).slice(0,5);
      if(!r.aktif||r.kapasitas_harian!==50||h(r.jam_buka)!==cfg[3]||h(r.jam_tutup)!==cfg[4])
        errors.push(`Jadwal ${svc} ${day} belum 08:00-${cfg[4]} / 50 pasien / aktif.`);
    }
  }
  const staffMap=new Map(s.staff.map(r=>[r.email,r]));
  for(const a of DATA.staff){
    const row=staffMap.get(a.email);
    if(row&&(row.nama!==a.nama||row.peran!=='PETUGAS'||!row.aktif))errors.push(`Akun petugas ${a.email} sudah ada dengan profil/status berbeda.`);
  }
  const pu=new Map(s.users.map(r=>[r.email,r]));
  for(const p of DATA.patients){const u=pu.get(p.email);if(u && (u.nama!==p.nama||u.peran!=='USER'||!u.aktif)) errors.push(`Akun email ${p.email} ada tetapi data/perannya berbeda.`);}
  const tmap=new Map(DATA.tickets.map(t=>[ticketCode(t),t]));
  const byDay=new Map(),seedPresent=new Set(), existingPatient=new Set();
  for(const t of s.existing){
    const d=dbDate(t.tanggal_antrean),svc=t.layanan_kode, k=`${d}|${svc}`;
    byDay.set(k,(byDay.get(k)||0)+1);
    const plan=tmap.get(t.kode_tiket);
    if(plan){
      if(plan.service!==svc||plan.date!==d||DATA.patients.find(p=>p.id===plan.patientId)?.email!==t.email) errors.push(`Benturan identitas kode tiket ${t.kode_tiket}`);
      else seedPresent.add(t.kode_tiket);
    }
    existingPatient.add(`${d}|${svc}|${t.email}`);
  }
  for(const t of DATA.tickets){
    if(seedPresent.has(ticketCode(t)))continue;
    const p=DATA.patients[Number(t.patientId.slice(1))-1];
    if(existingPatient.has(`${t.date}|${t.service}|${p.email}`)) errors.push(`Sudah ada tiket pasien ${p.id} pada ${t.date} / ${t.service}.`);
  }
  for(const x of DATA.summaryByDate){
    for(const svc of serviceKeys){
      const newCount=DATA.tickets.filter(t=>t.date===x.date && t.service===svc && !seedPresent.has(ticketCode(t))).length;
      const total=(byDay.get(`${x.date}|${svc}`)||0)+newCount;
      if(total>50) errors.push(`${x.date} ${svc}: ${total} tiket sesudah impor, melewati kuota 50 (sudah ada ${total-newCount}).`);
    }
  }
  if(s.existing.length>0)warnings.push(`Ada ${s.existing.length} tiket pada rentang tanggal dataset; tidak akan diubah.`);
  return {errors:[...new Set(errors)],warnings,sm,rm,dm,seedPresent};
}
async function checkSlotConflicts(db,s,checked){
  // Aplikasi mungkin sudah mempunyai booking slot pada tanggal yang sama.
  const q=await db.query(`SELECT t.kode_tiket,l.kode layanan_kode, t.tanggal_antrean::text as tanggal_antrean,lo.kode room,
     to_char(sp.mulai_pada AT TIME ZONE 'Asia/Jakarta','HH24:MI') jam,
     t.status FROM janji_temu j JOIN tiket_antrean t ON j.tiket_id=t.id
     JOIN layanan l ON t.layanan_id=l.id JOIN slot_praktik sp ON j.slot_praktik_id=sp.id
     JOIN jadwal_praktik jp ON sp.jadwal_praktik_id=jp.id JOIN loket lo ON jp.loket_id=lo.id
     WHERE l.kode='PG01' AND t.tanggal_antrean BETWEEN $1::date AND $2::date
     AND t.status <> 'DIBATALKAN'`,[DATA.meta.start,DATA.meta.end]);
  const planned=new Map(DATA.tickets.filter(t=>t.service==='PG01').map(t=>[`${t.date}|${t.room}|${t.time}`,t]));
  for(const row of q.rows){
    const r=planned.get(`${dbDate(row.tanggal_antrean)}|${row.room}|${row.jam}`);
    if(r && row.kode_tiket!==ticketCode(r))checked.errors.push(`Slot ${r.date} ${r.room} ${r.time} sudah ditempati tiket lain.`);
  }
  checked.errors=[...new Set(checked.errors)];
}
async function preview(db){
  const s=await fetchState(db),check=stateCheck(s);
  await checkSlotConflicts(db,s,check);
  console.log('Pratinjau database:',{existingTickets:s.existing.length,existingPatientAccounts:s.users.length,importedTicketsAlreadyPresent:check.seedPresent.size,missingAccounts:540-s.users.length,newTickets:3624-check.seedPresent.size});
  for(const msg of check.warnings) console.warn('INFO:',msg);
  for(const msg of check.errors.slice(0,35)) console.error('BLOCK:',msg);
  if(check.errors.length>35) console.error(`... dan ${check.errors.length-35} masalah tambahan.`);
  console.log(check.errors.length?`PREVIEW DIBLOKIR: ${check.errors.length} masalah. Tidak ada data diubah.`:'PREVIEW LULUS: Konfigurasi, kuota, dan konflik awal diperiksa; tidak ada perubahan DB.');
  return {s,check};
}
async function ensureDoctorLinks(db, s){
  const links={};
  for(const [doc,svc] of Object.entries(doctorService)){
    const d=s.doctors.find(r=>r.kode===doc),l=s.services.find(r=>r.kode===svc);
    let row=await qOne(db,'SELECT id,aktif FROM dokter_layanan WHERE dokter_id=$1 AND layanan_id=$2',[d.id,l.id]);
    if(!row){const id=uid();await db.query('INSERT INTO dokter_layanan(id,dokter_id,layanan_id,aktif) VALUES($1,$2,$3,true)',[id,d.id,l.id]);row={id,aktif:true};}
    if(!row.aktif)throw Error(`Hubungan dokter ${doc} ke ${svc} nonaktif. Aktifkan dahulu lewat Admin.`);
    links[doc]=row.id;
  }
  return links;
}
async function ensureSessionsAndSlots(db,s,links){
  const roomMap=new Map(s.rooms.map(r=>[r.kode,r]));
  const sessionMap=new Map();const slotMap=new Map();
  for(const day of DATA.summaryByDate){
    for(const [room,sessions] of Object.entries(doctorRooms)){
      for(const sess of sessions){
        const start=inst(day.date,sess.open),end=inst(day.date,sess.close);
        const link=links[sess.doctor],roomId=roomMap.get(room).id;
        let row=await qOne(db,'SELECT id,loket_id,selesai_pada,aktif FROM jadwal_praktik WHERE dokter_layanan_id=$1 AND mulai_pada=$2',[link,start]);
        if(!row){
          const conflict=await qOne(db,'SELECT id FROM jadwal_praktik WHERE loket_id=$1 AND tanggal=$2::date AND aktif=true AND mulai_pada < $4 AND selesai_pada > $3',[roomId,day.date,start,end]);
          if(conflict) throw Error(`Sesi ${day.date} ${room} ${sess.open}-${sess.close} bentrok jadwal praktik lain.`);
          const id=uid();await db.query('INSERT INTO jadwal_praktik(id,dokter_layanan_id,loket_id,tanggal,mulai_pada,selesai_pada,aktif) VALUES($1,$2,$3,$4::date,$5,$6,true)',[id,link,roomId,day.date,start,end]);row={id,loket_id:roomId,selesai_pada:end,aktif:true};
        }
        if(!row.aktif||row.loket_id!==roomId||+new Date(row.selesai_pada)!==+end) throw Error(`Sesi ${day.date} ${room} berbeda dengan dokumen. Tidak ditimpa.`);
        sessionMap.set(`${day.date}|${room}|${sess.open}`,row.id);
        if(room==='RU01')continue; // PU01 memakai antrean langsung.
        for(let timestamp=+start;timestamp<+end;timestamp+=20*60000){
          const st=new Date(timestamp),et=new Date(timestamp+20*60000);
          const hhmm=new Intl.DateTimeFormat('en-GB',{timeZone:zone,hour:'2-digit',minute:'2-digit',hour12:false}).format(st);
          const key=`${day.date}|${room}|${hhmm}`;
          let slot=await qOne(db,'SELECT id,kapasitas,selesai_pada,aktif FROM slot_praktik WHERE jadwal_praktik_id=$1 AND mulai_pada=$2',[row.id,st]);
          if(!slot){const id=uid();await db.query('INSERT INTO slot_praktik(id,jadwal_praktik_id,mulai_pada,selesai_pada,kapasitas,aktif) VALUES($1,$2,$3,$4,1,true)',[id,row.id,st,et]);slot={id,kapasitas:1,selesai_pada:et,aktif:true};}
          if(!slot.aktif||slot.kapasitas!==1||+new Date(slot.selesai_pada)!==+et) throw Error(`Slot ${key} tidak sesuai kapasitas/durasi. Tidak ditimpa.`);
          slotMap.set(key,slot.id);
        }
      }
    }
  }
  if(slotMap.size!==30*2*27)throw Error(`Jumlah slot tidak tepat: ${slotMap.size} (target 1620).`);
  return slotMap;
}
async function createUsers(db){
  const users=new Map();const newCredentials=[];
  for(const p of DATA.patients){
    let u=await qOne(db,'SELECT id,nama,peran,aktif FROM pengguna WHERE email=$1',[p.email]);
    if(!u){
      const pwd=crypto.randomBytes(18).toString('base64url');
      const hash=await bcrypt.hash(pwd,10);
      const id=uid();
      await db.query("INSERT INTO pengguna(id,nama,email,kata_sandi_hash,peran,aktif,dibuat_pada,diperbarui_pada) VALUES($1,$2,$3,$4,'USER',true,now(),now())",[id,p.nama,p.email,hash]);
      u={id,nama:p.nama,peran:'USER',aktif:true};newCredentials.push({tipe:'PASIEN',id:p.id,nama:p.nama,email:p.email,password:pwd});
    }
    if(u.nama!==p.nama||u.peran!=='USER'||!u.aktif)throw Error(`Akun pasien ${p.email} tidak cocok.`);
    users.set(p.id,u.id);
  }
  return {users,newCredentials};
}
async function ensureStaff(db,s,newCredentials){
  for(const a of DATA.staff){
    let u=await qOne(db,'SELECT id,nama,peran,aktif FROM pengguna WHERE email=$1',[a.email]);
    if(!u){
      const pass=crypto.randomBytes(18).toString('base64url');
      const hash=await bcrypt.hash(pass,10);
      const id=uid();
      await db.query("INSERT INTO pengguna(id,nama,email,kata_sandi_hash,peran,aktif,dibuat_pada,diperbarui_pada) VALUES($1,$2,$3,$4,'PETUGAS',true,now(),now())",[id,a.nama,a.email,hash]);
      u={id,nama:a.nama,peran:'PETUGAS',aktif:true};
      newCredentials.push({tipe:'PETUGAS',id:a.room,nama:a.nama,email:a.email,password:pass});
    }
    if(u.nama!==a.nama||u.peran!=='PETUGAS'||!u.aktif)throw Error(`Akun petugas ${a.email} tidak sesuai.`);
    const loket=s.rooms.find(x=>x.kode===a.room);
    let assignment=await qOne(db,'SELECT id,aktif FROM penugasan_petugas WHERE petugas_id=$1 AND loket_id=$2 AND tanggal_mulai=$3::date AND tanggal_selesai=$4::date',[u.id,loket.id,DATA.meta.start,DATA.meta.end]);
    if(!assignment){
      const id=uid();
      await db.query('INSERT INTO penugasan_petugas(id,petugas_id,loket_id,tanggal_mulai,tanggal_selesai,aktif) VALUES($1,$2,$3,$4::date,$5::date,true)',[id,u.id,loket.id,DATA.meta.start,DATA.meta.end]);
    }else if(!assignment.aktif)throw Error(`Penugasan ${a.email} ${a.room} nonaktif.`);
  }
}
async function insertAudit(db,ticketId,actorId,flow,events){
  let prev=null;
  const vals=[];const arg=[];
  for(const ev of events){
    const offset=arg.length;
    vals.push(`($${offset+1},$${offset+2},$${offset+3},$${offset+4},$${offset+5}::status_tiket,$${offset+6}::status_tiket,$${offset+7}::jsonb,$${offset+8})`);
    arg.push(uid(),ticketId,ev.type,ev.type==='RESERVATION_BOOK'?actorId:null,prev,ev.status,JSON.stringify({simulasi:true,dataset:DATA.meta.id,skenario:flow}),ev.at);
    prev=ev.status;
  }
  await db.query('INSERT INTO peristiwa_antrean(id,tiket_antrean_id,tipe,aktor_id,status_sebelum,status_sesudah,data_tambahan,terjadi_pada) VALUES '+vals.join(','),arg);
}
async function apply(db,credPath){
  // Requires a dedicated database backup. No destructive statements in this tool.
  if(flag('--confirm')!==CONFIRM) throw Error(`Untuk mengimpor, tambahkan --confirm=${CONFIRM}`);
  const file=path.resolve(credPath);
  if(file.startsWith(path.resolve(ROOT,'..','..')+path.sep))throw Error('File kredensial harus disimpan di luar direktori proyek/Git.');
  const today=localDate();
  console.log(`Tanggal layanan sekarang: ${today} (WIB). Riwayat lampau disimulasikan, hari ini dan masa depan belum diproses.`);
  await db.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  let savedFile=false;
  try{
    await db.query("SET LOCAL lock_timeout = '5000ms'");
    await db.query("SET LOCAL statement_timeout = '900000ms'");
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[DATA.meta.id]);
    const {s,check}=await preview(db);
    if(check.errors.length)throw Error(`Impor dibatalkan. ${check.errors.length} kendala preflight; tidak ada perubahan.`);
    if(check.seedPresent.size===DATA.tickets.length && s.users.length===DATA.patients.length && DATA.staff.every(a=>s.staff.some(x=>x.email===a.email))){
      await db.query('ROLLBACK');
      console.log('Dataset ini sudah lengkap. Tidak ada data diubah (idempotent/no-op).');
      return;
    }
    const {users,newCredentials}=await createUsers(db);
    await ensureStaff(db,s,newCredentials);
    if(newCredentials.length>0 && fs.existsSync(file))throw Error(`File kredensial sudah ada: ${file}. Pilih lokasi baru tanpa menimpa.`);
    const links=await ensureDoctorLinks(db,s);
    const slots=await ensureSessionsAndSlots(db,s,links);
    const byDateSvc=new Map();
    for(const t of DATA.tickets){const k=`${t.date}|${t.service}`;const arr=byDateSvc.get(k)||[];arr.push(t);byDateSvc.set(k,arr);}
    let inserted=0,skipped=0;
    for(const [key,rows] of byDateSvc){
      const [day,svcCode]=key.split('|');
      const svc=s.services.find(x=>x.kode===svcCode);
      let counter=await qOne(db,'SELECT id,nomor_terakhir,urutan_masuk_terakhir FROM urutan_antrean_harian WHERE layanan_id=$1 AND tanggal=$2::date',[svc.id,day]);
      if(!counter){const id=uid();await db.query('INSERT INTO urutan_antrean_harian(id,layanan_id,tanggal,nomor_terakhir,urutan_masuk_terakhir,diperbarui_pada) VALUES($1,$2,$3::date,0,0,now())',[id,svc.id,day]);counter={id,nomor_terakhir:0,urutan_masuk_terakhir:0};}
      const maxExisting=await qOne(db,'SELECT COALESCE(MAX(nomor_urut),0)::int m,COALESCE(MAX(urutan_masuk_antrean),0)::int q FROM tiket_antrean WHERE layanan_id=$1 AND tanggal_antrean=$2::date',[svc.id,day]);
      let num=Math.max(counter.nomor_terakhir,maxExisting.m),qnum=Math.max(counter.urutan_masuk_terakhir,maxExisting.q);
      // FIFO for historical test events uses appointment/check-in time, not permanent ticket number.
      const hist=rows.filter(r=>r.date<today && !['A2','A4'].includes(r.flow) && !check.seedPresent.has(ticketCode(r)));
      hist.sort((a,b)=> (+inst(a.date,a.time))-(+inst(b.date,b.time)) || a.line-b.line);
      const queueNums=new Map();
      for(const item of hist)queueNums.set(ticketCode(item),++qnum);
      // Registration number remains row order only if the day is empty;
      // otherwise it follows the highest existing counter, preventing collisions.
      for(const t of rows.sort((a,b)=>a.line-b.line)){
        const code=ticketCode(t);
        const existing=await qOne(db,'SELECT id,pengguna_id,layanan_id,tanggal_antrean::text as tanggal_antrean FROM tiket_antrean WHERE kode_tiket=$1',[code]);
        if(existing){if(existing.pengguna_id!==users.get(t.patientId)||existing.layanan_id!==svc.id||dbDate(existing.tanggal_antrean)!==day)throw Error(`Benturan kode tiket ${code}`);skipped++;continue;}
        num++;
        const ct=chronologyFor(t,today,queueNums.get(code)||null);
        const roomId=t.service==='PG01'&&t.date<today&&['A1','A3'].includes(t.flow)?s.rooms.find(x=>x.kode===t.room)?.id:null;
        const calledRoomId= t.service==='PU01' ? s.rooms.find(x=>x.kode==='RU01').id : t.service==='APT01' ? s.rooms.find(x=>x.kode==='FA01').id : s.rooms.find(x=>x.kode===t.room)?.id;
        const loket= ct.calledAt ? calledRoomId : roomId;
        const id=uid();
        await db.query(`INSERT INTO tiket_antrean(id,pengguna_id,layanan_id,loket_id,tanggal_antrean,nomor_urut,urutan_masuk_antrean,masuk_antrean_pada,kode_tiket,status,token_qr_hash,qr_kedaluwarsa_pada,check_in_pada,dipanggil_pada,pelayanan_dimulai_pada,pelayanan_selesai_pada,versi,dibuat_pada,diperbarui_pada)
          VALUES($1,$2,$3,$4,$5::date,$6,$7,$8,$9,$10::status_tiket,NULL,NULL,$11,$12,$13,$14,$15,$16,$17)`,
          [id,users.get(t.patientId),svc.id,loket,day,num,ct.queueNum,ct.enteredAt,code,ct.status,ct.checkInAt,ct.calledAt,ct.startAt,ct.finishAt,ct.events.length,ct.bookedAt,new Date()]);
        if(t.service==='PG01'){
          const slot=slots.get(`${t.date}|${t.room}|${t.time}`);if(!slot)throw Error(`Tidak ada slot ${day} ${t.room} ${t.time}.`);
          await db.query('INSERT INTO janji_temu(id,tiket_id,slot_praktik_id,dibuat_pada,diperbarui_pada) VALUES($1,$2,$3,$4,now())',[uid(),id,slot,ct.bookedAt]);
        }
        await insertAudit(db,id,users.get(t.patientId),t.flow,ct.events);
        inserted++;
      }
      // Never decrease a counter even when existing rows have been removed manually.
      await db.query('UPDATE urutan_antrean_harian SET nomor_terakhir=GREATEST(nomor_terakhir,$2), urutan_masuk_terakhir=GREATEST(urutan_masuk_terakhir,$3),diperbarui_pada=now() WHERE id=$1',[counter.id,num,qnum]);
      console.log(`Diproses ${key}: ${rows.length} baris`);
    }
    if(newCredentials.length){
      fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
      fs.writeFileSync(file,'tipe,id_referensi,nama,email,password\n'+newCredentials.map(x=>[x.tipe,x.id,x.nama,x.email,x.password].map(quoteCsv).join(',')).join('\n')+'\n',{flag:'wx',mode:0o600});
      savedFile=true;
    }
    await db.query('COMMIT');
    console.log(`SELESAI: ${inserted} tiket baru; ${skipped} tiket identik dilewati; ${newCredentials.length} akun fiktif baru (pasien + petugas).`);
    if(newCredentials.length)console.log('Kredensial akun fiktif tersimpan di folder pribadi, di luar Git:',file);
    console.log('CATATAN: QR scan untuk tiket impor belum dijamin sampai service penerbit QR diperiksa.');
  }catch(err){
    try{await db.query('ROLLBACK')}catch{}
    if(savedFile){try{fs.unlinkSync(file)}catch{}}
    throw err;
  }
}
async function verify(db){
  const codes=DATA.tickets.map(ticketCode);
  const q=await db.query('SELECT t.kode_tiket,l.kode layanan_kode,t.tanggal_antrean,t.status FROM tiket_antrean t JOIN layanan l ON t.layanan_id=l.id WHERE t.kode_tiket=ANY($1::text[])',[codes]);
  console.log(`Ditemukan ${q.rows.length} / ${codes.length} tiket dataset. Jumlah per status: `);
  const byStatus={};for(const t of q.rows)byStatus[t.status]=(byStatus[t.status]||0)+1;
  console.log(byStatus);
  if(q.rows.length!==codes.length)throw Error('Verifikasi belum lengkap; jalankan preview sebelum apply.');
  const j=await qOne(db,'SELECT count(*)::int n FROM janji_temu j JOIN tiket_antrean t ON t.id=j.tiket_id WHERE t.kode_tiket = ANY($1::text[])',[codes]);
  if(j.n!==1181)throw Error(`Janji temu ${j.n}/1181 tidak lengkap.`);
  console.log('Verifikasi OK: 3.624 tiket, 1.181 janji temu.');
}
async function main(){
  validate();
  if(MODE==='validate'){console.log('Mode offline; belum mengakses database.');return;}
  if(!['preview','apply','verify'].includes(MODE))throw Error('Perintah: validate | preview | apply | verify');
  const raw=process.env.DATABASE_URL;if(!raw)throw Error('DATABASE_URL belum tersedia di environment / .env.');
  const url=new URL(raw);
  if(!['127.0.0.1','localhost','::1','[::1]'].includes(url.hostname)) throw Error('Importer sengaja membatasi target ke PostgreSQL lokal; jangan jalankan ke cloud/production.');
  if(process.env.NODE_ENV==='production')throw Error('Importer tidak boleh dijalankan dengan NODE_ENV=production.');
  if(process.env.SERVICE_TIME_ZONE && process.env.SERVICE_TIME_ZONE!==zone)throw Error('SERVICE_TIME_ZONE harus Asia/Jakarta karena dokumen WIB.');
  console.log(`Database lokal: ${url.hostname}:${url.port || '5432'} / ${url.pathname.slice(1)} (kata sandi dirahasiakan)`);
  const db=new Client({connectionString:raw});await db.connect();
  try{
    if(MODE==='preview'){const v=await preview(db);if(v.check.errors.length)process.exitCode=2;}
    else if(MODE==='apply')await apply(db,flag('--credentials')||path.join(os.homedir(),'QueueB-private','akun-30hari.csv'));
    else await verify(db);
  }finally{await db.end()}
}
main().catch(err=>{console.error('IMPOR GAGAL:',err.message);process.exitCode=1;});
