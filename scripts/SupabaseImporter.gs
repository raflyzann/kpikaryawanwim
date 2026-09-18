/**
 * =====================================================================
 * IMPORTER: GOOGLE SHEETS -> SUPABASE
 * File: scripts/SupabaseImporter.gs
 * ---------------------------------------------------------------------
 * Skrip ini dijalankan DI DALAM project Google Apps Script yang sama
 * dengan code.gs (Extensions > Apps Script), supaya data lama dari
 * Spreadsheet bisa dipindahkan ke Supabase tanpa export/import CSV
 * manual dan tanpa kehilangan data.
 *
 * LANGKAH PEMAKAIAN:
 *   1. Isi SUPABASE_URL & SUPABASE_SERVICE_ROLE_KEY di bawah.
 *      >>> service_role key JANGAN ditaruh di frontend/index.html. <<<
 *   2. Jalankan verifyConnection() dulu -> pastikan tabel terbaca.
 *   3. Jalankan migrateAll() -> semua sheet dipindahkan (urutan otomatis:
 *      Users lebih dulu supaya foreign key tidak gagal).
 *   4. Jalankan verifyMigration() -> bandingkan jumlah baris Sheets vs
 *      Supabase. Harus sama.
 *   5. (Opsional) set REUPLOAD_PHOTOS = true lalu jalankan
 *      migratePiketPhotos() untuk memindahkan foto dari Google Drive ke
 *      Supabase Storage.
 *
 * SIFAT SKRIP: idempoten (memakai UPSERT berdasarkan primary key), jadi
 * aman dijalankan berulang kali. Tidak pernah menghapus data di Supabase.
 * =====================================================================
 */

// >>> WAJIB DIISI <<<
var SUPABASE_URL = "https://nwojyzeftbotqeqqldbs.supabase.co"; // tanpa garis miring di akhir
var SUPABASE_SERVICE_ROLE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im53b2p5emVmdGJvdHFlcXFsZGJzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1OTI1NDAsImV4cCI6MjEwNTE2ODU0MH0.5TPe3O8VPLCcnr-c1-av2pIp1ipoaSEnybzUTx50H1k"; // Settings > API > service_role

// Opsi
var REUPLOAD_PHOTOS = false; // true = foto Drive dipindah ke Supabase Storage
var STORAGE_BUCKET = "piket-bukti";
var BATCH_SIZE = 200; // jumlah baris per request

// =====================================================================
// Helper umum
// =====================================================================

function _sbHeaders(extra) {
  var headers = {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: "Bearer " + SUPABASE_SERVICE_ROLE_KEY,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (extra) {
    Object.keys(extra).forEach(function (k) {
      headers[k] = extra[k];
    });
  }
  return headers;
}

function _sbUrl(pathAndQuery) {
  return SUPABASE_URL.replace(/\/+$/, "") + pathAndQuery;
}

/** Panggil REST Supabase. Melempar error berisi pesan dari server. */
function sbFetch(pathAndQuery, method, payload, extraHeaders) {
  var options = {
    method: method || "GET",
    headers: _sbHeaders(extraHeaders),
    muteHttpExceptions: true,
  };
  if (payload !== undefined && payload !== null) {
    options.payload = JSON.stringify(payload);
  }

  var res = UrlFetchApp.fetch(_sbUrl(pathAndQuery), options);
  var code = res.getResponseCode();
  var text = res.getContentText();
  var parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch (e) {
    parsed = null;
  }

  if (code < 200 || code >= 300) {
    var msg =
      (parsed && (parsed.message || parsed.hint || parsed.details)) || text;
    throw new Error("Supabase " + code + " pada " + pathAndQuery + ": " + msg);
  }
  return parsed;
}

/** UPSERT massal: POST + Prefer: resolution=merge-duplicates (on_conflict). */
function sbUpsert(table, rows, onConflict) {
  if (!rows || rows.length === 0) return 0;
  var total = 0;

  for (var i = 0; i < rows.length; i += BATCH_SIZE) {
    var chunk = rows.slice(i, i + BATCH_SIZE);
    var query =
      "/rest/v1/" +
      encodeURIComponent(table) +
      (onConflict ? "?on_conflict=" + encodeURIComponent(onConflict) : "");
    sbFetch(query, "POST", chunk, {
      Prefer: "resolution=merge-duplicates,return=minimal",
    });
    total += chunk.length;
    Logger.log(
      "  " + table + ": " + total + "/" + rows.length + " baris terkirim",
    );
  }
  return total;
}

/** Hitung jumlah baris di sebuah tabel Supabase (dari header Content-Range). */
function sbCount(table) {
  var res = UrlFetchApp.fetch(
    _sbUrl("/rest/v1/" + encodeURIComponent(table) + "?select=*&limit=1"),
    {
      method: "GET",
      headers: _sbHeaders({ Prefer: "count=exact", Range: "0-0" }),
      muteHttpExceptions: true,
    },
  );
  var allHeaders = res.getHeaders();
  var range = allHeaders["Content-Range"] || allHeaders["content-range"];
  if (!range) return -1;
  var parts = String(range).split("/");
  return parts.length === 2 ? Number(parts[1]) : -1;
}

// =====================================================================
// Baca data dari Spreadsheet
// =====================================================================

function _sheetObjects(sheetName) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(sheetName);
  if (!sheet) {
    Logger.log('Sheet "' + sheetName + '" tidak ditemukan - dilewati.');
    return [];
  }
  var data = sheet.getDataRange().getValues();
  if (data.length <= 1) return [];

  var headers = data[0];
  var rows = [];
  for (var i = 1; i < data.length; i++) {
    var obj = {};
    for (var j = 0; j < headers.length; j++) {
      var value = data[i][j];
      if (value instanceof Date) {
        value = Utilities.formatDate(
          value,
          Session.getScriptTimeZone(),
          "yyyy-MM-dd",
        );
      }
      obj[String(headers[j])] = value;
    }
    rows.push(obj);
  }
  return rows;
}

