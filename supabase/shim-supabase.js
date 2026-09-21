/* =====================================================================
 * SHIM SUPABASE - pengganti shim google.script.run
 * File: supabase/shim-supabase.js
 * ---------------------------------------------------------------------
 * CARA PAKAI:
 *   1. Buka index.html, cari blok "0. KONEKSI KE BACKEND GOOGLE APPS SCRIPT"
 *      (sekitar baris 1040-1120).
 *   2. HAPUS: const APPS_SCRIPT_URL = '...' dan seluruh IIFE shim
 *      (function () { ... window.google = { script: { run: createRunner() } }; })();
 *   3. GANTI dengan: <script src="shim-supabase.js"></script>
 *      (atau tempel isi file ini di dalam blok <script> yang sudah ada).
 *   4. Isi SUPABASE_URL & SUPABASE_ANON_KEY di bawah.
 *
 * Setelah itu SELURUH pemanggilan google.script.run.namaFungsi(...) di
 * index.html tetap bekerja tanpa diubah satu baris pun - nama fungsi lama
 * dipetakan ke RPC Supabase (kpi_*) lewat tabel RPC_MAP.
 *
 * Catatan keamanan: anon key memang aman dipublikasikan di browser, sebab
 * RLS menutup semua akses tabel langsung. Seluruh otorisasi terjadi di
 * dalam fungsi RPC (SECURITY DEFINER) yang memvalidasi token sesi.
 * ===================================================================== */
