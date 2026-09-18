-- =====================================================================
-- KPI KARYAWAN - FUNGSI AUTENTIKASI & SESI (RPC)
-- File: supabase/04_functions_auth.sql
-- ---------------------------------------------------------------------
-- Berisi pengganti bagian autentikasi code.gs:
--   login()          -> kpi_login()
--   logoutSession()  -> kpi_logout()
--   registerUser()   -> kpi_register()
--   resetPin()       -> kpi_reset_pin()
--   changePin()      -> kpi_change_pin()
--   _requireSession()-> _kpi_require_session()
--
-- PENTING: semua fungsi diberi SECURITY DEFINER + `set search_path`
-- supaya (1) boleh menembus RLS, dan (2) tidak rentan serangan
-- search_path hijacking.
--
-- Pemanggilan dari browser (via PostgREST): POST /rest/v1/rpc/kpi_login
-- dengan body {"p_email":"...","p_pin":"..."}.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Konstanta aplikasi
-- ---------------------------------------------------------------------
-- Sama dengan PIN_SALT di code.gs. JANGAN diubah setelah ada PIN yang
-- tersimpan sebagai hash - kalau diubah, semua hash PIN lama tidak cocok.
create or replace function public._kpi_pin_salt()
returns text
language sql immutable
as $$ select 'WIM-KPI-2024'::text $$;

-- Ambil nilai Config dengan fallback default bila belum ada.
create or replace function public._kpi_config(p_key text, p_default text default null)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select c."Value" from public."Config" c where c."Key" = p_key), p_default);
$$;

-- ---------------------------------------------------------------------
-- 2. Hash & verifikasi PIN (identik dengan _hashPin() di code.gs)
-- ---------------------------------------------------------------------
-- sha256(pin + 'WIM-KPI-2024' + '::' + lower(email)) -> 'sha256v2$<hex>'
create or replace function public._kpi_hash_pin(p_pin text, p_email text)
returns text
language sql
immutable
as $$
  select 'sha256v2$' || encode(
    extensions.digest(
      p_pin || 'WIM-KPI-2024' || '::' || lower(btrim(coalesce(p_email, ''))),
      'sha256'
    ),
    'hex'
  );
$$;

-- Skema LAMA (v1): sha256(pin + 'WIM-KPI-2024') tanpa email -> 'sha256$<hex>'
-- Dipertahankan hanya untuk baris lama; tidak dipakai membuat hash baru.
create or replace function public._kpi_hash_pin_legacy_v1(p_pin text)
returns text
language sql
immutable
as $$
  select 'sha256$' || encode(
    extensions.digest(p_pin || 'WIM-KPI-2024', 'sha256'),
    'hex'
  );
$$;

-- Verifikasi PIN terhadap 3 kemungkinan format nilai tersimpan
-- (hash v2, hash v1 lama, atau teks biasa 6 digit dari spreadsheet jadul).
create or replace function public._kpi_pin_matches(p_stored text, p_input text, p_email text)
returns boolean
language sql
immutable
as $$
  select case
    when coalesce(p_stored, '') ~ '^sha256v2\$[0-9a-f]{64}$'
      then p_stored = public._kpi_hash_pin(p_input, p_email)
    when coalesce(p_stored, '') ~ '^sha256\$[0-9a-f]{64}$'
      then p_stored = public._kpi_hash_pin_legacy_v1(p_input)
    else coalesce(p_stored, '') = coalesce(p_input, '')
  end;
$$;