/** 'YYYY-MM' dari Date / 'YYYY-MM-DD' / 'YYYY-MM'. */
function _normBulan(value) {
  if (value instanceof Date) {
    return Utilities.formatDate(value, Session.getScriptTimeZone(), "yyyy-MM");
  }
  var m = String(value == null ? "" : value)
    .trim()
    .match(/^(\d{4}-\d{2})/);
  return m ? m[1] : "";
}

/** 'YYYY-MM-DD' dari Date / string apa pun. */
function _normTanggal(value) {
  if (value instanceof Date) {
    return Utilities.formatDate(
      value,
      Session.getScriptTimeZone(),
      "yyyy-MM-dd",
    );
  }
  var s = String(value == null ? "" : value).trim();
  var m = s.match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : "";
}

function _text(value, maxLen) {
  var s = String(value == null ? "" : value).trim();
  if (maxLen && s.length > maxLen) s = s.substring(0, maxLen);
  return s;
}

function _num(value) {
  var n = Number(value);
  return isNaN(n) ? 0 : n;
}

function _nullable(value) {
  var s = _text(value);
  return s === "" ? null : s;
}

// =====================================================================
// Konversi + impor per tabel
// =====================================================================

function importUsers() {
  var rows = _sheetObjects("Users")
    .map(function (r) {
      return {
        User_ID: _text(r.User_ID, 200).toLowerCase(),
        Nama: _text(r.Nama, 100),
        Role: _text(r.Role, 20) || "User",
        // PIN sengaja dikirim APA ADANYA. Hash lama (sha256v2$ / sha256$)
        // tetap valid karena algoritmanya identik dengan _kpi_hash_pin().
        PIN: _nullable(r.PIN),
        is_active: true,
      };
    })
    .filter(function (r) {
      return r["User_ID"] !== "" && r["Nama"] !== "";
    });

  return sbUpsert("Users", rows, "User_ID");
}

function importJobdesk() {
  var rows = _sheetObjects("Jobdesk")
    .map(function (r) {
      return {
        Task_ID: _text(r.Task_ID, 100),
        User_ID: _text(r.User_ID, 200).toLowerCase(),
        Tanggal: _normTanggal(r.Tanggal) || null,
        Deskripsi_Tugas: _text(r.Deskripsi_Tugas, 500),
        Status: _text(r.Status, 20) === "Approved" ? "Approved" : "Pending",
        Poin: _num(r.Poin),
        Status_Kerja:
          _text(r.Status_Kerja, 20) === "Selesai" ? "Selesai" : "Belum Selesai",
      };
    })
    .filter(function (r) {
      return (
        r["Task_ID"] !== "" &&
        r["User_ID"] !== "" &&
        r["Deskripsi_Tugas"].length >= 10
      );
    });

  return sbUpsert("Jobdesk", rows, "Task_ID");
}

function importPiket() {
  var rows = _sheetObjects("Piket")
    .map(function (r) {
      return {
        Schedule_ID: _text(r.Schedule_ID, 100),
        User_ID: _text(r.User_ID, 200).toLowerCase(),
        Tanggal: _normTanggal(r.Tanggal) || null,
        Jenis_Piket: _text(r.Jenis_Piket, 100),
        Status: _text(r.Status, 20) === "Approved" ? "Approved" : "Pending",
        Poin: _num(r.Poin),
        Status_Kerja:
          _text(r.Status_Kerja, 20) === "Selesai" ? "Selesai" : "Belum Selesai",
        Catatan_Admin: _nullable(r.Catatan_Admin),
      };
    })
    .filter(function (r) {
      return (
        r["Schedule_ID"] !== "" &&
        r["User_ID"] !== "" &&
        r["Jenis_Piket"] !== ""
      );
    });

  return sbUpsert("Piket", rows, "Schedule_ID");
}