(function () {
    'use strict';

    // >>> WAJIB DIISI <<<
    const SUPABASE_URL = 'https://jzjbemaseqehdtkdhrrb.supabase.co';
    const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp6amJlbWFzZXFlaGR0a2RocnJiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2OTYzNzgsImV4cCI6MjEwNTI3MjM3OH0._HEdZJiFlo7c3XTEAhJ_wFhWwFgq3IK6uUSst6n5_Hw';

    const HEADERS = {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json'
    };

    /**
     * Peta nama fungsi lama (code.gs / API_WHITELIST) -> nama RPC Supabase.
     * `params` adalah nama parameter RPC sesuai posisi argumen yang dikirim
     * frontend, jadi urutannya harus sama dengan signature fungsi lama.
     */
    const RPC_MAP = {
        login:                 { rpc: 'kpi_login',               params: ['p_email', 'p_pin', 'p_user_agent'] },
        logoutSession:         { rpc: 'kpi_logout',              params: ['p_token'] },
        getAllData:            { rpc: 'kpi_get_all_data',        params: ['p_token'] },
        registerUser:          { rpc: 'kpi_register',            params: ['p_nama', 'p_email', 'p_pin'] },
        resetPin:              { rpc: 'kpi_reset_pin',           params: ['p_token', 'p_email', 'p_pin_baru'] },
        changePin:             { rpc: 'kpi_change_pin',          params: ['p_token', 'p_pin_lama', 'p_pin_baru'] },
        saveMultipleJobdesk:   { rpc: 'kpi_save_jobdesk',        params: ['p_token', 'p_tasks'] },
        saveAdminJobdesk:      { rpc: 'kpi_save_admin_jobdesk',  params: ['p_token', 'p_data'] },
        approveTask:           { rpc: 'kpi_approve_task',        params: ['p_token', 'p_data'] },
        approveAllTasks:       { rpc: 'kpi_approve_all_tasks',   params: ['p_token', 'p_tasks'] },
        deleteTask:            { rpc: 'kpi_delete_task',         params: ['p_token', 'p_id'] },
        updateTask:            { rpc: 'kpi_update_task',         params: ['p_token', 'p_data'] },
        updateTaskPoin:        { rpc: 'kpi_update_task_poin',    params: ['p_token', 'p_data'] },
        updateTaskStatusKerja: { rpc: 'kpi_update_status_kerja', params: ['p_token', 'p_data'] },
        updateTaskCatatan:     { rpc: 'kpi_update_task_catatan', params: ['p_token', 'p_data'] },
        updateTaskPoinCatatan: { rpc: 'kpi_update_task_poin_catatan', params: ['p_token', 'p_data'] },
        deleteMultipleTasks:   { rpc: 'kpi_delete_multiple_tasks', params: ['p_token', 'p_ids'] },
        updateMultipleTaskStatus: { rpc: 'kpi_update_multiple_status', params: ['p_token', 'p_ids'] },
        saveKehadiran:         { rpc: 'kpi_save_kehadiran',      params: ['p_token', 'p_data'] },
        saveSeragam:           { rpc: 'kpi_save_seragam',        params: ['p_token', 'p_data'] },
        updateSeragamPoin:     { rpc: 'kpi_update_seragam_poin', params: ['p_token', 'p_data'] },
        deleteSeragam:         { rpc: 'kpi_delete_seragam',      params: ['p_token', 'p_id'] },
        // Fungsi tambahan (fitur baru, tidak ada di code.gs):
        getConfig:             { rpc: 'kpi_get_config',          params: ['p_token'] },
        setConfig:             { rpc: 'kpi_set_config',          params: ['p_token', 'p_key', 'p_value'] },
        setUserRole:           { rpc: 'kpi_set_user_role',       params: ['p_token', 'p_email', 'p_role'] },
        setUserActive:         { rpc: 'kpi_set_user_active',     params: ['p_token', 'p_email', 'p_active'] },
        getActivityLog:        { rpc: 'kpi_get_activity_log',    params: ['p_token', 'p_limit'] }
    };

    /** Panggil RPC PostgREST dan normalisasi balasan error-nya. */
    function callRpc(fnName, params) {
        return fetch(SUPABASE_URL + '/rest/v1/rpc/' + fnName, {
            method: 'POST',
            headers: HEADERS,
            body: JSON.stringify(params || {})
        }).then(function (res) {
            return res.text().then(function (text) {
                let data = null;
                try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
                if (!res.ok) {
                    const msg = (data && (data.message || data.hint || data.details)) ||
                                ('HTTP ' + res.status);
                    throw new Error(msg);
                }
                return data;
            });
        });
    }

    /**
     * Simpan laporan piket: panggil RPC kpi_save_piket langsung tanpa
     * melalui Edge Function, karena fitur upload foto sudah dinonaktifkan.
     */
    function callUploadPiket(token, data) {
        return callRpc('kpi_save_piket', {
            p_token: token,
            p_data: {
                tanggal: (data && data.tanggal) || null,
                jenis: (data && data.jenis) || null,
                isSelesai: (data && data.isSelesai) || false
            }
        });
    }

    /**
     * Jalankan satu nama fungsi lama lewat jalur yang tepat:
     *  - uploadPiket  -> Edge Function
     *  - sisanya      -> RPC PostgREST
     * Mengembalikan Promise berisi `result` (data sukses) atau melempar
     * Error dengan pesan dari server.
     */
    function invoke(fnName, args) {
        if (fnName === 'uploadPiket') {
            return callUploadPiket(args[0], args[1]).then(function (result) {
                return { result: result };
            }).catch(function (err) {
                return { error: err.message };
            });
        }

        const mapping = RPC_MAP[fnName];
        if (!mapping) {
            return Promise.resolve({
                error: 'Fungsi "' + fnName + '" tidak dikenali atau tidak diizinkan.'
            });
        }

        const params = {};
        mapping.params.forEach(function (paramName, index) {
            let value = args[index];
            // User agent dikirim otomatis untuk fungsi login.
            if (paramName === 'p_user_agent' && (value === undefined || value === null)) {
                value = (typeof navigator !== 'undefined' && navigator.userAgent)
                    ? navigator.userAgent.substring(0, 300) : null;
            }
            if (value !== undefined) {
                params[paramName] = value;
            }
        });

        return callRpc(mapping.rpc, params)
            .then(function (result) { return { result: result }; })
            .catch(function (err) { return { error: err.message }; });
    }

    function createRunner() {
        let successHandler = null;
        let failureHandler = null;

        const runner = new Proxy(function () {}, {
            get(_target, prop) {
                if (prop === 'withSuccessHandler') {
                    return function (fn) { successHandler = fn; return runner; };
                }
                if (prop === 'withFailureHandler') {
                    return function (fn) { failureHandler = fn; return runner; };
                }
                // Properti lain dianggap sebagai nama fungsi server, persis
                // seperti google.script.run.namaFungsi(arg1, arg2, ...).
                return function (...args) {
                    const onSuccess = successHandler;
                    const onFailure = failureHandler;
                    successHandler = null;
                    failureHandler = null;

                    invoke(String(prop), args).then(function (data) {
                        if (data && data.error === undefined) {
                            if (onSuccess) onSuccess(data.result);
                            return;
                        }
                        const msg = (data && data.error) || 'Terjadi kesalahan pada server.';
                        // Sesi habis -> tangani terpusat (arahkan ke login) dan
                        // JANGAN tampilkan error generik dari handler masing-masing.
                        if (typeof handleSessionExpired === 'function' && handleSessionExpired(msg)) return;
                        if (onFailure) onFailure({ message: msg });
                        else console.error(msg);
                    });

                    return runner;
                };
            }
        });

        return runner;
    }

    // Jangan timpa google.script.run asli bila file ini (tanpa sengaja)
    // dijalankan di dalam lingkungan Apps Script.
    if (typeof google !== 'undefined' && google.script && google.script.run) return;

    window.google = { script: { run: createRunner() } };

    // Helper opsional untuk pemakaian langsung dari console/DevTools:
    window.kpiSupabase = {
        url: SUPABASE_URL,
        rpc: callRpc,
        uploadPiket: callUploadPiket,
        invoke: invoke,
        map: RPC_MAP
    };
})();