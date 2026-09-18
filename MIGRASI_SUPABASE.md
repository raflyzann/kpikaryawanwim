# Migrasi Google Spreadsheet → Supabase

Panduan lengkap memindahkan sistem **KPI Karyawan Wahdah Islamiyah Makassar**
dari Google Sheets ke **Supabase (PostgreSQL)**. Sistem ini menggunakan
Supabase Storage untuk foto bukti piket.

---

## 1. Ringkasan & prinsip desain

| Aspek            | Sebelum                                          | Sesudah                                                  |
| ---------------- | ------------------------------------------------ | -------------------------------------------------------- |
| Database         | Google Sheets                                    | PostgreSQL (Supabase)                                    |
| Backend logika   | `code.gs` (Apps Script)                          | Fungsi RPC di PostgreSQL (`kpi_*`)                       |
| Sesi login       | `CacheService` (`session_<token>`)               | Tabel `Sessions` (tahan restart, bisa dicabut)           |
| Rate limit login | `CacheService`                                   | Tabel `Login_Attempts`                                   |
| Foto bukti piket | Google Drive (folder publik)                     | Supabase Storage (bucket `piket-bukti`)                  |
| Frontend         | `index.html` + shim `fetch` ke Apps Script       | `index.html` + shim `fetch` ke Supabase (**tetap sama**) |
| Keamanan data    | Semua data dikirim ke client lalu disaring di JS | RLS menutup tabel + otorisasi di dalam RPC               |

**Prinsip utama migrasi ini: frontend TIDAK diubah.** Caranya:

1. **Nama tabel & kolom dipertahankan** persis seperti nama sheet (`"Jobdesk"`,
   `"Task_ID"`, `"User_ID"`, ...). Jadi bentuk data yang diterima `index.html`
   identik dengan sebelumnya.
2. **Kontrak API dipertahankan.** Setiap fungsi di `API_WHITELIST` (code.gs)
   punya padanan RPC (`kpi_*`) dengan bentuk balasan yang sama
   (`{users, jobdesk, piket, kehadiran, seragam}`), sehingga seluruh
   `google.script.run.xxx(...)` di `index.html` tetap jalan.
3. **Yang diganti hanya "kabel"-nya**: shim `fetch` di `index.html`
   diarahkan ke Supabase (lihat `supabase/shim-supabase.js`).

---

## 2. Prasyarat

| Kebutuhan                      | Keterangan                                                           |
| ------------------------------ | -------------------------------------------------------------------- |
| Akun Supabase                  | Gratis (Free plan cukup untuk skala internal) — https://supabase.com |
| (Opsional) Project Apps Script | Hanya jika suatu saat perlu impor data dari Sheets                   |
| (Opsional) Google Sheets asli  | Disimpan sebagai cadangan, tidak dipakai untuk migrasi               |
| (Opsional) Supabase CLI        | Hanya jika ingin menjalankan SQL/deploy lewat terminal               |
| Node.js ≥ 18                   | Hanya jika memakai Supabase CLI lewat `npx`                          |

> Tanpa Supabase CLI pun **semua langkah bisa diselesaikan** lewat
> **SQL Editor** di dashboard Supabase. Apps Script tidak diperlukan
> untuk migrasi ini karena tidak ada import data dari Sheets.

---

## 3. Peta migrasi

### 3.1 Sheet → Tabel

| Sheet lama  | Tabel Supabase     | Primary key                 | Catatan                                      |
| ----------- | ------------------ | --------------------------- | -------------------------------------------- |
| `Users`     | `"Users"`          | `User_ID` (email lowercase) | `PIN` tetap hash `sha256v2$...` (kompatibel) |
| `Jobdesk`   | `"Jobdesk"`        | `Task_ID`                   | prefix `TSK-` dipertahankan                  |
| `Piket`     | `"Piket"`          | `Schedule_ID`               | prefix `PKT-` + kolom baru `Bukti_Foto_Path` |
| `Kehadiran` | `"Kehadiran"`      | `Kehadiran_ID`              | `UNIQUE(User_ID, Bulan)`                     |
| `Seragam`   | `"Seragam"`        | `Seragam_ID`                | `UNIQUE(User_ID, Tanggal)`                   |
| `Config`    | `"Config"`         | `Key`                       | nilai dipindah dari hardcode `APP_CONFIG`    |
| _(baru)_    | `"Sessions"`       | `token`                     | pengganti `CacheService`                     |
| _(baru)_    | `"Login_Attempts"` | `email`                     | pengganti rate limit di cache                |
| _(baru)_    | `"Activity_Log"`   | `id`                        | audit log (opsional)                         |