function importKehadiran() {
  var rows = _sheetObjects("Kehadiran")
    .map(function (r) {
      return {
        Kehadiran_ID:
          _text(r.Kehadiran_ID, 100) || "KHD-" + Utilities.getUuid(),
        User_ID: _text(r.User_ID, 200).toLowerCase(),
        Bulan: _normBulan(r.Bulan),
        Nilai: _num(r.Nilai),
      };
    })
    .filter(function (r) {
      return r["User_ID"] !== "" && /^\d{4}-\d{2}$/.test(r["Bulan"]);
    });

  return sbUpsert("Kehadiran", rows, "User_ID,Bulan");
}

function importSeragam() {
  var rows = _sheetObjects("Seragam")
    .map(function (r) {
      return {
        Seragam_ID: _text(r.Seragam_ID, 100) || "SRG-" + Utilities.getUuid(),
        User_ID: _text(r.User_ID, 200).toLowerCase(),
        Tanggal: _normTanggal(r.Tanggal) || null,
        Nilai: _num(r.Nilai),
      };
    })
    .filter(function (r) {
      return r["User_ID"] !== "" && r["Tanggal"];
    });

  return sbUpsert("Seragam", rows, "User_ID,Tanggal");
}

function importConfig() {
  var rows = _sheetObjects("Config")
    .map(function (r) {
      return { Key: _text(r.Key, 100), Value: _text(r.Value, 500) };
    })
    .filter(function (r) {
      return r["Key"] !== "";
    });

  return sbUpsert("Config", rows, "Key");
}

// =====================================================================
// Orkestrasi & verifikasi
// =====================================================================

/** Cek koneksi & keberadaan seluruh tabel. Jalankan ini lebih dulu. */
function verifyConnection() {
  var tables = ["Users", "Jobdesk", "Piket", "Kehadiran", "Seragam", "Config"];
  var lines = ["Cek koneksi ke " + SUPABASE_URL];
  tables.forEach(function (t) {
    try {
      lines.push("  OK    " + t + " -> " + sbCount(t) + " baris");
    } catch (e) {
      lines.push("  GAGAL " + t + " -> " + e.message);
    }
  });
  var report = lines.join("\n");
  Logger.log(report);
  return report;
}

/**
 * Pindahkan SEMUA data dari Spreadsheet ke Supabase.
 * Urutan penting: Users lebih dulu (foreign key), lalu Jobdesk/Piket,
 * terakhir Kehadiran/Seragam/Config.
 */
function migrateAll() {
  var results = {};
  var steps = [
    ["Users", importUsers],
    ["Jobdesk", importJobdesk],
    ["Piket", importPiket],
    ["Kehadiran", importKehadiran],
    ["Seragam", importSeragam],
    ["Config", importConfig],
  ];

  Logger.log("=== MIGRASI SHEETS -> SUPABASE DIMULAI ===");
  steps.forEach(function (step) {
    var name = step[0];
    var fn = step[1];
    try {
      var count = fn();
      results[name] = count + " baris";
      Logger.log("[OK] " + name + ": " + count + " baris");
    } catch (e) {
      results[name] = "GAGAL: " + e.message;
      Logger.log("[GAGAL] " + name + ": " + e.message);
    }
  });
  Logger.log("=== SELESAI ===");
  Logger.log(JSON.stringify(results, null, 2));
  return results;
}

/**
 * Bandingkan jumlah baris Spreadsheet vs Supabase untuk tiap tabel.
 * Jalankan setelah migrateAll(); semua angka harus sama.
 */
function verifyMigration() {
  var tables = ["Users", "Jobdesk", "Piket", "Kehadiran", "Seragam", "Config"];
  var lines = ["Perbandingan jumlah baris (Sheets vs Supabase):"];
  var allMatch = true;

  tables.forEach(function (t) {
    var local = _sheetObjects(t).length;
    var remote = -1;
    try {
      remote = sbCount(t);
    } catch (e) {
      remote = -1;
    }
    var match = local === remote;
    if (!match) allMatch = false;
    lines.push(
      "  " + (match ? "OK   " : "BEDA ") + t + ": " + local + " vs " + remote,
    );
  });

  lines.push(
    allMatch
      ? "Semua tabel COCOK. Migrasi data selesai."
      : "Ada tabel yang jumlahnya BEDA - periksa Logger di migrateAll().",
  );
  var report = lines.join("\n");
  Logger.log(report);
  return report;
}

