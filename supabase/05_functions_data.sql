-- =====================================================================
-- KPI KARYAWAN - FUNGSI DATA (RPC)
-- File: supabase/05_functions_data.sql
-- ---------------------------------------------------------------------
-- Berisi pengganti seluruh fungsi di API_WHITELIST code.gs:
--   getAllData               -> kpi_get_all_data()
--   saveMultipleJobdesk      -> kpi_save_jobdesk()
--   saveAdminJobdesk         -> kpi_save_admin_jobdesk()
--   uploadPiket              -> kpi_save_piket()   (file diunggah dulu ke
--                               Storage oleh Edge Function upload-piket)
--   approveTask              -> kpi_approve_task()
--   approveAllTasks          -> kpi_approve_all_tasks()
--   deleteTask               -> kpi_delete_task()
--   updateTask               -> kpi_update_task()
--   updateTaskPoin           -> kpi_update_task_poin()
--   updateTaskStatusKerja    -> kpi_update_status_kerja()
--   updateTaskCatatan        -> kpi_update_task_catatan()
--   updateTaskPoinCatatan    -> kpi_update_task_poin_catatan()
--   deleteMultipleTasks      -> kpi_delete_multiple_tasks()
--   updateMultipleTaskStatus -> kpi_update_multiple_status()
--   saveKehadiran            -> kpi_save_kehadiran()
--   saveSeragam              -> kpi_save_seragam()
--
-- Bentuk balasan dibuat SAMA dengan code.gs: objek
-- {users, jobdesk, piket, kehadiran, seragam} sehingga frontend tidak
-- perlu diubah.
-- Jalankan setelah 04_functions_auth.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. _kpi_all_data: pengganti getAllData() + penyaringan per-role
-- ---------------------------------------------------------------------
-- Admin & Operator menerima SELURUH data, karyawan biasa hanya data
-- miliknya sendiri (persis logika getAllData() di code.gs).
create or replace function public._kpi_all_data(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess        jsonb;
  v_uid         text;
  v_role        text;
  v_full_access boolean;
  v_users       jsonb;
  v_jobdesk     jsonb;
  v_piket       jsonb;
  v_kehadiran   jsonb;
  v_seragam     jsonb;
begin
  v_sess := public._kpi_require_session(p_token);
  v_uid  := v_sess ->> 'user_id';
  v_role := v_sess ->> 'role';
  v_full_access := v_role in ('Admin', 'Operator');

  -- Daftar user (hanya identitas dasar, TANPA kolom PIN) - selalu dikirim
  -- karena dipakai untuk dropdown & leaderboard.
  select coalesce(jsonb_agg(
           jsonb_build_object('User_ID', u."User_ID", 'Nama', u."Nama", 'Role', u."Role")
           order by u."Nama"
         ), '[]'::jsonb)
    into v_users
  from public."Users" u
  where u.is_active;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'Task_ID',         j."Task_ID",
             'User_ID',         j."User_ID",
             'Tanggal',         to_char(j."Tanggal", 'YYYY-MM-DD'),
             'Deskripsi_Tugas', j."Deskripsi_Tugas",
             'Status',          j."Status",
             'Poin',            trim_scale(j."Poin"),
             'Status_Kerja',    j."Status_Kerja"
           ) order by j."Tanggal", j."Task_ID"
         ), '[]'::jsonb)
    into v_jobdesk
  from public."Jobdesk" j
  where v_full_access or j."User_ID" = v_uid;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'Schedule_ID',     p."Schedule_ID",
             'User_ID',         p."User_ID",
             'Tanggal',         to_char(p."Tanggal", 'YYYY-MM-DD'),
             'Jenis_Piket',     p."Jenis_Piket",
             'Status',          p."Status",
             'Poin',            trim_scale(p."Poin"),
             'Status_Kerja',    p."Status_Kerja",
             'Catatan_Admin',   p."Catatan_Admin"
           ) order by p."Tanggal", p."Schedule_ID"
         ), '[]'::jsonb)
    into v_piket
  from public."Piket" p
  where v_full_access or p."User_ID" = v_uid;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'Kehadiran_ID', k."Kehadiran_ID",
             'User_ID',      k."User_ID",
             'Bulan',        k."Bulan",
             'Nilai',        trim_scale(k."Nilai")
           ) order by k."Bulan", k."User_ID"
         ), '[]'::jsonb)
    into v_kehadiran
  from public."Kehadiran" k
  where v_full_access or k."User_ID" = v_uid;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'Seragam_ID', s."Seragam_ID",
             'User_ID',    s."User_ID",
             'Tanggal',    to_char(s."Tanggal", 'YYYY-MM-DD'),
             'Nilai',      trim_scale(s."Nilai"),
             'Rincian',    s."Rincian"
           ) order by s."Tanggal", s."User_ID"
         ), '[]'::jsonb)
    into v_seragam
    from public."Seragam" s
    where v_full_access or s."User_ID" = v_uid;

  return jsonb_build_object(
    'users',     v_users,
    'jobdesk',   v_jobdesk,
    'piket',     v_piket,
    'kehadiran', v_kehadiran,
    'seragam',   v_seragam
  );