### 3.2 Struktur file yang sudah dibuat

```
supabase/
  01_schema.sql                      # tabel, constraint, index, trigger, view
  02_rls.sql                         # RLS deny-by-default + bucket Storage
  03_seed_config.sql                 # seed Config + cara membuat Admin pertama
  04_functions_auth.sql              # login/logout/register/PIN/sesi/config (RPC)
  05_functions_data.sql              # seluruh RPC data (jobdesk, piket, kehadiran, seragam)
  06_audit_log.sql                   # (opsional) audit log perubahan data
  shim-supabase.js                   # pengganti shim google.script.run di index.html
  functions/upload-piket/index.ts     # Edge Function unggah foto ke Storage
scripts/
  SupabaseImporter.gs                # (opsional) importer Sheets -> Supabase jika suatu saat diperlukan
MIGRASI_SUPABASE.md                  # dokumen ini
```

### 3.3 Nama fungsi lama → RPC Supabase

| code.gs (`API_WHITELIST`)            | RPC Supabase                                    | Catatan                                |
| ------------------------------------ | ----------------------------------------------- | -------------------------------------- |
| `login(email, pin)`                  | `kpi_login(p_email, p_pin, p_user_agent, p_ip)` | balasan `{token, user}` atau `{error}` |
| `logoutSession(token)`               | `kpi_logout(p_token)`                           |                                        |
| `getAllData(token)`                  | `kpi_get_all_data(p_token)`                     | tetap disaring per-role                |
| `registerUser(nama, email, pin)`     | `kpi_register(p_nama, p_email, p_pin)`          | role selalu `User`                     |
| `resetPin(token, email, pin)`        | `kpi_reset_pin(...)`                            | hanya Admin                            |
| `changePin(token, lama, baru)`       | `kpi_change_pin(...)`                           | wajib PIN lama                         |
| `saveMultipleJobdesk(token, tasks)`  | `kpi_save_jobdesk(p_token, p_tasks)`            |                                        |
| `saveAdminJobdesk(token, data)`      | `kpi_save_admin_jobdesk(p_token, p_data)`       | marker `[[ASSIGNED_BY:...]]`           |
| `uploadPiket(token, data)`           | Edge Function `upload-piket` → `kpi_save_piket` | file ke Storage                        |
| `approveTask(token, data)`           | `kpi_approve_task(p_token, p_data)`             | Operator hanya Piket                   |
| `approveAllTasks(token, tasks)`      | `kpi_approve_all_tasks(p_token, p_tasks)`       |                                        |
| `deleteTask` / `deleteMultipleTasks` | `kpi_delete_task` / `kpi_delete_multiple_tasks` |                                        |
| `updateTask`                         | `kpi_update_task`                               |                                        |
| `updateTaskPoin`                     | `kpi_update_task_poin`                          | hanya Admin                            |
| `updateTaskStatusKerja`              | `kpi_update_status_kerja`                       |                                        |
| `updateTaskCatatan`                  | `kpi_update_task_catatan`                       | hanya Piket                            |
| `updateTaskPoinCatatan`              | `kpi_update_task_poin_catatan`                  | hanya Admin                            |
| `updateMultipleTaskStatus`           | `kpi_update_multiple_status`                    |                                        |
| `saveKehadiran(token, data)`         | `kpi_save_kehadiran(p_token, p_data)`           | UPSERT                                 |
| `saveSeragam(token, data)`           | `kpi_save_seragam(p_token, p_data)`             | UPSERT multi karyawan                  |
| _(baru)_                             | `kpi_get_config` / `kpi_set_config`             | konfigurasi di database                |
| _(baru)_                             | `kpi_set_user_role` / `kpi_set_user_active`     | ganti edit manual sheet `Users`        |
| _(baru)_                             | `kpi_get_activity_log`                          | hanya Admin                            |

---

## 4. Langkah demi langkah

### Langkah 0 — Backup data lama (5 menit)

1. Buka Spreadsheet, `File > Make a copy` → beri nama
   `BACKUP_KPI_<tanggal>`.