// =====================================================================
// Opsional: pindahkan foto bukti dari Google Drive ke Supabase Storage
// =====================================================================

/** Unggah satu Blob ke Storage (memakai service_role). */
function sbUploadObject(objectPath, blob, contentType) {
  var res = UrlFetchApp.fetch(
    _sbUrl("/storage/v1/object/" + STORAGE_BUCKET + "/" + objectPath),
    {
      method: "POST",
      headers: {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: "Bearer " + SUPABASE_SERVICE_ROLE_KEY,
        "Content-Type":
          contentType || blob.getContentType() || "application/octet-stream",
        "x-upsert": "true",
      },
      payload: blob,
      muteHttpExceptions: true,
    },
  );
  var code = res.getResponseCode();
  if (code < 200 || code >= 300) {
    throw new Error(
      "Upload Storage gagal (" + code + "): " + res.getContentText(),
    );
  }
  return true;
}

/**
 * Untuk setiap baris Piket yang masih menunjuk foto Google Drive:
 *   1. baca file dari Drive,
 *   2. unggah ke Storage (path 'piket/<user>/<nama file>'),
 *   3. update Bukti_Foto_URL + Bukti_Foto_Path di Supabase.
 * Foto Drive TIDAK dihapus, jadi masih bisa dipakai sebagai cadangan.
 * Aktifkan lebih dulu: REUPLOAD_PHOTOS = true
 */
function migratePiketPhotos() {
  if (!REUPLOAD_PHOTOS) {
    return "REUPLOAD_PHOTOS masih false. Set true dulu bila ingin memindahkan foto ke Storage.";
  }

  var rows = sbFetch(
    "/rest/v1/Piket?select=Schedule_ID,User_ID,Bukti_Foto_URL&limit=10000",
    "GET",
  );
  var moved = 0,
    skipped = 0,
    failed = 0;

  rows.forEach(function (row) {
    var url = String(row["Bukti_Foto_URL"] || "");
    if (
      url.indexOf("drive.google.com") === -1 &&
      url.indexOf("docs.google.com") === -1
    ) {
      skipped++;
      return;
    }

    var match = url.match(/[-\w]{25,}/); // Google Drive file ID
    if (!match) {
      skipped++;
      return;
    }

    try {
      var blob = DriveApp.getFileById(match[0]).getBlob();
      var ext = (blob.getName().split(".").pop() || "jpg").toLowerCase();
      var safeUser =
        String(row["User_ID"])
          .split("@")[0]
          .replace(/[^a-zA-Z0-9]/g, "") || "user";
      var objectPath =
        "piket/" +
        safeUser +
        "/" +
        Date.now() +
        "_" +
        match[0].slice(0, 8) +
        "." +
        ext;

      sbUploadObject(objectPath, blob);
      var publicUrl =
        SUPABASE_URL.replace(/\/+$/, "") +
        "/storage/v1/object/public/" +
        STORAGE_BUCKET +
        "/" +
        objectPath;

      sbFetch(
        "/rest/v1/Piket?Schedule_ID=eq." +
          encodeURIComponent(row["Schedule_ID"]),
        "PATCH",
        { Bukti_Foto_URL: publicUrl, Bukti_Foto_Path: objectPath },
      );

      moved++;
      Logger.log("Foto " + row["Schedule_ID"] + " -> " + objectPath);
    } catch (e) {
      failed++;
      Logger.log("GAGAL foto " + row["Schedule_ID"] + ": " + e.message);
    }
  });

  var report =
    "Foto dipindahkan: " +
    moved +
    ", dilewati: " +
    skipped +
    ", gagal: " +
    failed +
    ".";
  Logger.log(report);
  return report;
}

// =====================================================================
// Setelah migrasi: samakan URL Supabase di tabel Config
// =====================================================================
/**
 * Menulis Config 'supabase_url' supaya kpi_save_piket() bisa menyusun
 * Bukti_Foto_URL sendiri saat hanya fotoPath yang dikirim.
 * Jalankan sekali setelah migrateAll().
 */
function setSupabaseUrlConfig() {
  var url = SUPABASE_URL.replace(/\/+$/, "");
  sbFetch(
    "/rest/v1/Config?on_conflict=Key",
    "POST",
    [
      { Key: "supabase_url", Value: url },
      { Key: "storage_bucket_piket", Value: STORAGE_BUCKET },
    ],
    { Prefer: "resolution=merge-duplicates,return=minimal" },
  );

  var report =
    "Config supabase_url = " +
    url +
    " dan storage_bucket_piket = " +
    STORAGE_BUCKET;
  Logger.log(report);
  return report;
}
