-- =====================================================================
-- KPI KARYAWAN WAHDAH ISLAMIYAH MAKASSAR - SKEMA DATABASE SUPABASE
-- File: supabase/01_schema.sql
-- ---------------------------------------------------------------------
-- Catatan desain penting:
--  1. NAMA TABEL & KOLOM SENGAJA DIPERTAHANKAN persis seperti nama sheet
--     (Users, Jobdesk, Piket, Kehadiran, Seragam, Config) + nama kolom
--     PascalCase (Task_ID, User_ID, ...). Alasannya: seluruh frontend
--     (index.html) dan kontrak API (doPost -> getAllData) memakai nama
--     tersebut, jadi migrasi ini TIDAK memaksa perubahan di frontend.
--  2. Karena nama kolom bertipe mixed-case, SEMUA identifier harus
--     ditulis dalam tanda kutip ganda ("Task_ID"). Tanpa kutip, Postgres
--     menganggapnya task_id dan query akan gagal.
--  3. Tanggal disimpan sebagai tipe `date`/`text` asli (bukan lagi string
--     yang di-autoformat Google Sheets). "Tanggal" = date, "Bulan" =
--     text 'YYYY-MM'.
--  4. Proteksi akses ada di file 02_rls.sql.
-- Urutan eksekusi: 01 -> 02 -> 03 -> 04 -> 05 -> (06 opsional)
-- =====================================================================

-- Ekstensi yang dibutuhkan:
--  * pgcrypto  -> digest() SHA-256 untuk hash PIN, gen_random_uuid()
--  * pg_trgm   -> index pencarian teks (opsional, dipakai index nama)
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm  with schema extensions;