end;
$$;

-- Versi publik (nama RPC yang dipanggil frontend).
create or replace function public.kpi_get_all_data(p_token text)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public._kpi_all_data(p_token);
$$;

-- ---------------------------------------------------------------------
-- 2. Helper validasi tanggal & bulan
-- ---------------------------------------------------------------------
-- Menerima 'YYYY-MM-DD' (string) atau null -> fallback hari ini.
-- Melempar error bila formatnya salah, sama seperti validasi di code.gs.
create or replace function public._kpi_parse_tanggal(p_value text, p_default_today boolean default true)
returns date
language plpgsql
stable
as $$
declare
  v text := btrim(coalesce(p_value, ''));
begin
  if v = '' then
    if p_default_today then
      return current_date;
    end if;
    raise exception 'Tanggal wajib diisi.';
  end if;
  if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
    raise exception 'Format tanggal tidak valid. Gunakan format YYYY-MM-DD.';
  end if;
  return left(v, 10)::date;
end;
$$;

-- Menerima 'YYYY-MM' -> text 'YYYY-MM' (divalidasi ketat).
create or replace function public._kpi_parse_bulan(p_value text)
returns text
language plpgsql
immutable
as $$
declare
  v text := btrim(coalesce(p_value, ''));
begin
  if v !~ '^[0-9]{4}-[0-9]{2}$' then
    raise exception 'Format bulan tidak valid. Gunakan format YYYY-MM.';
  end if;
  return v;
end;
$$;

