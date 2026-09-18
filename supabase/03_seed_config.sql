-- =====================================================================
-- KPI KARYAWAN - SEED DATA AWAL
-- File: supabase/03_seed_config.sql
-- Jalankan setelah 02_rls.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Konfigurasi aplikasi (pengganti hardcode APP_CONFIG di index.html
--    + konstanta bisnis di code.gs)
-- ---------------------------------------------------------------------
insert into public."Config" ("Key", "Value") values
  -- Bobot persentase leaderboard (APP_CONFIG.bobotPersen)
  ('bobot_kinerja',              '50'),
  ('bobot_kehadiran',            '30'),
  ('bobot_seragam',              '20'),
  -- Poin penilaian seragam (APP_CONFIG.poinSeragamLengkap/TidakLengkap)
  ('poin_seragam_lengkap',       '2'),
  ('poin_seragam_tidak_lengkap', '0'),
  -- Keamanan login (code.gs: MAX_LOGIN_ATTEMPTS / LOGIN_LOCKOUT_SECONDS)
  ('max_login_attempts',         '5'),
  ('login_lockout_seconds',      '300'),
  ('session_ttl_days',           '30'),
  -- Daftar area piket (sebelumnya hardcode di <select id="inpPiketJenis">)
  ('area_piket',                 'Lantai 1,Lantai 2,Tangga & Wc,Cuci Piring & Buang Sampah')
on conflict ("Key") do update
  set "Value" = excluded."Value",
      updated_at = now();

-- ---------------------------------------------------------------------
-- 2. Akun Admin pertama
-- ---------------------------------------------------------------------
-- PILIHAN A (cara cepat, hash dihitung di database):
--   FUNGSI _kpi_hash_pin() ada di file 04_functions_auth.sql, jadi blok
--   "do $$ ... $$" di bawah harus dijalankan SETELAH file 04 dieksekusi.
--   Jalankan blok ini SETELAH mengganti email/nama/pin.
--   PIN 6 digit akan langsung disimpan dalam bentuk hash sha256v2$...,
--   sama formatnya dengan hasil _hashPin() di code.gs.
do $$
declare
  v_email text := 'admin@mail.com';  -- <<< GANTI
  v_nama  text := 'Admin Master';    -- <<< GANTI
  v_pin   text := '123456';          -- <<< GANTI (harus 6 digit)
begin
  if v_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN harus tepat 6 digit angka.';
  end if;

  insert into public."Users" ("User_ID", "Nama", "Role", "PIN")
  values (
    lower(v_email),
    v_nama,
    'Admin',
    public._kpi_hash_pin(v_pin, lower(v_email))   -- fungsi ada di 04_functions_auth.sql
  )
  on conflict ("User_ID") do update
    set "Nama" = excluded."Nama",
        "Role" = excluded."Role",
        "PIN"  = excluded."PIN";
end;
$$;

-- PILIHAN B (registrasi via aplikasi):
--   Setelah migrasi, karyawan bisa mendaftar sendiri melalui menu Register
--   di halaman login, atau di-INSERT manual ke tabel `Users` dengan PIN
--   yang di-hash menggunakan public._kpi_hash_pin().
