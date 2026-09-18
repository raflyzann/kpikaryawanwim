-- =====================================================================
-- KPI KARYAWAN - AUDIT LOG (opsional tapi disarankan)
-- File: supabase/06_audit_log.sql
-- ---------------------------------------------------------------------
-- Menjawab rekomendasi "Audit log / riwayat perubahan" (Prioritas 4):
-- siapa mengubah poin/status apa dan kapan.
--
-- Cara kerja:
--  * Trigger BEFORE UPDATE / AFTER INSERT / AFTER DELETE pada tabel data.
--  * Pelaku diambil dari `current_setting('kpi.actor', true)` yang di-set
--    otomatis oleh _kpi_require_session() pada setiap pemanggilan RPC.
--    Kalau perubahan terjadi di luar RPC (mis. lewat SQL Editor), kolom
--    actor berisi 'system'.
--  * Kolom PIN pada tabel Users TIDAK PERNAH disimpan ke log.
--
-- Jalankan setelah 05_functions_data.sql.
-- =====================================================================

create table if not exists public."Activity_Log" (
  id          bigserial primary key,
  actor       text,
  action      text not null,             -- INSERT / UPDATE / DELETE
  entity      text not null,             -- Jobdesk / Piket / Kehadiran / Seragam / Users / Config
  entity_id   text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);

comment on table public."Activity_Log" is 'Jejak audit semua perubahan data KPI (siapa, apa, kapan).';

create index if not exists idx_activity_log_created on public."Activity_Log" (created_at desc);
create index if not exists idx_activity_log_entity  on public."Activity_Log" (entity, entity_id);
create index if not exists idx_activity_log_actor   on public."Activity_Log" (actor);

alter table public."Activity_Log" enable row level security;
revoke all on all tables in schema public from anon, authenticated;   -- pastikan tetap tertutup

-- ---------------------------------------------------------------------
-- Fungsi trigger
-- ---------------------------------------------------------------------
create or replace function public.log_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_action text := tg_op;
  v_old    jsonb;
  v_new    jsonb;
  v_id     text;
  v_actor  text := coalesce(nullif(current_setting('kpi.actor', true), ''), 'system');
begin
  v_old := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_new := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;

  -- Kunci identitas per tabel.
  v_id := coalesce(
    v_new ->> 'Task_ID',
    v_new ->> 'Schedule_ID',
    v_new ->> 'Kehadiran_ID',
    v_new ->> 'Seragam_ID',
    v_new ->> 'User_ID',
    v_new ->> 'Key',
    v_old ->> 'Task_ID',
    v_old ->> 'Schedule_ID',
    v_old ->> 'Kehadiran_ID',
    v_old ->> 'Seragam_ID',
    v_old ->> 'User_ID',
    v_old ->> 'Key'
  );

  -- Jangan pernah menulis hash PIN ke log.
  if tg_table_name = 'Users' then
    v_old := v_old - 'PIN' - 'auth_user_id';
    v_new := v_new - 'PIN' - 'auth_user_id';
  end if;

  insert into public."Activity_Log" (actor, action, entity, entity_id, old_data, new_data)
  values (v_actor, v_action, tg_table_name, v_id, v_old, v_new);

  return coalesce(new, old);
end;
$$;

-- ---------------------------------------------------------------------
-- Pasang trigger ke tabel data
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['Users', 'Jobdesk', 'Piket', 'Kehadiran', 'Seragam', 'Config'] loop
    execute format('drop trigger if exists trg_%1$s_audit on public.%1$I', t);
    execute format(
      'create trigger trg_%1$s_audit
         after insert or update or delete on public.%1$I
         for each row execute function public.log_activity()', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- RPC: hanya Admin yang boleh membaca log
-- ---------------------------------------------------------------------
-- p_limit = jumlah baris terakhir yang diambil (default 200, maks 1000).
create or replace function public.kpi_get_activity_log(
  p_token text,
  p_limit int default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
begin
  perform public._kpi_require_session(p_token, array['Admin']);

  return coalesce((
    select jsonb_agg(x.row_json order by x.created_at desc)
    from (
      select
        l.created_at,
        jsonb_build_object(
          'id',         l.id,
          'actor',      l.actor,
          'action',     l.action,
          'entity',     l.entity,
          'entity_id',  l.entity_id,
          'old_data',   l.old_data,
          'new_data',   l.new_data,
          'created_at', l.created_at
        ) as row_json
      from public."Activity_Log" l
      order by l.created_at desc
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.kpi_get_activity_log(text, int) to anon, authenticated;
revoke all on function public.log_activity() from anon, authenticated;

-- Catatan: tabel Activity_Log sengaja hanya bisa dibaca lewat RPC di atas
-- (RLS tanpa policy + tidak ada grant langsung ke anon).