2. Unduh juga salinan `.xlsx` (`File > Download > Microsoft Excel`) dan
   simpan di Drive.
3. **Jangan** mengubah Spreadsheet asli sampai migrasi dinyatakan sukses.
   Importer hanya membaca, tidak pernah menghapus.

### Langkah 1 — Buat project Supabase (10 menit)

1. Masuk https://supabase.com/dashboard → **New project**.
2. Isi:
   - **Name**: `kpi-karyawan-wim`
   - **Database Password**: simpan di tempat aman (Password Manager).
   - **Region**: pilih `Southeast Asia (Singapore)` agar latensi ke Makassar
     kecil.
3. Tunggu ±2 menit sampai project siap.
4. Catat tiga nilai dari **Project Settings > API**:
   - `Project URL` → contoh `https://abcdefgh.supabase.co`
   - `anon public` key → dipakai di browser (`shim-supabase.js`)
   - `service_role` key → **rahasia**, hanya untuk Edge Function (jika perlu akses admin dari backend)

> `supabase_url` (Project URL) nanti juga ditulis ke tabel `Config` pada
> Langkah 4 supaya URL foto piket bisa disusun otomatis.

### Langkah 2 — Jalankan skema & RLS (15 menit)

Buka **SQL Editor** di dashboard Supabase, lalu jalankan file berikut
**secara berurutan** (salin isi file → paste → Run):

| Urutan | File                             | Yang dibuat                                                               |
| ------ | -------------------------------- | ------------------------------------------------------------------------- |
| 2.1    | `supabase/01_schema.sql`         | 9 tabel + constraint + index + trigger `updated_at` + 2 view              |
| 2.2    | `supabase/02_rls.sql`            | RLS aktif + seluruh tabel ditutup dari anon + bucket Storage              |
| 2.3    | `supabase/04_functions_auth.sql` | fungsi `_kpi_*` dan RPC autentikasi                                       |
| 2.4    | `supabase/05_functions_data.sql` | seluruh RPC data                                                          |
| 2.5    | `supabase/06_audit_log.sql`      | _(opsional)_ audit log                                                    |
| 2.6    | `supabase/03_seed_config.sql`    | seed tabel `Config` (**Pilihan A di file ini butuh 04 sudah dijalankan**) |

**Cek hasil 2.2** — jalankan query berikut, semuanya harus bernilai `true`:

```sql
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;
```

_(Opsional, jalur CLI)_

```bash
supabase link --project-ref <PROJECT_REF>
supabase db push            # menjalankan semua file di supabase/migrations
```

### Langkah 3 — Buat Admin pertama (5 menit)

Jalankan `supabase/03_seed_config.sql` di SQL Editor. Sebelum menjalankan,
ganti `v_email`, `v_nama`, dan `v_pin` (6 digit) pada blok **Pilihan A** di
file tersebut. PIN akan otomatis di-hash sebagai `sha256v2$...`.

Kredensial ini adalah akun Admin pertama Anda — setelah migrasi selesai,
karyawan lain bisa didaftarkan lewat fitur **Register** di aplikasi atau
langsung INSERT manual ke tabel `Users`.

### Langkah 4 — Isi konfigurasi aplikasi (5 menit)

Jalankan di SQL Editor (ganti URL project Anda):

```sql
insert into public."Config" ("Key", "Value") values
  ('supabase_url',         'https://GANTI-PROJECT-REF.supabase.co'),
  ('storage_bucket_piket', 'piket-bukti')
on conflict ("Key") do update set "Value" = excluded."Value", updated_at = now();
```

Nilai lain (`bobot_kinerja`, `area_piket`, `max_login_attempts`, ...) sudah
diisi oleh `03_seed_config.sql` dan bisa diubah kapan saja lewat
`Config`/RPC `kpi_set_config` tanpa mengubah kode frontend.

### Langkah 5 — Daftarkan pengguna awal (opsional, 5 menit)

Jika ingin menambahkan akun karyawan sebelum aplikasi di-share, jalankan
perintah berikut di SQL Editor (ganti dengan data yang sesuai):

```sql
insert into public."Users" ("User_ID", "Nama", "Role", "PIN")
values
  ('karyawan1@mail.com', 'Nama Karyawan 1', 'User', public._kpi_hash_pin('123456', 'karyawan1@mail.com')),
  ('karyawan2@mail.com', 'Nama Karyawan 2', 'User', public._kpi_hash_pin('123456', 'karyawan2@mail.com'))
on conflict ("User_ID") do nothing;
```

