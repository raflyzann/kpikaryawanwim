-- =====================================================================
-- KPI KARYAWAN - ADMIN: KELOLA KARYAWAN (RPC)
-- File: supabase/07_functions_admin_user.sql
-- Jalankan SETELAH 07_migrations_user_cascade.sql berhasil
-- =====================================================================

-- 1. Tambah karyawan baru (hanya Admin)
create or replace function public.kpi_admin_add_user(
  p_token text,
  p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_nama text;
  v_email text;
  v_pin text;
  v_hash text;
begin
  v_sess := public._kpi_require_session(p_token, array['Admin']);

  v_nama := btrim(coalesce(p_data ->> 'nama', ''));
  v_email := lower(btrim(coalesce(p_data ->> 'email', '')));
  v_pin := btrim(coalesce(p_data ->> 'pin', ''));

  if v_nama = '' then
    raise exception 'Nama karyawan wajib diisi.';
  end if;
  if v_email = '' or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'Format email tidak valid.';
  end if;
  if v_pin !~ '^\d{6}$' then
    raise exception 'PIN harus tepat 6 digit angka.';
  end if;

  if exists (select 1 from public."Users" where "User_ID" = v_email) then
    raise exception 'Email sudah terdaftar.';
  end if;

  v_hash := public._kpi_hash_pin(v_pin, v_email);

  insert into public."Users" ("User_ID", "Nama", "Role", "PIN")
  values (v_email, v_nama, 'User', v_hash);

  return public._kpi_all_data(p_token);
end;
$$;

grant execute on function public.kpi_admin_add_user(text, jsonb) to anon, authenticated;

-- 2. Edit nama/email karyawan (hanya Admin, hanya Role = User)
create or replace function public.kpi_admin_update_user(
  p_token text,
  p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess      jsonb;
  v_old_email text;
  v_new_email text;
  v_nama      text;
  v_role      text;
begin
  v_sess := public._kpi_require_session(p_token, array['Admin']);

  v_old_email := lower(btrim(coalesce(p_data ->> 'userId', '')));
  v_new_email := lower(btrim(coalesce(p_data ->> 'email', '')));
  v_nama := btrim(coalesce(p_data ->> 'nama', ''));

  if v_old_email = '' then
    raise exception 'User_ID lama wajib diisi.';
  end if;
  if v_new_email = '' or v_new_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'Format email baru tidak valid.';
  end if;
  if v_nama = '' or length(v_nama) < 3 then
    raise exception 'Nama harus minimal 3 karakter.';
  end if;

  select "Role" into v_role from public."Users" where "User_ID" = v_old_email;
  if not found then
    raise exception 'Karyawan dengan email % tidak ditemukan.', v_old_email;
  end if;
  if v_role <> 'User' then
    raise exception 'Hanya karyawan dengan role User yang bisa diubah lewat menu ini.';
  end if;

  if v_new_email <> v_old_email and exists (
    select 1 from public."Users" where "User_ID" = v_new_email
  ) then
    raise exception 'Email % sudah digunakan oleh akun lain.', v_new_email;
  end if;

  update public."Users"
     set "User_ID" = v_new_email,
         "Nama"    = v_nama,
         updated_at = now()
   where "User_ID" = v_old_email;

  if not found then
    raise exception 'Gagal memperbarui data karyawan.';
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

grant execute on function public.kpi_admin_update_user(text, jsonb) to anon, authenticated;

-- 3. Hapus karyawan beserta seluruh datanya (hanya Admin, hanya Role = User)
create or replace function public.kpi_admin_delete_user(
  p_token text,
  p_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_uid  text;
  v_nama text;
  v_role text;
begin
  v_sess := public._kpi_require_session(p_token, array['Admin']);
  v_uid := v_sess ->> 'user_id';

  if p_id is null or btrim(p_id) = '' then
    raise exception 'ID karyawan wajib diisi.';
  end if;

  select "Nama", "Role" into v_nama, v_role
  from public."Users"
  where "User_ID" = p_id;

  if not found then
    raise exception 'Karyawan dengan email % tidak ditemukan.', p_id;
  end if;

  if v_role <> 'User' then
    raise exception 'Hanya karyawan dengan role User yang bisa dihapus lewat menu ini.';
  end if;

  if p_id = v_uid then
    raise exception 'Anda tidak bisa menghapus akun sendiri.';
  end if;

  delete from public."Users" where "User_ID" = p_id;

  return public._kpi_all_data(p_token);
end;
$$;

grant execute on function public.kpi_admin_delete_user(text, text) to anon, authenticated;