-- Normalisasi nilai numerik (poin/nilai) dengan pesan error seragam.
create or replace function public._kpi_parse_nilai(p_value jsonb, p_label text)
returns numeric
language plpgsql
immutable
as $$
declare
  v numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return 0;
  end if;
  begin
    v := (p_value #>> '{}')::numeric;
  exception when others then
    raise exception 'Nilai % harus berupa angka.', p_label;
  end;
  if v < 0 then
    raise exception 'Nilai % harus berupa angka positif.', p_label;
  end if;
  return v;
end;
$$;

-- Parser boolean yang toleran (frontend kadang mengirim true/false, kadang
-- string 'Selesai'/'true'). Tidak pernah melempar error.
create or replace function public._kpi_bool(p_value jsonb)
returns boolean
language sql
immutable
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then false
    when jsonb_typeof(p_value) = 'boolean' then (p_value #>> '{}')::boolean
    else lower(btrim(coalesce(p_value #>> '{}', ''))) in ('true', '1', 'yes', 'ya', 'selesai')
  end;
$$;

-- ---------------------------------------------------------------------
-- 3. Simpan tugas milik sendiri: kpi_save_jobdesk
-- ---------------------------------------------------------------------
-- p_tasks = [{"deskripsi":"...","tanggal":"YYYY-MM-DD","isSelesai":true}, ...]
create or replace function public.kpi_save_jobdesk(
  p_token text,
  p_tasks jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_uid  text;
  v_item jsonb;
  v_desc text;
begin
  v_sess := public._kpi_require_session(p_token);
  v_uid  := v_sess ->> 'user_id';

  -- Tidak ada tugas yang dikirim -> cukup kembalikan data terbaru.
  if p_tasks is null
     or jsonb_typeof(p_tasks) <> 'array'
     or jsonb_array_length(p_tasks) = 0 then
    return public._kpi_all_data(p_token);
  end if;

  for v_item in select * from jsonb_array_elements(p_tasks) loop
    v_desc := left(btrim(coalesce(v_item ->> 'deskripsi', '')), 500);
    if length(v_desc) < 10 then
      raise exception 'Deskripsi tugas minimal 10 karakter.';
    end if;

    -- User_ID diambil dari SESI SERVER, bukan dari payload client
    -- (sama seperti code.gs).
    insert into public."Jobdesk"
      ("Task_ID", "User_ID", "Tanggal", "Deskripsi_Tugas", "Status", "Poin", "Status_Kerja")
    values (
      'TSK-' || gen_random_uuid(),
      v_uid,
      public._kpi_parse_tanggal(v_item ->> 'tanggal'),
      v_desc,
      'Pending',
      0,
      case when public._kpi_bool(v_item -> 'isSelesai') then 'Selesai' else 'Belum Selesai' end
    );
  end loop;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Admin menugaskan jobdesk ke karyawan: kpi_save_admin_jobdesk
-- ---------------------------------------------------------------------
-- p_data = {"targetUserId":"email@mail.com","tasks":[{"deskripsi":"..."}]}
-- Deskripsi diberi marker "[[ASSIGNED_BY:Nama Admin]] " seperti code.gs.
create or replace function public.kpi_save_admin_jobdesk(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess        jsonb;
  v_admin_id    text;
  v_admin_nama  text;
  v_target      text;
  v_tasks       jsonb;
  v_item        jsonb;
  v_desc        text;
  v_today       date := current_date;
begin
  v_sess     := public._kpi_require_session(p_token, array['Admin']);
  v_admin_id := v_sess ->> 'user_id';
  v_admin_nama := replace(left(coalesce(v_sess ->> 'nama', v_admin_id), 100), ']]', ')) ');

  v_target := btrim(coalesce(p_data ->> 'targetUserId', ''));
  if v_target = '' then
    raise exception 'Karyawan tujuan penugasan wajib dipilih.';
  end if;

  -- Pastikan target benar-benar karyawan (Role = 'User') yang aktif.
  if not exists (
    select 1 from public."Users"
    where "User_ID" = lower(v_target) and "Role" = 'User' and is_active
  ) then
    raise exception 'Karyawan tujuan tidak ditemukan atau tidak valid.';
  end if;
  v_target := lower(v_target);

  v_tasks := coalesce(p_data -> 'tasks', '[]'::jsonb);
  if jsonb_typeof(v_tasks) <> 'array' or jsonb_array_length(v_tasks) = 0 then
    raise exception 'Minimal harus ada 1 deskripsi tugas.';
  end if;

  for v_item in select * from jsonb_array_elements(v_tasks) loop
    v_desc := left(btrim(coalesce(v_item ->> 'deskripsi', '')), 500);
    if length(v_desc) < 10 then
      raise exception 'Deskripsi tugas minimal 10 karakter.';
    end if;

    insert into public."Jobdesk"
      ("Task_ID", "User_ID", "Tanggal", "Deskripsi_Tugas", "Status", "Poin", "Status_Kerja")
    values (
      'TSK-' || gen_random_uuid(),
      v_target,                       -- milik KARYAWAN, bukan admin yang login
      v_today,                        -- selalu hari ini, seperti code.gs
      '[[ASSIGNED_BY:' || v_admin_nama || ']] ' || v_desc,
      'Pending',
      0,
      'Belum Selesai'
    );
  end loop;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Simpan laporan piket: kpi_save_piket
-- ---------------------------------------------------------------------
-- p_data = {"tanggal":"YYYY-MM-DD","jenis":"Lantai 1","isSelesai":true}
create or replace function public.kpi_save_piket(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess     jsonb;
  v_uid      text;
  v_jenis    text;
begin
  v_sess := public._kpi_require_session(p_token);
  v_uid  := v_sess ->> 'user_id';

  v_jenis := left(btrim(coalesce(p_data ->> 'jenis', '')), 100);
  if v_jenis = '' then
    raise exception 'Area piket wajib dipilih.';
  end if;

  insert into public."Piket"
    ("Schedule_ID", "User_ID", "Tanggal", "Jenis_Piket", "Status",
     "Poin", "Status_Kerja")
  values (
    'PKT-' || gen_random_uuid(),
    v_uid,
    public._kpi_parse_tanggal(p_data ->> 'tanggal'),
    v_jenis,
    'Pending',
    0,
    case when public._kpi_bool(p_data -> 'isSelesai') then 'Selesai' else 'Belum Selesai' end
  );

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Setujui satu laporan: kpi_approve_task
-- ---------------------------------------------------------------------
-- p_data = {"id":"TSK-.../PKT-...","poin":10,"catatan":"..."}
-- Operator hanya boleh menyetujui laporan PIKET (dicek di server).
create or replace function public.kpi_approve_task(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess    jsonb;
  v_role    text;
  v_id      text := btrim(coalesce(p_data ->> 'id', ''));
  v_is_task boolean;
  v_poin    numeric;
  v_has_cat boolean;
  v_catatan text;
begin
  v_sess := public._kpi_require_session(p_token, array['Admin', 'Operator']);
  v_role := v_sess ->> 'role';

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;
  v_is_task := v_id like 'TSK%';
  if v_role = 'Operator' and v_is_task then
    raise exception 'Operator hanya dapat menyetujui laporan piket.';
  end if;

  v_poin := public._kpi_parse_nilai(p_data -> 'poin', 'poin');
  v_has_cat := (not v_is_task)
               and (p_data ? 'catatan')
               and jsonb_typeof(p_data -> 'catatan') <> 'null';
  v_catatan := case when v_has_cat
                    then left(btrim(coalesce(p_data ->> 'catatan', '')), 500)
                    else null end;

  if v_is_task then
    update public."Jobdesk"
       set "Status" = 'Approved', "Poin" = v_poin
     where "Task_ID" = v_id;
    if not found then
      raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
    end if;
  else
    update public."Piket"
       set "Status" = 'Approved',
           "Poin" = v_poin,
           "Catatan_Admin" = case when v_has_cat then v_catatan else "Catatan_Admin" end
     where "Schedule_ID" = v_id;
    if not found then
      raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
    end if;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Setujui banyak laporan sekaligus: kpi_approve_all_tasks
-- ---------------------------------------------------------------------
-- p_tasks = [{"id":"TSK-...","poin":10}, {"id":"PKT-...","poin":5,"catatan":"..."}]
create or replace function public.kpi_approve_all_tasks(
  p_token text,
  p_tasks jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess    jsonb;
  v_role    text;
  v_item    jsonb;
  v_id      text;
  v_poin    numeric;
  v_has_cat boolean;
  v_catatan text;
begin
  v_sess := public._kpi_require_session(p_token, array['Admin', 'Operator']);
  v_role := v_sess ->> 'role';

  if p_tasks is null
     or jsonb_typeof(p_tasks) <> 'array'
     or jsonb_array_length(p_tasks) = 0 then
    return public._kpi_all_data(p_token);
  end if;

  -- Operator hanya boleh menyetujui laporan piket; kalau ada ID TSK
  -- menyelinap di payload, batalkan SELURUH operasi (atomik).
  if v_role = 'Operator' and exists (
    select 1
    from jsonb_array_elements(p_tasks) as e(value)
    where coalesce(e.value ->> 'id', '') like 'TSK%'
  ) then
    raise exception 'Operator hanya dapat menyetujui laporan piket.';
  end if;

  for v_item in select * from jsonb_array_elements(p_tasks) loop
    v_id := btrim(coalesce(v_item ->> 'id', ''));
    if v_id = '' then
      continue;
    end if;

    v_poin  := public._kpi_parse_nilai(v_item -> 'poin', 'poin');
    v_has_cat := (v_id not like 'TSK%')
                 and (v_item ? 'catatan')
                 and jsonb_typeof(v_item -> 'catatan') <> 'null';
    v_catatan := case when v_has_cat
                      then left(btrim(coalesce(v_item ->> 'catatan', '')), 500)
                      else null end;

    if v_id like 'TSK%' then
      update public."Jobdesk"
         set "Status" = 'Approved', "Poin" = v_poin
       where "Task_ID" = v_id;
    else
      update public."Piket"
         set "Status" = 'Approved',
             "Poin" = v_poin,
             "Catatan_Admin" = case when v_has_cat then v_catatan else "Catatan_Admin" end
       where "Schedule_ID" = v_id;
    end if;
  end loop;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Hapus satu laporan: kpi_delete_task
-- ---------------------------------------------------------------------
-- Karyawan biasa hanya boleh menghapus laporan miliknya sendiri yang
-- masih Pending; Admin boleh menghapus apa pun (sama seperti code.gs).
create or replace function public.kpi_delete_task(
  p_token text,
  p_id    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_role text;
  v_uid  text;
  v_id   text := btrim(coalesce(p_id, ''));
  v_row  record;
begin
  v_sess := public._kpi_require_session(p_token);
  v_role := v_sess ->> 'role';
  v_uid  := v_sess ->> 'user_id';

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;

  if v_id like 'TSK%' then
    select "User_ID" as owner, "Status" as status into v_row
    from public."Jobdesk" where "Task_ID" = v_id;
  else
    select "User_ID" as owner, "Status" as status into v_row
    from public."Piket" where "Schedule_ID" = v_id;
  end if;

  if v_row is null then
    return public._kpi_all_data(p_token);   -- sudah tidak ada, anggap sukses
  end if;

  if v_role <> 'Admin' then
    if v_row.owner <> v_uid then
      raise exception 'Anda tidak boleh menghapus laporan milik orang lain.';
    end if;
    if v_row.status = 'Approved' then
      raise exception 'Laporan yang sudah disetujui tidak bisa dihapus.';
    end if;
  end if;

  if v_id like 'TSK%' then
    delete from public."Jobdesk" where "Task_ID" = v_id;
  else
    delete from public."Piket" where "Schedule_ID" = v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Ubah deskripsi tugas: kpi_update_task
-- ---------------------------------------------------------------------
-- p_data = {"id":"TSK-...","type":"Task"|"Piket","val":"deskripsi baru"}
create or replace function public.kpi_update_task(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_role text;
  v_uid  text;
  v_id   text := btrim(coalesce(p_data ->> 'id', ''));
  v_type text := lower(btrim(coalesce(p_data ->> 'type', '')));
  v_val  text;
  v_row  record;
begin
  v_sess := public._kpi_require_session(p_token);
  v_role := v_sess ->> 'role';
  v_uid  := v_sess ->> 'user_id';

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;

  -- Tipe diutamakan dari payload; kalau kosong ditebak dari prefix ID.
  if v_type = '' then
    v_type := case when v_id like 'TSK%' then 'task' else 'piket' end;
  end if;

  if v_type = 'task' then
    select "User_ID" as owner, "Status" as status into v_row
    from public."Jobdesk" where "Task_ID" = v_id;
  else
    select "User_ID" as owner, "Status" as status into v_row
    from public."Piket" where "Schedule_ID" = v_id;
  end if;

  if v_row is null then
    raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
  end if;

  if v_role <> 'Admin' then
    if v_row.owner <> v_uid then
      raise exception 'Anda tidak boleh mengubah laporan milik orang lain.';
    end if;
    if v_row.status = 'Approved' then
      raise exception 'Laporan yang sudah disetujui tidak bisa diubah.';
    end if;
  end if;

  -- Sama seperti code.gs: fungsi ini SELALU menulis ke kolom deskripsi
  -- Jobdesk (kolom ke-4). Untuk Piket kolom ke-4 adalah Jenis_Piket yang
  -- tidak pernah diubah lewat jalur ini, jadi permintaan Piket ditolak
  -- supaya tidak salah tulis.
  if v_type <> 'task' then
    raise exception 'Kolom deskripsi hanya tersedia untuk laporan tugas.';
  end if;

  v_val := left(btrim(coalesce(p_data ->> 'val', '')), 500);
  if length(v_val) < 10 then
    raise exception 'Deskripsi tugas minimal 10 karakter.';
  end if;

  update public."Jobdesk" set "Deskripsi_Tugas" = v_val where "Task_ID" = v_id;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Admin mengubah poin: kpi_update_task_poin
-- ---------------------------------------------------------------------
-- p_data = {"id":"...","type":"Task"|"Piket","poin":10}
create or replace function public.kpi_update_task_poin(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   text := btrim(coalesce(p_data ->> 'id', ''));
  v_type text;
  v_poin numeric;
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;
  v_type := public._kpi_resolve_type(p_data ->> 'type', v_id);
  v_poin := public._kpi_parse_nilai(p_data -> 'poin', 'poin');

  if v_type = 'Task' then
    update public."Jobdesk" set "Poin" = v_poin where "Task_ID" = v_id;
    if not found then
      raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
    end if;
  else
    update public."Piket" set "Poin" = v_poin where "Schedule_ID" = v_id;
    if not found then
      raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
    end if;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Ubah status kerja: kpi_update_status_kerja
-- ---------------------------------------------------------------------
-- p_data = {"id":"...","type":"Task"|"Piket","isSelesai":true}
create or replace function public.kpi_update_status_kerja(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_role text;
  v_uid  text;
  v_id   text := btrim(coalesce(p_data ->> 'id', ''));
  v_type text;
  v_owner text;
  v_status_kerja text;
begin
  v_sess := public._kpi_require_session(p_token);
  v_role := v_sess ->> 'role';
  v_uid  := v_sess ->> 'user_id';

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;
  v_type := public._kpi_resolve_type(p_data ->> 'type', v_id);
  v_status_kerja := case when public._kpi_bool(p_data -> 'isSelesai')
                         then 'Selesai' else 'Belum Selesai' end;

  if v_type = 'Task' then
    select "User_ID" into v_owner from public."Jobdesk" where "Task_ID" = v_id;
  else
    select "User_ID" into v_owner from public."Piket" where "Schedule_ID" = v_id;
  end if;

  if v_owner is null then
    raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
  end if;
  if v_role <> 'Admin' and v_owner <> v_uid then
    raise exception 'Anda tidak boleh mengubah laporan milik orang lain.';
  end if;

  if v_type = 'Task' then
    update public."Jobdesk" set "Status_Kerja" = v_status_kerja where "Task_ID" = v_id;
  else
    update public."Piket" set "Status_Kerja" = v_status_kerja where "Schedule_ID" = v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Helper penentu jenis laporan ('Task' atau 'Piket')
-- ---------------------------------------------------------------------
-- Frontend mengirim type='Task' untuk jobdesk dan selain itu untuk piket.
-- Kalau type kosong/tidak dikenal, ditebak dari prefix ID (TSK- / PKT-).
create or replace function public._kpi_resolve_type(p_type text, p_id text)
returns text
language sql
immutable
as $$
  select case
    when lower(btrim(coalesce(p_type, ''))) in ('task', 'tsk', 'jobdesk') then 'Task'
    when lower(btrim(coalesce(p_type, ''))) in ('piket', 'pkt', 'schedule') then 'Piket'
    when coalesce(p_id, '') like 'TSK%' then 'Task'
    else 'Piket'
  end;
$$;

-- Sama seperti di atas, tapi mengembalikan nama tabel sekaligus
-- mempermudah penulisan query generik.
create or replace function public._kpi_type_is_task(p_type text, p_id text)
returns boolean
language sql
immutable
as $$
  select public._kpi_resolve_type(p_type, p_id) = 'Task';
$$;

-- ---------------------------------------------------------------------
-- 13. Catatan manual piket: kpi_update_task_catatan
-- ---------------------------------------------------------------------
-- p_data = {"id":"PKT-...","catatan":"lantainya kurang bersih"}
-- Admin & Operator boleh mengisi catatan; selalu menulis ke tabel Piket.
create or replace function public.kpi_update_task_catatan(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id      text := btrim(coalesce(p_data ->> 'id', ''));
  v_catatan text := left(btrim(coalesce(p_data ->> 'catatan', '')), 500);
begin
  perform public._kpi_require_session(p_token, array['Admin', 'Operator']);

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;

  update public."Piket"
     set "Catatan_Admin" = v_catatan
   where "Schedule_ID" = v_id;

  if not found then
    raise exception 'Laporan piket dengan ID % tidak ditemukan.', v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Poin + catatan sekaligus: kpi_update_task_poin_catatan
-- ---------------------------------------------------------------------
-- p_data = {"id":"...","type":"Task"|"Piket","poin":10,"catatan":"...","deskripsi":"..."}
-- - Untuk Task: opsional mengganti Deskripsi_Tugas (minimal 10 karakter).
-- - Untuk Piket: "deskripsi" tidak diterima.
create or replace function public.kpi_update_task_poin_catatan(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id      text := btrim(coalesce(p_data ->> 'id', ''));
  v_type    text;
  v_poin    numeric;
  v_has_cat boolean;
  v_catatan text;
  v_deskripsi text;
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  if v_id = '' then
    raise exception 'ID laporan wajib diisi.';
  end if;

  v_type    := public._kpi_resolve_type(p_data ->> 'type', v_id);
  v_poin    := public._kpi_parse_nilai(p_data -> 'poin', 'poin');
  v_has_cat := (v_type = 'Piket')
               and (p_data ? 'catatan')
               and jsonb_typeof(p_data -> 'catatan') <> 'null';
  v_catatan := case when v_has_cat
                    then left(btrim(coalesce(p_data ->> 'catatan', '')), 500)
                    else null end;

  if v_type = 'Task' then
    if p_data ? 'deskripsi' and jsonb_typeof(p_data -> 'deskripsi') <> 'null' then
      v_deskripsi := left(btrim(coalesce(p_data ->> 'deskripsi', '')), 1000);
      if length(v_deskripsi) < 10 then
        raise exception 'Deskripsi minimal 10 karakter.';
      end if;
    end if;
    update public."Jobdesk"
       set "Poin" = v_poin,
           "Deskripsi_Tugas" = coalesce(v_deskripsi, "Deskripsi_Tugas")
     where "Task_ID" = v_id;
  else
    if p_data ? 'deskripsi' and jsonb_typeof(p_data -> 'deskripsi') <> 'null' then
      raise exception 'Tipe Piket tidak boleh mengganti deskripsi tugas.';
    end if;
    update public."Piket"
       set "Poin" = v_poin,
           "Catatan_Admin" = case when v_has_cat then v_catatan else "Catatan_Admin" end
     where "Schedule_ID" = v_id;
  end if;

  if not found then
    raise exception 'Laporan dengan ID % tidak ditemukan.', v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 15. Hapus banyak laporan: kpi_delete_multiple_tasks
-- ---------------------------------------------------------------------
-- p_ids = ["TSK-...", "PKT-..."]
-- Karyawan biasa hanya boleh menghapus barisnya sendiri yang belum
-- Approved; baris yang tidak diizinkan dilewati (bukan error), persis
-- perilaku deleteMultipleTasks() di code.gs.
create or replace function public.kpi_delete_multiple_tasks(
  p_token text,
  p_ids   jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_role text;
  v_uid  text;
  v_ids  text[];
begin
  v_sess := public._kpi_require_session(p_token);
  v_role := v_sess ->> 'role';
  v_uid  := v_sess ->> 'user_id';

  if p_ids is null
     or jsonb_typeof(p_ids) <> 'array'
     or jsonb_array_length(p_ids) = 0 then
    return public._kpi_all_data(p_token);
  end if;

  select coalesce(array_agg(btrim(t.id)), '{}')
    into v_ids
  from jsonb_array_elements_text(p_ids) as t(id)
  where btrim(t.id) <> '';

  delete from public."Jobdesk"
   where "Task_ID" = any (v_ids)
     and (v_role = 'Admin' or ("User_ID" = v_uid and "Status" <> 'Approved'));

  delete from public."Piket"
   where "Schedule_ID" = any (v_ids)
     and (v_role = 'Admin' or ("User_ID" = v_uid and "Status" <> 'Approved'));

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 16. Tandai banyak laporan selesai: kpi_update_multiple_status
-- ---------------------------------------------------------------------
-- p_ids = ["TSK-...", "PKT-..."] -> semua Status_Kerja jadi 'Selesai'
-- (hanya untuk baris milik sendiri, kecuali Admin).
create or replace function public.kpi_update_multiple_status(
  p_token text,
  p_ids   jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sess jsonb;
  v_role text;
  v_uid  text;
  v_ids  text[];
begin
  v_sess := public._kpi_require_session(p_token);
  v_role := v_sess ->> 'role';
  v_uid  := v_sess ->> 'user_id';

  if p_ids is null
     or jsonb_typeof(p_ids) <> 'array'
     or jsonb_array_length(p_ids) = 0 then
    return public._kpi_all_data(p_token);
  end if;

  select coalesce(array_agg(btrim(t.id)), '{}')
    into v_ids
  from jsonb_array_elements_text(p_ids) as t(id)
  where btrim(t.id) <> '';

  update public."Jobdesk"
     set "Status_Kerja" = 'Selesai'
   where "Task_ID" = any (v_ids)
     and (v_role = 'Admin' or "User_ID" = v_uid);

  update public."Piket"
     set "Status_Kerja" = 'Selesai'
   where "Schedule_ID" = any (v_ids)
     and (v_role = 'Admin' or "User_ID" = v_uid);

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 17. Nilai kehadiran: kpi_save_kehadiran (Admin & Operator)
-- ---------------------------------------------------------------------
-- p_data = {"userId":"email@mail.com","bulan":"YYYY-MM","nilai":10}
-- Kombinasi User_ID + Bulan bersifat UNIQUE, jadi cukup UPSERT
-- (menggantikan loop "cari lalu update / append" di code.gs).
create or replace function public.kpi_save_kehadiran(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   text := lower(btrim(coalesce(p_data ->> 'userId', '')));
  v_bulan text;
  v_nilai numeric;
begin
  perform public._kpi_require_session(p_token, array['Admin', 'Operator']);

  if v_uid = '' then
    raise exception 'Karyawan wajib dipilih.';
  end if;
  v_bulan := public._kpi_parse_bulan(p_data ->> 'bulan');
  v_nilai := public._kpi_parse_nilai(p_data -> 'nilai', 'kehadiran');

  if not exists (select 1 from public."Users" where "User_ID" = v_uid) then
    raise exception 'Karyawan tidak ditemukan.';
  end if;

  insert into public."Kehadiran" ("Kehadiran_ID", "User_ID", "Bulan", "Nilai")
  values ('KHD-' || gen_random_uuid(), v_uid, v_bulan, v_nilai)
  on conflict ("User_ID", "Bulan") do update
    set "Nilai" = excluded."Nilai";

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 18. Penilaian kedisiplinan: kpi_save_seragam (Admin & Operator)
-- ---------------------------------------------------------------------
-- p_data = {"userIds":["a@mail.com","b@mail.com"],"tanggal":"YYYY-MM-DD","nilai":1,"rincian":{"rapi_lengkap":true,"parkir":false,"alas_kaki":true}}
-- Nilai dihitung ulang dari rincian bila rincian dikirim (1 poin per item).
-- Backward compatible: tanpa rincian, nilai tetap dibaca dari payload.
create or replace function public.kpi_save_seragam(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tanggal date;
  v_nilai   numeric;
  v_ids     text[];
  v_bad     text;
  v_rincian jsonb;
begin
  perform public._kpi_require_session(p_token, array['Admin', 'Operator']);

  select coalesce(array_agg(distinct lower(btrim(t.id))), '{}')
    into v_ids
  from jsonb_array_elements_text(
         case
           when jsonb_typeof(p_data -> 'userIds') = 'array'  then p_data -> 'userIds'
           when jsonb_typeof(p_data -> 'userId')  = 'string' then jsonb_build_array(p_data -> 'userId')
           else '[]'::jsonb
         end
       ) as t(id)
  where btrim(t.id) <> '';

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'Minimal 1 karyawan wajib dipilih.';
  end if;

  v_tanggal := public._kpi_parse_tanggal(p_data ->> 'tanggal');

  if p_data ? 'rincian' and jsonb_typeof(p_data -> 'rincian') = 'object' then
    v_rincian := p_data -> 'rincian';
    if array(select jsonb_object_keys(v_rincian)) <@ array['rapi_lengkap','parkir','alas_kaki'] then
      if jsonb_typeof(v_rincian -> 'rapi_lengkap') <> 'boolean'
         or jsonb_typeof(v_rincian -> 'parkir') <> 'boolean'
         or jsonb_typeof(v_rincian -> 'alas_kaki') <> 'boolean' then
        raise exception 'Rincian kedisiplinan harus berupa boolean.';
      end if;
    else
      raise exception 'Key rincian kedisiplinan tidak diizinkan.';
    end if;
    v_nilai := (case when (v_rincian ->> 'rapi_lengkap')::boolean then 1 else 0 end
              + case when (v_rincian ->> 'parkir')::boolean then 1 else 0 end
              + case when (v_rincian ->> 'alas_kaki')::boolean then 1 else 0 end) * 1;
  else
    v_nilai := case
                 when p_data ? 'nilai' then public._kpi_parse_nilai(p_data -> 'nilai', 'kedisiplinan')
                 else 0
               end;
  end if;

  select x.id into v_bad
  from unnest(v_ids) as x(id)
  where not exists (select 1 from public."Users" u where u."User_ID" = x.id)
  limit 1;
  if v_bad is not null then
    raise exception 'Karyawan tidak ditemukan: %', v_bad;
  end if;

  insert into public."Seragam" ("Seragam_ID", "User_ID", "Tanggal", "Nilai", "Rincian")
  select 'SRG-' || gen_random_uuid(), x.id, v_tanggal, v_nilai, v_rincian
  from unnest(v_ids) as x(id)
  on conflict ("User_ID", "Tanggal") do update
    set "Nilai" = excluded."Nilai",
        "Rincian" = excluded."Rincian";

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 19. Edit poin kedisiplinan: kpi_update_seragam_poin
-- ---------------------------------------------------------------------
-- p_data = {"id":"SRG-...","poin":1,"rincian":{"rapi_lengkap":true,"parkir":false,"alas_kaki":true}}
-- Bila rincian dikirim, nilai dihitung ulang (1 poin per item true).
create or replace function public.kpi_update_seragam_poin(
  p_token text,
  p_data  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id      text := btrim(coalesce(p_data ->> 'id', ''));
  v_nilai   numeric;
  v_rincian jsonb;
begin
  perform public._kpi_require_session(p_token, array['Admin', 'Operator']);

  if v_id = '' then
    raise exception 'ID kedisiplinan wajib diisi.';
  end if;

  if p_data ? 'rincian' and jsonb_typeof(p_data -> 'rincian') = 'object' then
    v_rincian := p_data -> 'rincian';
    if array(select jsonb_object_keys(v_rincian)) <@ array['rapi_lengkap','parkir','alas_kaki'] then
      if jsonb_typeof(v_rincian -> 'rapi_lengkap') <> 'boolean'
         or jsonb_typeof(v_rincian -> 'parkir') <> 'boolean'
         or jsonb_typeof(v_rincian -> 'alas_kaki') <> 'boolean' then
        raise exception 'Rincian kedisiplinan harus berupa boolean.';
      end if;
    else
      raise exception 'Key rincian kedisiplinan tidak diizinkan.';
    end if;
    v_nilai := (case when (v_rincian ->> 'rapi_lengkap')::boolean then 1 else 0 end
              + case when (v_rincian ->> 'parkir')::boolean then 1 else 0 end
              + case when (v_rincian ->> 'alas_kaki')::boolean then 1 else 0 end) * 1;
  else
    v_nilai := public._kpi_parse_nilai(p_data -> 'poin', 'kedisiplinan');
  end if;

  update public."Seragam"
     set "Nilai" = v_nilai,
         "Rincian" = v_rincian,
         updated_at = now()
   where "Seragam_ID" = v_id;

  if not found then
    raise exception 'Inputan kedisiplinan dengan ID % tidak ditemukan.', v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 20. Hapus inputan kedisiplinan: kpi_delete_seragam
-- ---------------------------------------------------------------------
-- p_id = "SRG-..."
create or replace function public.kpi_delete_seragam(
  p_token text,
  p_id    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id text := btrim(coalesce(p_id, ''));
begin
  perform public._kpi_require_session(p_token, array['Admin', 'Operator']);

  if v_id = '' then
    raise exception 'ID kedisiplinan wajib diisi.';
  end if;

  delete from public."Seragam"
   where "Seragam_ID" = v_id;

  if not found then
    raise exception 'Inputan kedisiplinan dengan ID % tidak ditemukan.', v_id;
  end if;

  return public._kpi_all_data(p_token);
end;
$$;

-- =====================================================================
-- 21. HAK AKSES (GRANT) untuk seluruh RPC data
-- =====================================================================
grant execute on function public.kpi_get_all_data(text)                     to anon, authenticated;
grant execute on function public.kpi_save_jobdesk(text, jsonb)              to anon, authenticated;
grant execute on function public.kpi_save_admin_jobdesk(text, jsonb)        to anon, authenticated;
grant execute on function public.kpi_save_piket(text, jsonb)                to anon, authenticated;
grant execute on function public.kpi_approve_task(text, jsonb)              to anon, authenticated;
grant execute on function public.kpi_approve_all_tasks(text, jsonb)         to anon, authenticated;
grant execute on function public.kpi_delete_task(text, text)                to anon, authenticated;
grant execute on function public.kpi_update_task(text, jsonb)               to anon, authenticated;
grant execute on function public.kpi_update_task_poin(text, jsonb)          to anon, authenticated;
grant execute on function public.kpi_update_status_kerja(text, jsonb)       to anon, authenticated;
grant execute on function public.kpi_update_task_catatan(text, jsonb)       to anon, authenticated;
grant execute on function public.kpi_update_task_poin_catatan(text, jsonb)  to anon, authenticated;
grant execute on function public.kpi_delete_multiple_tasks(text, jsonb)     to anon, authenticated;
grant execute on function public.kpi_update_multiple_status(text, jsonb)    to anon, authenticated;
grant execute on function public.kpi_save_kehadiran(text, jsonb)            to anon, authenticated;
grant execute on function public.kpi_save_seragam(text, jsonb)              to anon, authenticated;
grant execute on function public.kpi_update_seragam_poin(text, jsonb)         to anon, authenticated;
grant execute on function public.kpi_delete_seragam(text, text)               to anon, authenticated;

-- Fungsi internal: jangan pernah bisa dipanggil dari luar.
revoke all on function public._kpi_all_data(text)               from anon, authenticated;
revoke all on function public._kpi_parse_tanggal(text, boolean) from anon, authenticated;
revoke all on function public._kpi_parse_bulan(text)            from anon, authenticated;
revoke all on function public._kpi_parse_nilai(jsonb, text)     from anon, authenticated;
revoke all on function public._kpi_bool(jsonb)                  from anon, authenticated;
revoke all on function public._kpi_resolve_type(text, text)     from anon, authenticated;
revoke all on function public._kpi_type_is_task(text, text)     from anon, authenticated;