Atau lebih mudah: **bagikan aplikasi ke karyawan dan minta mereka
registrasi sendiri** melalui menu Register di halaman login. Setelah login,
data Jobdesk, Piket, Kehadiran, dan Seragam akan dimulai dari nol.

### Langkah 6 — Deploy Edge Function `upload-piket` (10 menit)

Diperlukan karena browser tidak boleh memegang `service_role` key.

**Jalur CLI (disarankan):**

```bash
supabase login
supabase link --project-ref <PROJECT_REF>
supabase functions deploy upload-piket --no-verify-jwt
```

`--no-verify-jwt` dipakai karena autentikasi aplikasi memakai token sesi
sendiri (PIN), bukan JWT Supabase Auth.

**Jalur dashboard (tanpa CLI):** _Edge Functions > Deploy a new function >
Via Editor_, beri nama `upload-piket`, tempel isi
`supabase/functions/upload-piket/index.ts`, lalu deploy dan pastikan opsi
**Enforce JWT Verification = OFF**.

> **Penting:** Versi terbaru `upload-piket/index.ts` tidak mengimpor library
> Supabase dari CDN. Ia memakai `fetch` langsung ke REST API Supabase agar
> tidak terjadi error parsing/bundling di Edge Runtime. Pastikan kode yang
> di-deploy adalah versi terbaru di repo ini.

Uji cepat:

```bash
curl -i -X POST "https://<PROJECT_REF>.supabase.co/functions/v1/upload-piket" \
  -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"token":"token-palsu"}'
# Harapan: {"ok":false,"error":"Sesi habis atau tidak valid. Silakan login ulang."}
```

> **Catatan CORS:** Shim `supabase/shim-supabase.js` sudah diperbarui untuk
> menghindari credentialed request ke Edge Function. Bila browser masih
> melaporkan CORS error pada preflight OPTIONS, cek **Logs** Edge Function:
> status 500 di OPTIONS biasanya berarti module error saat dimuat.

### Langkah 7 — Arahkan frontend ke Supabase (10 menit)

1. Buka `index.html`, cari blok
   `// 0. KONEKSI KE BACKEND GOOGLE APPS SCRIPT` (sekitar baris 1040–1120).
2. Hapus `const APPS_SCRIPT_URL = '...'` **dan** seluruh IIFE shim
   `(function () { ... window.google = { script: { run: createRunner() } }; })();`
3. Tambahkan **sebelum** blok `<script>` utama:
   ```html
   <script src="supabase/shim-supabase.js"></script>
   ```
4. Buka `supabase/shim-supabase.js`, isi `SUPABASE_URL` dan `SUPABASE_ANON_KEY`
   dengan nilai milik project Supabase Anda.
5. Simpan, unggah ke GitHub Pages, lalu buka aplikasi.

> **Penting:** Jika ada sisa kode Apps Script seperti `APPS_SCRIPT_URL` atau
> pembuatan `window.google.script.run` yang masih ada di `index.html`, shim
> tidak akan jalan dan aplikasi akan tetap mencoba memanggil Apps Script lama.
> Pastikan kedua blok tersebut sudah **dihapus sepenuhnya**.

> **Catatan troubleshooting cepat:**
> - Bila login gagal dan masuk mode dummy, buka **Console** (F12). Jika ada
>   `ReferenceError: google is not defined`, berarti shim belum dimuat.
> - Bila login error dengan pesan `Email atau PIN salah`, cek tabel `Users`
>   di Supabase apakah Admin sudah dibuat.
> - Bila upload piket error CORS, pastikan Edge Function `upload-piket` sudah
>   di-deploy ulang dengan kode terbaru dan **Enforce JWT Verification = OFF**.

### Langkah 8 — Uji end-to-end (30 menit)

