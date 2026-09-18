-- =====================================================================
-- KPI KARYAWAN - KEAMANAN (RLS) & STORAGE
-- File: supabase/02_rls.sql
-- ---------------------------------------------------------------------
-- STRATEGI KEAMANAN (penting, baca dulu):
--
-- Aplikasi ini TIDAK memakai Supabase Auth. Login tetap pakai PIN, dan
-- seluruh akses data lewat fungsi RPC (schema public) yang didefinisikan
-- di 04_functions_auth.sql & 05_functions_data.sql. Fungsi-fungsi itu
-- dibuat dengan SECURITY DEFINER + validasi token sesi sendiri, persis
-- seperti _requireSession(token, role) di code.gs.
--
-- Maka RLS di sini dibuat "DENY BY DEFAULT":
--   * RLS diaktifkan di semua tabel.
--   * TIDAK ada satu pun policy untuk role anon/authenticated.
--   * Hasilnya: anon key (yang ada di browser) TIDAK BISA membaca/menulis
--     tabel secara langsung - termasuk tabel "Users" yang berisi hash PIN.
--   * Yang boleh lewat hanya: (a) fungsi SECURITY DEFINER (bypass RLS),
--     (b) service_role key (dipakai backend/Edge Function/importer - JANGAN
--     pernah ditaruh di browser).
--
-- Jalankan file ini SETELAH 01_schema.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Aktifkan RLS di semua tabel
-- ---------------------------------------------------------------------
alter table public."Users"          enable row level security;
alter table public."Jobdesk"        enable row level security;
alter table public."Piket"          enable row level security;
alter table public."Kehadiran"      enable row level security;
alter table public."Seragam"        enable row level security;
alter table public."Config"         enable row level security;
alter table public."Sessions"       enable row level security;
alter table public."Login_Attempts" enable row level security;

-- ---------------------------------------------------------------------
-- 2. Pastikan anon/authenticated TIDAK punya hak apa pun di tabel
--    (policy kosong saja sudah menolak baris, tapi REVOKE ini juga
--     menutup jalur akses struktur tabel seperti `select * from users`).
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- View bantu pun tidak untuk diakses langsung dari browser.
revoke all on public.v_poin_bulanan    from anon, authenticated;
revoke all on public.v_antrean_pending from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Beri anon hak memanggil fungsi RPC saja (login, getAllData, dst).
--    GRANT EXECUTE ini diberikan otomatis juga di file 04 & 05, tapi
--    ditulis sekali lagi di sini agar jelas & idempoten.
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Storage bucket untuk bukti foto piket telah dihapus karena fitur
--    upload foto dinonaktifkan.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 5. Cek hasil (jalankan manual untuk memastikan RLS aktif)
-- ---------------------------------------------------------------------
-- select tablename, rowsecurity from pg_tables where schemaname = 'public';
--   -> semua tabel harus rowsecurity = true
-- select count(*) from pg_policies where schemaname = 'public';
--   -> harus 0 (deny by default) kecuali Anda membuka policy opsional di atas
