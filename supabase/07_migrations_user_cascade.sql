-- =====================================================================
-- MIGRASI: ON UPDATE CASCADE untuk foreign key User_ID
-- File: supabase/07_migrations_user_cascade.sql
-- Jalankan SETELAH 01_schema.sql
-- =====================================================================

-- 1. Drop constraint lama (jika ada) tanpa DO-block
ALTER TABLE IF EXISTS public."Jobdesk"    DROP CONSTRAINT IF EXISTS jobdesk_user_id_fkey;
ALTER TABLE IF EXISTS public."Piket"      DROP CONSTRAINT IF EXISTS piket_user_id_fkey;
ALTER TABLE IF EXISTS public."Kehadiran"  DROP CONSTRAINT IF EXISTS kehadiran_user_id_fkey;
ALTER TABLE IF EXISTS public."Seragam"    DROP CONSTRAINT IF EXISTS seragam_user_id_fkey;
ALTER TABLE IF EXISTS public."Sessions"   DROP CONSTRAINT IF EXISTS sessions_user_id_fkey;

-- 2. Recreate dengan ON DELETE CASCADE + ON UPDATE CASCADE
ALTER TABLE public."Jobdesk"
  ADD CONSTRAINT jobdesk_user_id_fkey
    FOREIGN KEY ("User_ID") REFERENCES public."Users" ("User_ID")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public."Piket"
  ADD CONSTRAINT piket_user_id_fkey
    FOREIGN KEY ("User_ID") REFERENCES public."Users" ("User_ID")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public."Kehadiran"
  ADD CONSTRAINT kehadiran_user_id_fkey
    FOREIGN KEY ("User_ID") REFERENCES public."Users" ("User_ID")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public."Seragam"
  ADD CONSTRAINT seragam_user_id_fkey
    FOREIGN KEY ("User_ID") REFERENCES public."Users" ("User_ID")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public."Sessions"
  ADD CONSTRAINT sessions_user_id_fkey
    FOREIGN KEY ("User_ID") REFERENCES public."Users" ("User_ID")
    ON DELETE CASCADE ON UPDATE CASCADE;