| #   | Skenario                                   | Yang harus terjadi                                        |
| --- | ------------------------------------------ | --------------------------------------------------------- |
| 1   | Login Admin dengan PIN lama                | masuk dashboard, token tersimpan                          |
| 2   | Login karyawan dengan PIN lama             | data yang tampil **hanya** miliknya                       |
| 3   | Salah PIN 5x                               | pesan "Terlalu banyak percobaan login gagal..."           |
| 4   | Tambah 2 tugas di Ruang Kerja              | muncul di daftar, status `Pending`                        |
| 5   | Unggah laporan piket + foto                | foto terbuka dari domain `supabase.co`                    |
| 6   | Admin menyetujui piket + isi catatan       | poin & catatan tersimpan                                  |
| 7   | Operator coba setujui laporan tugas        | ditolak: "Operator hanya dapat menyetujui laporan piket." |
| 8   | Admin catat penugasan ke karyawan          | deskripsi berawalan `[[ASSIGNED_BY:Nama Admin]]`          |
| 9   | Input nilai kehadiran 2x bulan yang sama   | tidak ada baris duplikat (UPSERT)                         |
| 10  | Penilaian seragam 3 karyawan sekaligus     | 3 baris, ter-update bila tanggal sama                     |
| 11  | Ganti PIN lalu login ulang                 | berhasil dengan PIN baru                                  |
| 12  | Logout lalu refresh                        | kembali ke halaman login                                  |
| 13  | DevTools cek `GET /rest/v1/Users?select=*` | **ditolak** (RLS) — PIN tidak bisa dibaca                 |
| 14  | Admin ubah poin di Riwayat Kinerja         | berubah & tercatat di `Activity_Log`                      |

Cek audit log lewat SQL Editor:

```sql
select created_at, actor, action, entity, entity_id
from public."Activity_Log"
order by created_at desc
limit 20;
```

### Langkah 9 — Cutover (5 menit)

1. Beri tahu karyawan: aplikasi tetap sama, tidak ada perubahan cara pakai.
2. Ubah Spreadsheet lama menjadi **view-only** (Share > _Viewer_) atau
   pindahkan ke folder arsip, supaya tidak ada input ganda.
3. Opsional: matikan Web App Apps Script (_Deploy > Manage deployments >
   Archive_) — lakukan **setelah** Langkah 8 lolos dan aplikasi berjalan
   normal minimal 1 minggu.
4. Simpan `code.gs` sebagai arsip (mis. `code.gs.legacy`) di repositori.

### Langkah 10 — Rencana rollback

Migrasi ini **tidak menghapus apa pun** di Sheets/Drive, jadi rollback mudah:

1. Kembalikan blok shim di `index.html` ke versi Apps Script (simpan versi
   lama sebelum Langkah 7, mis. lewat Git).
2. Aktifkan kembali Web App Apps Script bila sudah di-archive.
3. Spreadsheet lama masih berisi data terakhir sebelum cutover. Data yang
   masuk setelah cutover ada di Supabase dan bisa diekspor bila perlu.

### Langkah 11 — Setelah migrasi (opsional)

1. **Backup otomatis**: Supabase Free sudah punya backup harian; tambahkan
   ekspor manual bulanan (_Database > Backups_).
2. **Pembersihan sesi berkala**:
   `delete from public."Sessions" where expires_at <= now();`
   (sudah otomatis dipanggil saat login, bisa dijadwalkan via `pg_cron`).
3. **Ke Supabase Auth** (bila nanti mau login email+password): kolom
   `auth_user_id` di tabel `Users` sudah disiapkan sehingga identitas bisa
   dipetakan ke `auth.users` tanpa mengubah struktur; RPC tetap dipakai
   untuk otorisasi role.
4. **Hapus shim**: ganti `google.script.run.foo(...)` menjadi
   `supabase.rpc('kpi_foo', {...})` memakai peta di `RPC_MAP`, lalu
   `shim-supabase.js` bisa dihapus.

---

## 5. Checklist keamanan

- [x] **PIN tidak pernah dikirim ke client.** `kpi_get_all_data()` hanya
      mengembalikan `User_ID`, `Nama`, `Role`.