-- =====================================================================
-- 1. USERS  (pengganti sheet 'Users')
-- =====================================================================
-- Sheet lama: [User_ID, Nama, Role, PIN]
--  * User_ID = email (lowercase) dan menjadi PRIMARY KEY.
--  * PIN     = hash "sha256v2$<64 hex>" (kompatibel penuh dengan _hashPin()
--              di code.gs: sha256(pin + 'WIM-KPI-2024' + '::' + email)).
--              Kolom ini TIDAK PERNAH boleh dibaca dari client (dijaga RLS).
--  * auth_user_id = opsional, hanya bila nanti memakai Supabase Auth.
create table if not exists public."Users" (
  "User_ID"      text primary key
                 check ("User_ID" = lower("User_ID")),
  "Nama"         text not null
                 check (char_length(btrim("Nama")) between 1 and 100),
  "Role"         text not null default 'User'
                 check ("Role" in ('Admin', 'Operator', 'User')),
  "PIN"          text,                       -- nullable: boleh kosong bila pakai Supabase Auth
  auth_user_id   uuid unique references auth.users (id) on delete set null,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table  public."Users" is 'Profil karyawan (pengganti sheet Users). User_ID = email lowercase.';
comment on column public."Users"."PIN" is 'Hash SHA-256 + salt per-user, format sha256v2$<hex>. Jangan pernah kirim ke client.';

-- Index tambahan: pencarian nama pada dropdown admin.
create index if not exists idx_users_role on public."Users" ("Role") where is_active;
create index if not exists idx_users_nama_trgm on public."Users" using gin ("Nama" extensions.gin_trgm_ops);
-- =====================================================================
-- 2. JOBDESK / TUGAS  (pengganti sheet 'Jobdesk')
-- =====================================================================
-- Sheet lama: [Task_ID, User_ID, Tanggal, Deskripsi_Tugas, Status, Poin, Status_Kerja]
create table if not exists public."Jobdesk" (
  "Task_ID"         text primary key
                    default ('TSK-' || gen_random_uuid()),
  "User_ID"         text not null
                    references public."Users" ("User_ID") on delete cascade,
  "Tanggal"         date not null default current_date,
  "Deskripsi_Tugas" text not null
                    check (char_length(btrim("Deskripsi_Tugas")) between 10 and 500),
  "Status"          text not null default 'Pending'
                    check ("Status" in ('Pending', 'Approved')),
  "Poin"            numeric(10, 2) not null default 0
                    check ("Poin" >= 0),
  "Status_Kerja"    text not null default 'Belum Selesai'
                    check ("Status_Kerja" in ('Selesai', 'Belum Selesai')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public."Jobdesk" is 'Laporan tugas harian karyawan (pengganti sheet Jobdesk).';
comment on column public."Jobdesk"."Deskripsi_Tugas" is 'Bisa berisi marker "[[ASSIGNED_BY:Nama Admin]] " di depan deskripsi.';

-- Index untuk query yang paling sering dipakai frontend:
--  * daftar tugas per user + urut tanggal
--  * antrean persetujuan (Status = Pending)
create index if not exists idx_jobdesk_user_tanggal on public."Jobdesk" ("User_ID", "Tanggal" desc);
create index if not exists idx_jobdesk_status        on public."Jobdesk" ("Status") where "Status" = 'Pending';
create index if not exists idx_jobdesk_tanggal       on public."Jobdesk" ("Tanggal" desc);

-- =====================================================================
-- 3. PIKET  (pengganti sheet 'Piket')
-- =====================================================================
-- Sheet lama: [Schedule_ID, User_ID, Tanggal, Jenis_Piket, Status,
--              Poin, Status_Kerja, Catatan_Admin]
create table if not exists public."Piket" (
  "Schedule_ID"     text primary key
                    default ('PKT-' || gen_random_uuid()),
  "User_ID"         text not null
                    references public."Users" ("User_ID") on delete cascade,
  "Tanggal"         date not null default current_date,
  "Jenis_Piket"     text not null
                    check (char_length(btrim("Jenis_Piket")) between 1 and 100),
  "Status"          text not null default 'Pending'
                     check ("Status" in ('Pending', 'Approved')),
  "Poin"            numeric(10, 2) not null default 0
                    check ("Poin" >= 0),
  "Status_Kerja"    text not null default 'Belum Selesai'
                    check ("Status_Kerja" in ('Selesai', 'Belum Selesai')),
  "Catatan_Admin"   text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public."Piket" is 'Laporan piket (pengganti sheet Piket).';

create index if not exists idx_piket_user_tanggal on public."Piket" ("User_ID", "Tanggal" desc);
create index if not exists idx_piket_status       on public."Piket" ("Status") where "Status" = 'Pending';
create index if not exists idx_piket_jenis        on public."Piket" ("Jenis_Piket");

-- =====================================================================
-- 4. KEHADIRAN  (pengganti sheet 'Kehadiran')
-- =====================================================================
-- Sheet lama: [Kehadiran_ID, User_ID, Bulan, Nilai]
-- "Bulan" = teks 'YYYY-MM' (bukan date) supaya persis sama perilaku
-- frontend yang mencocokkan string bulan.
-- UNIQUE(User_ID, Bulan) menggantikan logika "cari lalu update, kalau
-- tidak ada baru append" di saveKehadiran() -> cukup pakai UPSERT.
create table if not exists public."Kehadiran" (
  "Kehadiran_ID" text primary key
                 default ('KHD-' || gen_random_uuid()),
  "User_ID"      text not null
                 references public."Users" ("User_ID") on delete cascade,
  "Bulan"        text not null
                 check ("Bulan" ~ '^[0-9]{4}-[0-9]{2}$'),
  "Nilai"        numeric(10, 2) not null default 0
                 check ("Nilai" >= 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint uq_kehadiran_user_bulan unique ("User_ID", "Bulan")
);

comment on table public."Kehadiran" is 'Nilai kehadiran bulanan per karyawan (pengganti sheet Kehadiran).';

create index if not exists idx_kehadiran_bulan on public."Kehadiran" ("Bulan");

-- =====================================================================
-- 5. SERAGAM  (pengganti sheet 'Seragam')
-- =====================================================================
-- Sheet lama: [Seragam_ID, User_ID, Tanggal, Nilai]
create table if not exists public."Seragam" (
  "Seragam_ID" text primary key
               default ('SRG-' || gen_random_uuid()),
  "User_ID"    text not null
               references public."Users" ("User_ID") on delete cascade,
  "Tanggal"    date not null default current_date,
  "Nilai"      numeric(10, 2) not null default 0
               check ("Nilai" >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint uq_seragam_user_tanggal unique ("User_ID", "Tanggal")
);

comment on table public."Seragam" is 'Penilaian seragam harian per karyawan (pengganti sheet Seragam).';

create index if not exists idx_seragam_tanggal on public."Seragam" ("Tanggal" desc);

-- =====================================================================
-- 6. CONFIG  (pengganti sheet 'Config')
-- =====================================================================
-- Key/Value bebas. Dipakai untuk memindahkan hardcode di index.html
-- (APP_CONFIG) & code.gs ke database. Seed ada di 03_seed_config.sql.
create table if not exists public."Config" (
  "Key"      text primary key,
  "Value"    text,
  updated_at timestamptz not null default now()
);

comment on table public."Config" is 'Konfigurasi aplikasi Key/Value (pengganti sheet Config).';

-- =====================================================================
-- 7. SESSIONS  (pengganti CacheService 'session_<token>')
-- =====================================================================
-- Di Apps Script sesi disimpan di CacheService (bisa hilang kapan saja
-- bila cache dibersihkan). Di Supabase sesi disimpan di tabel supaya
-- tahan restart, bisa diaudit, dan bisa di-revoke (logout semua device).
create table if not exists public."Sessions" (
  token      uuid primary key default gen_random_uuid(),
  "User_ID"  text not null
             references public."Users" ("User_ID") on delete cascade,
  user_agent text,
  ip_address text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);

comment on table public."Sessions" is 'Sesi login (pengganti CacheService session_<token>). TTL default 30 hari.';

create index if not exists idx_sessions_user    on public."Sessions" ("User_ID");
create index if not exists idx_sessions_expires on public."Sessions" (expires_at);

-- =====================================================================
-- 8. LOGIN_ATTEMPTS  (pengganti CacheService 'login_fail_<email>')
-- =====================================================================
create table if not exists public."Login_Attempts" (
  email        text primary key,
  failed_count int not null default 0,
  locked_until timestamptz,
  last_attempt timestamptz not null default now()
);

comment on table public."Login_Attempts" is 'Penghitung percobaan login gagal (rate limit 5x / 5 menit).';

-- =====================================================================
-- 9. TRIGGER updated_at otomatis untuk semua tabel
-- =====================================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  t record;
begin
  for t in
    select c.table_name
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.column_name  = 'updated_at'
  loop
    execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$I', t.table_name);
    execute format(
      'create trigger trg_%1$s_updated_at before update on public.%1$I
         for each row execute function public.set_updated_at()', t.table_name);
  end loop;
end;
$$;

-- =====================================================================
-- 10. VIEW BANTU (opsional, untuk laporan & analitik)
-- =====================================================================
-- View ini memakai gaya snake_case agar enak dipakai di SQL/BI tool,
-- TANPA mengubah tabel utama yang dipertahankan kompatibel.
create or replace view public.v_poin_bulanan as
with basis as (
  select
    u."User_ID" as user_id,
    coalesce(to_char(j."Tanggal", 'YYYY-MM'), to_char(p."Tanggal", 'YYYY-MM'),
             k."Bulan",  to_char(s."Tanggal", 'YYYY-MM')) as bulan
  from public."Users" u
  left join public."Jobdesk"   j on j."User_ID" = u."User_ID"
  left join public."Piket"     p on p."User_ID" = u."User_ID"
  left join public."Kehadiran" k on k."User_ID" = u."User_ID"
  left join public."Seragam"   s on s."User_ID" = u."User_ID"
  where u.is_active
)
select
  u."User_ID"                                        as user_id,
  u."Nama"                                           as nama,
  u."Role"                                           as role,
  b.bulan,
  coalesce((
    select sum(j."Poin") from public."Jobdesk" j
    where j."User_ID" = u."User_ID" and j."Status" = 'Approved'
      and to_char(j."Tanggal", 'YYYY-MM') = b.bulan), 0)          as poin_jobdesk,
  coalesce((
    select sum(p."Poin") from public."Piket" p
    where p."User_ID" = u."User_ID" and p."Status" = 'Approved'
      and to_char(p."Tanggal", 'YYYY-MM') = b.bulan), 0)          as poin_piket,
  coalesce((
    select max(k."Nilai") from public."Kehadiran" k
    where k."User_ID" = u."User_ID" and k."Bulan" = b.bulan), 0)  as nilai_kehadiran,
  coalesce((
    select sum(s."Nilai") from public."Seragam" s
    where s."User_ID" = u."User_ID"
      and to_char(s."Tanggal", 'YYYY-MM') = b.bulan), 0)          as nilai_seragam
from public."Users" u
join (select distinct user_id, bulan from basis where bulan is not null) b
  on b.user_id = u."User_ID"
where u.is_active
order by b.bulan desc, u."Nama";

comment on view public.v_poin_bulanan is 'Rekap poin per karyawan per bulan (jobdesk, piket, kehadiran, seragam).';

-- View ringkas antrean persetujuan (Admin/Operator).
create or replace view public.v_antrean_pending as
select 'Task'::text as jenis, j."Task_ID" as id, j."User_ID" as user_id, u."Nama" as nama,
       j."Tanggal"::text as tanggal, j."Deskripsi_Tugas" as deskripsi,
       null::text as jenis_piket, j."Status_Kerja" as status_kerja, j.created_at
from public."Jobdesk" j
join public."Users" u on u."User_ID" = j."User_ID"
where j."Status" = 'Pending'
union all
select 'Piket'::text, p."Schedule_ID", p."User_ID", u."Nama",
       p."Tanggal"::text, null::text,
       p."Jenis_Piket", p."Status_Kerja", p.created_at
from public."Piket" p
join public."Users" u on u."User_ID" = p."User_ID"
where p."Status" = 'Pending';

comment on view public.v_antrean_pending is 'Gabungan antrean persetujuan Jobdesk + Piket yang masih Pending.';