-- ---------------------------------------------------------------------
-- 3. Validasi sesi (pengganti _requireSession di code.gs)
-- ---------------------------------------------------------------------
-- Mengembalikan jsonb {user_id, nama, role} bila token valid.
-- Melempar exception dengan pesan yang SAMA seperti di code.gs supaya
-- handleSessionExpired() di index.html tetap mendeteksinya.
-- Catatan: token diterima sebagai text (bukan uuid) supaya nilai token
-- dari localStorage tidak pernah memicu error parsing yang membingungkan.
create or replace function public._kpi_require_session(
  p_token text,
  p_roles text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  if p_token is null or btrim(p_token) = '' then
    raise exception 'Sesi tidak ditemukan. Silakan login ulang.';
  end if;

  select s."User_ID" as user_id, u."Nama" as nama, u."Role" as role
    into r
  from public."Sessions" s
  join public."Users" u on u."User_ID" = s."User_ID"
  where s.token::text = lower(btrim(p_token))
    and s.expires_at > now()
    and u.is_active;

  if r is null then
    raise exception 'Sesi habis atau tidak valid. Silakan login ulang.';
  end if;

  if p_roles is not null and not (r.role = any (p_roles)) then
    raise exception 'Anda tidak memiliki izin untuk melakukan aksi ini.';
  end if;

  -- Catat pelaku di level transaksi. Dipakai trigger audit log
  -- (06_audit_log.sql) untuk mengisi kolom actor. is_local = true
  -- sehingga nilainya otomatis hilang di akhir transaksi.
  perform set_config('kpi.actor', r.user_id, true);

  return jsonb_build_object('user_id', r.user_id, 'nama', r.nama, 'role', r.role);
end;
$$;

-- Helper kecil: bersihkan sesi kedaluwarsa (dipanggil saat login).
create or replace function public._kpi_purge_expired_sessions()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public."Sessions" where expires_at <= now();
$$;

-- ---------------------------------------------------------------------
-- 4. kpi_login  (pengganti login() di code.gs)
-- ---------------------------------------------------------------------
-- Mengembalikan jsonb dengan bentuk PERSIS seperti balasan login() lama:
--   sukses : {"token": "...", "user": {"User_ID": "...", "Nama": "...", "Role": "..."}}
--   gagal  : {"error": "..."}
-- Jadi blok success handler login di index.html tidak perlu diubah.
create or replace function public.kpi_login(
  p_email      text,
  p_pin        text,
  p_user_agent text default null,
  p_ip         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_pin     text := btrim(coalesce(p_pin, ''));
  v_user    record;
  v_max     int;
  v_lockout int;
  v_ttl     int;
  v_attempt record;
  v_token   uuid;
begin
  if v_email = '' or v_pin = '' then
    return jsonb_build_object('error', 'Email dan PIN wajib diisi.');
  end if;

  v_max     := coalesce(public._kpi_config('max_login_attempts', '5')::int, 5);
  v_lockout := coalesce(public._kpi_config('login_lockout_seconds', '300')::int, 300);
  v_ttl     := coalesce(public._kpi_config('session_ttl_days', '30')::int, 30);

  -- Rate limit: blokir sementara bila sudah melewati batas percobaan gagal.
  select * into v_attempt from public."Login_Attempts" where email = v_email;
  if v_attempt is not null
     and v_attempt.locked_until is not null
     and v_attempt.locked_until > now() then
    return jsonb_build_object(
      'error',
      'Terlalu banyak percobaan login gagal. Coba lagi dalam ' ||
      greatest(1, ceil(extract(epoch from (v_attempt.locked_until - now())) / 60))::int ||
      ' menit.'
    );
  end if;

  select * into v_user
  from public."Users"
  where "User_ID" = v_email and is_active
  limit 1;

  -- Pesan disamakan (email salah / PIN salah) agar tidak membocorkan
  -- apakah sebuah email terdaftar atau tidak.
  if v_user is null or not public._kpi_pin_matches(v_user."PIN", v_pin, v_email) then
    insert into public."Login_Attempts" as la (email, failed_count, locked_until, last_attempt)
    values (
      v_email,
      1,
      case when v_max <= 1 then now() + make_interval(secs => v_lockout) else null end,
      now()
    )
    on conflict (email) do update
      set failed_count = case
                           when la.locked_until is not null and la.locked_until > now() then la.failed_count
                           else la.failed_count + 1
                         end,
          locked_until = case
                           when la.locked_until is not null and la.locked_until > now() then la.locked_until
                           when la.failed_count + 1 >= v_max then now() + make_interval(secs => v_lockout)
                           else null
                         end,
          last_attempt = now();

    return jsonb_build_object('error', 'Email atau PIN salah.');
  end if;

  -- Login sukses: reset penghitung gagal + rapikan PIN lama jadi hash v2.
  delete from public."Login_Attempts" where email = v_email;

  if v_user."PIN" is null
     or v_user."PIN" !~ '^sha256v2\$[0-9a-f]{64}$' then
    update public."Users"
       set "PIN" = public._kpi_hash_pin(v_pin, v_email)
     where "User_ID" = v_email;
  end if;

  perform public._kpi_purge_expired_sessions();

  insert into public."Sessions" (token, "User_ID", user_agent, ip_address, expires_at)
  values (
    gen_random_uuid(),
    v_user."User_ID",
    left(coalesce(p_user_agent, ''), 300),
    left(coalesce(p_ip, ''), 60),
    now() + make_interval(days => v_ttl)
  )
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token::text,
    'user', jsonb_build_object(
      'User_ID', v_user."User_ID",
      'Nama',    v_user."Nama",
      'Role',    v_user."Role"
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. kpi_logout  (pengganti logoutSession())
-- ---------------------------------------------------------------------
create or replace function public.kpi_logout(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public."Sessions" where token::text = lower(btrim(coalesce(p_token, '')));
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. kpi_register  (pengganti registerUser() di code.gs)
-- ---------------------------------------------------------------------
-- Role SELALU dipaksa 'User' di server (tidak bisa dipilih dari client).
create or replace function public.kpi_register(
  p_nama  text,
  p_email text,
  p_pin   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_nama  text := btrim(coalesce(p_nama, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_pin   text := btrim(coalesce(p_pin, ''));
begin
  if v_nama = '' or v_email = '' or v_pin = '' then
    return jsonb_build_object('error', 'Nama, email, dan PIN wajib diisi.');
  end if;
  if length(v_nama) > 100 then
    v_nama := left(v_nama, 100);
  end if;
  -- Regex sama dengan code.gs: sengaja melarang kutip, backslash, dan
  -- tanda kurung sudut supaya aman dipakai di atribut onclick frontend.
  if v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then
    return jsonb_build_object('error', 'Format email tidak valid.');
  end if;
  if v_pin !~ '^[0-9]{6}$' then
    return jsonb_build_object('error', 'PIN harus tepat 6 digit angka (tidak boleh lebih atau kurang).');
  end if;
  if exists (select 1 from public."Users" where "User_ID" = v_email) then
    return jsonb_build_object('error', 'Email sudah terdaftar.');
  end if;

  insert into public."Users" ("User_ID", "Nama", "Role", "PIN")
  values (v_email, v_nama, 'User', public._kpi_hash_pin(v_pin, v_email));

  return jsonb_build_object('User_ID', v_email, 'Nama', v_nama, 'Role', 'User');
end;
$$;

-- ---------------------------------------------------------------------
-- 8. kpi_change_pin  (pengganti changePin(): wajib PIN lama)
-- ---------------------------------------------------------------------
create or replace function public.kpi_change_pin(
  p_token     text,
  p_pin_lama  text,
  p_pin_baru  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_sess     jsonb;
  v_uid      text;
  v_lama     text := btrim(coalesce(p_pin_lama, ''));
  v_baru     text := btrim(coalesce(p_pin_baru, ''));
  v_stored   text;
begin
  v_sess := public._kpi_require_session(p_token);
  v_uid  := v_sess ->> 'user_id';

  if v_lama = '' or v_baru = '' then
    return jsonb_build_object('error', 'PIN lama dan PIN baru wajib diisi.');
  end if;
  if v_baru !~ '^[0-9]{6}$' then
    return jsonb_build_object('error', 'PIN baru harus tepat 6 digit angka (tidak boleh lebih atau kurang).');
  end if;

  select "PIN" into v_stored from public."Users" where "User_ID" = v_uid;
  if v_stored is null and not exists (select 1 from public."Users" where "User_ID" = v_uid) then
    return jsonb_build_object('error', 'Akun tidak ditemukan.');
  end if;
  if not public._kpi_pin_matches(v_stored, v_lama, v_uid) then
    return jsonb_build_object('error', 'PIN lama salah.');
  end if;

  update public."Users"
     set "PIN" = public._kpi_hash_pin(v_baru, v_uid)
   where "User_ID" = v_uid;

  -- Keamanan tambahan: sesi lain (device lain) diputus, sesi aktif dipertahankan.
  delete from public."Sessions"
   where "User_ID" = v_uid and token::text <> lower(btrim(p_token));

  return jsonb_build_object('success', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. kpi_reset_pin  (pengganti resetPin(): HANYA Admin)
-- ---------------------------------------------------------------------
create or replace function public.kpi_reset_pin(
  p_token    text,
  p_email    text,
  p_pin_baru text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_baru  text := btrim(coalesce(p_pin_baru, ''));
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if v_email = '' or v_baru = '' then
    return jsonb_build_object('error', 'Email dan PIN baru wajib diisi.');
  end if;
  if v_baru !~ '^[0-9]{6}$' then
    return jsonb_build_object('error', 'PIN baru harus tepat 6 digit angka (tidak boleh lebih atau kurang).');
  end if;
  if not exists (select 1 from public."Users" where "User_ID" = v_email) then
    return jsonb_build_object('error', 'Email tidak ditemukan.');
  end if;

  update public."Users"
     set "PIN" = public._kpi_hash_pin(v_baru, v_email)
   where "User_ID" = v_email;

  -- Semua sesi user tsb diputus supaya PIN baru langsung berlaku efektif.
  delete from public."Sessions" where "User_ID" = v_email;

  return jsonb_build_object('success', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. kpi_session_info (opsional: cek sesi masih hidup / pulihkan sesi)
-- ---------------------------------------------------------------------
create or replace function public.kpi_session_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public._kpi_require_session(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Manajemen user oleh Admin (dulu: edit manual di sheet Users)
-- ---------------------------------------------------------------------
create or replace function public.kpi_set_user_role(
  p_token text,
  p_email text,
  p_role  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_role  text := btrim(coalesce(p_role, ''));
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if v_role not in ('Admin', 'Operator', 'User') then
    return jsonb_build_object('error', 'Role tidak valid. Pilih Admin, Operator, atau User.');
  end if;
  if not exists (select 1 from public."Users" where "User_ID" = v_email) then
    return jsonb_build_object('error', 'Email tidak ditemukan.');
  end if;
  -- Cegah aplikasi kehilangan seluruh Admin aktif.
  if v_role <> 'Admin'
     and exists (select 1 from public."Users" where "User_ID" = v_email and "Role" = 'Admin')
     and (select count(*) from public."Users" where "Role" = 'Admin' and is_active) <= 1 then
    return jsonb_build_object('error', 'Minimal harus ada satu Admin aktif. Tambahkan Admin lain dulu.');
  end if;

  update public."Users" set "Role" = v_role where "User_ID" = v_email;
  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.kpi_set_user_active(
  p_token  text,
  p_email  text,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if not exists (select 1 from public."Users" where "User_ID" = v_email) then
    return jsonb_build_object('error', 'Email tidak ditemukan.');
  end if;
  if coalesce(p_active, true) = false
     and exists (select 1 from public."Users" where "User_ID" = v_email and "Role" = 'Admin')
     and (select count(*) from public."Users" where "Role" = 'Admin' and is_active) <= 1 then
    return jsonb_build_object('error', 'Minimal harus ada satu Admin aktif.');
  end if;

  update public."Users" set is_active = coalesce(p_active, true) where "User_ID" = v_email;
  if coalesce(p_active, true) = false then
    delete from public."Sessions" where "User_ID" = v_email;
  end if;

  return jsonb_build_object('success', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Konfigurasi aplikasi (tabel Config) - baca & tulis
-- ---------------------------------------------------------------------
-- Dibaca siapa saja yang sudah login (dipakai frontend untuk bobot dll).
create or replace function public.kpi_get_config(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg jsonb;
begin
  perform public._kpi_require_session(p_token);

  select coalesce(jsonb_object_agg(c."Key", c."Value"), '{}'::jsonb)
    into v_cfg
  from public."Config" c;

  return v_cfg;
end;
$$;

-- Ditulis hanya oleh Admin (mis. mengganti daftar area piket).
create or replace function public.kpi_set_config(
  p_token text,
  p_key   text,
  p_value text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := btrim(coalesce(p_key, ''));
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if v_key = '' then
    return jsonb_build_object('error', 'Key konfigurasi wajib diisi.');
  end if;

  insert into public."Config" ("Key", "Value")
  values (v_key, p_value)
  on conflict ("Key") do update set "Value" = excluded."Value", updated_at = now();

  return jsonb_build_object('success', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 13. HAK AKSES: beri izin EXECUTE ke anon (browser memakai anon key)
-- ---------------------------------------------------------------------
-- Hanya fungsi publik `kpi_*` yang di-grant. Fungsi internal `_kpi_*`
-- TIDAK di-grant supaya tidak bisa dipanggil langsung dari luar.
grant execute on function public.kpi_login(text, text, text, text)       to anon, authenticated;
grant execute on function public.kpi_logout(text)                         to anon, authenticated;
grant execute on function public.kpi_session_info(text)                   to anon, authenticated;
grant execute on function public.kpi_register(text, text, text)           to anon, authenticated;
grant execute on function public.kpi_change_pin(text, text, text)         to anon, authenticated;
grant execute on function public.kpi_reset_pin(text, text, text)          to anon, authenticated;
grant execute on function public.kpi_set_user_role(text, text, text)      to anon, authenticated;
grant execute on function public.kpi_set_user_active(text, text, boolean) to anon, authenticated;
grant execute on function public.kpi_get_config(text)                     to anon, authenticated;
grant execute on function public.kpi_set_config(text, text, text)         to anon, authenticated;

-- Fungsi internal (prefix _kpi_) sengaja TIDAK di-grant ke anon.
-- Pastikan juga hak default bawaan tidak bocor:
revoke all on function public._kpi_hash_pin(text, text)           from anon, authenticated;
revoke all on function public._kpi_hash_pin_legacy_v1(text)       from anon, authenticated;
revoke all on function public._kpi_pin_matches(text, text, text)  from anon, authenticated;
revoke all on function public._kpi_config(text, text)             from anon, authenticated;
revoke all on function public._kpi_purge_expired_sessions()       from anon, authenticated;
revoke all on function public._kpi_require_session(text, text[])  from anon, authenticated;