- [x] **RLS deny-by-default** untuk semua tabel: anon key tidak bisa
      membaca/menulis tabel secara langsung (diuji di Langkah 8 #13).
- [x] **Hash PIN per-user** (salt = email) dihitung di database lewat
      `extensions.digest`, bukan di client.
- [x] **Rate limit login** 5x gagal → terkunci 5 menit, tersimpan di tabel
      (tidak hilang saat server restart).
- [x] **Otorisasi per-role di server** (`_kpi_require_session(token, role)`),
      termasuk batasan Operator hanya untuk laporan piket.
- [x] **ID user selalu diambil dari sesi server**, bukan dari payload client.
- [x] **Kunci rahasia tidak ada di browser**: `service_role` hanya dipakai
      oleh Edge Function (tidak pernah di-expose ke frontend).
- [x] **Validasi panjang & format** (deskripsi ≥ 10 karakter, email, PIN 6
      digit, bulan `YYYY-MM`, tanggal `YYYY-MM-DD`) diulang di database.
- [x] **Operasi tulis atomik** — satu panggilan RPC = satu transaksi
      (menggantikan `LockService` di code.gs).
- [x] **Audit log** mencatat pelaku perubahan (kolom `PIN` tidak pernah dicatat).

---

## 6. Jalur alternatif: tetap pakai Apps Script sebagai backend

Bila ingin migrasi bertahap (database dulu, backend tetap `code.gs`), tidak
perlu membuat RPC/Edge Function. Cukup ganti 4 helper di `code.gs` agar
membaca/menulis Supabase REST alih-alih Sheets:

| Fungsi lama di `code.gs`          | Diganti dengan                |
| --------------------------------- | ----------------------------- |
| `getSheetDataAsObjects(name)`     | `sbSelect(name, '?select=*')` |
| `sheet.appendRow([...])`          | `sbInsert(name, obj)`         |
| `sheet.getRange(...).setValue(x)` | `sbUpdate(name, filter, obj)` |
| `sheet.deleteRow(i+1)`            | `sbDelete(name, filter)`      |

Contoh implementasi (tempel di `code.gs`):

```js
const SB_URL = "https://<PROJECT_REF>.supabase.co";
const SB_KEY =
  PropertiesService.getScriptProperties().getProperty("SB_SERVICE_KEY");

function sbFetch(path, method, body) {
  const res = UrlFetchApp.fetch(SB_URL + "/rest/v1/" + path, {
    method: method || "get",
    headers: {
      apikey: SB_KEY,
      Authorization: "Bearer " + SB_KEY,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    payload: body ? JSON.stringify(body) : null,
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
  return JSON.parse(res.getContentText() || "[]");
}

function sbSelect(table, query) {
  return sbFetch(table + (query || ""), "get");
}
function sbInsert(table, row) {
  return sbFetch(table, "post", Array.isArray(row) ? row : [row]);
}
function sbUpdate(table, filter, patch) {
  return sbFetch(table + "?" + filter, "patch", patch);
}
function sbDelete(table, filter) {
  return sbFetch(table + "?" + filter, "delete");
}
```

Catatan penting: karena jalur ini memakai `service_role` di Apps Script,
kunci itu harus disimpan di **Script Properties** (seperti contoh di atas),
bukan ditulis langsung di `code.gs`. Jalur ini juga kehilangan sebagian
keuntungan RPC (transaksi atomik & audit log otomatis).

---

## 7. Troubleshooting

| Gejala                                                              | Penyebab & solusi                                                                                                                                                                          |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `permission denied for table Users`                                 | Kunci yang dipakai bukan `service_role`, atau `SUPABASE_SERVICE_ROLE_KEY` salah.                                                                                                           |
| `column "user_id" does not exist`                                   | Nama kolom bertipe mixed-case. Selalu tulis `"User_ID"` (dengan tanda kutip ganda).                                                                                                        |
| `new row violates check constraint "Jobdesk_Deskripsi_Tugas_check"` | Deskripsi < 10 karakter. Perbaiki di aplikasi sebelum menyimpan.                                                                                                                           |
| Login gagal, frontend masuk mode pratinjau dummy                    | Shim `supabase/shim-supabase.js` belum dimuat di `index.html`. Pastikan tag `<script src="supabase/shim-supabase.js"></script>` ada sebelum blok `<script>` utama.                         |
| Login gagal, error dari RPC `kpi_login`                             | Cek Console browser (F12). Bila pesan `Email atau PIN salah`, pastikan Admin sudah dibuat di Langkah 3 dan `Users` terisi. Bila `relation "Users" does not exist`, SQL `01_schema.sql` belum dijalankan. |
| `Sesi Berakhir` langsung setelah login                               | `kpi_get_all_data` mengembalikan error. Cek apakah tabel `Sessions` bisa diakses dan RPC `_kpi_require_session` ada.                                                                        |
| Frontend tetap mengakses Apps Script lama                            | Masih ada blok `APPS_SCRIPT_URL` atau IIFE `window.google = ...` di `index.html`. Hapus keduanya sebelum menambah shim Supabase.                                                           |
| Foto piket gagal diunggah, OPTIONS preflight 500                    | Edge Function `upload-piket` error saat module dimuat. Pastikan sudah di-deploy ulang dengan kode terbaru tanpa import library. Cek **Logs** di Edge Function untuk error parse/bundle.    |
| Foto piket gagal diunggah, CORS error                               | Request ke `/functions/v1/upload-piket` masih membawa header `Authorization`. Pastikan `shim-supabase.js` memanggil Edge Function hanya dengan `apikey` + body JSON.                      |
| Foto piket gagal diunggah, `Enforce JWT Verification` ON            | Di Supabase Dashboard, buka Edge Function > **Settings** > matikan **Enforce JWT Verification**.                                                                                          |
| Foto tidak muncul walau baris tersimpan                             | Bucket `piket-bukti` belum publik. Jalankan ulang bagian bucket pada `02_rls.sql`.                                                                                                         |
| `supabase_url` di `Config` masih placeholder                        | Isi manual via SQL: `insert into public."Config" ("Key","Value") values ('supabase_url', 'https://PROJECT_REF.supabase.co') on conflict ("Key") do update set "Value" = excluded."Value";` |
| `function public.kpi_xxx(text, jsonb) does not exist` saat grant    | Urutan eksekusi SQL keliru. Jalankan `04` lalu `05`, baru `03`.                                                                                                                            |
| Token localStorage bertahan tapi login selalu gagal                 | Hapus `kpi_wim_session_v1` di DevTools > Application > Local Storage, lalu login ulang. Token lama dari Apps Script tidak valid di Supabase.                                              |
| `404` pada `/rest/v1/rpc/kpi_login`                                 | Skema belum dijalankan, atau nama fungsi salah. Cek **Database > Functions** di dashboard.                                                                                                 |

---

## 8. Referensi ringkas skema

```sql
-- Users
"User_ID" text PK, "Nama" text, "Role" ('Admin'|'Operator'|'User'),
"PIN" text, auth_user_id uuid, is_active bool, created_at, updated_at

-- Jobdesk
"Task_ID" text PK, "User_ID" FK, "Tanggal" date, "Deskripsi_Tugas" text,
"Status" ('Pending'|'Approved'), "Poin" numeric,
"Status_Kerja" ('Selesai'|'Belum Selesai')

-- Piket
"Schedule_ID" text PK, "User_ID" FK, "Tanggal" date, "Jenis_Piket" text,
"Status", "Bukti_Foto_URL" text, "Bukti_Foto_Path" text, "Poin" numeric,
"Status_Kerja", "Catatan_Admin" text

-- Kehadiran              UNIQUE ("User_ID", "Bulan")
"Kehadiran_ID" text PK, "User_ID" FK, "Bulan" text 'YYYY-MM', "Nilai" numeric

-- Seragam                UNIQUE ("User_ID", "Tanggal")
"Seragam_ID" text PK, "User_ID" FK, "Tanggal" date, "Nilai" numeric

-- Config
"Key" text PK, "Value" text

-- Sessions
token uuid PK, "User_ID" FK, user_agent, ip_address, created_at, expires_at

-- Login_Attempts
email text PK, failed_count int, locked_until timestamptz, last_attempt

-- Activity_Log
id bigserial PK, actor text, action text, entity text, entity_id text,
old_data jsonb, new_data jsonb, created_at
```

View bantu: `v_poin_bulanan` (rekap poin per karyawan per bulan) dan
`v_antrean_pending` (gabungan Jobdesk + Piket yang masih `Pending`).

Konfigurasi yang sudah dipindah dari kode ke tabel `Config`:
`bobot_kinerja`, `bobot_kehadiran`, `bobot_seragam`, `poin_seragam_lengkap`,
`poin_seragam_tidak_lengkap`, `max_login_attempts`, `login_lockout_seconds`,
`session_ttl_days`, `area_piket`, `upload_max_bytes`, `upload_allowed_mime`,
`storage_bucket_piket`, `supabase_url`.

---

_Dokumen ini dibuat berdasarkan pemeriksaan langsung `code.gs` (1.355 baris)
dan `index.html` (4.267 baris) pada repositori ini, sehingga nama tabel,
kolom, fungsi, dan aturan bisnisnya sama dengan yang benar-benar dipakai
aplikasi._
