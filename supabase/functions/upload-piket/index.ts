// =====================================================================
// SUPABASE EDGE FUNCTION: upload-piket
// File: supabase/functions/upload-piket/index.ts
// ---------------------------------------------------------------------
// Versi tanpa import library. Langsung panggil Supabase REST/Storage
// lewat fetch agar tidak bergantung pada modul CDN di Edge Runtime.
// =====================================================================

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const BUCKET = 'piket-bukti';
const ALLOWED_MIME = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const MAX_BYTES = 5 * 1024 * 1024;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
}

function getEnv() {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceKey) {
    throw new Error('Konfigurasi server tidak lengkap.');
  }
  return { supabaseUrl: supabaseUrl.replace(/\/+$/, ''), anonKey, serviceKey };
}

async function sbPost(path: string, body: unknown, { service = false }: { service?: boolean } = {}): Promise<{ ok: boolean; data?: any; error?: string }> {
  const { supabaseUrl, anonKey, serviceKey } = getEnv();
  const headers: Record<string, string> = {
    'apikey': service ? serviceKey : anonKey,
    'Content-Type': 'application/json',
    'Prefer': 'return=representation'
  };
  if (service) {
    headers['Authorization'] = 'Bearer ' + serviceKey;
  }

  const res = await fetch(supabaseUrl + path, {
    method: 'POST',
    headers,
    body: JSON.stringify(body)
  });

  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }

  if (!res.ok) {
    const message = (data && (data.message || data.error)) || ('HTTP ' + res.status);
    return { ok: false, error: message };
  }
  return { ok: true, data };
}

async function sbDelete(path: string, service = false): Promise<{ ok: boolean; error?: string }> {
  const { supabaseUrl, anonKey, serviceKey } = getEnv();
  const headers: Record<string, string> = {
    'apikey': service ? serviceKey : anonKey,
    'Prefer': 'return=representation'
  };
  if (service) {
    headers['Authorization'] = 'Bearer ' + serviceKey;
  }

  const res = await fetch(supabaseUrl + path, { method: 'DELETE', headers });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }

  if (!res.ok) {
    const message = (data && (data.message || data.error)) || ('HTTP ' + res.status);
    return { ok: false, error: message };
  }
  return { ok: true };
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'Metode tidak didukung. Gunakan POST.' }, 405);
  }

  try {
    const body = await req.json().catch(() => null);
    if (!body || typeof body !== 'object') {
      return json({ ok: false, error: 'Body JSON tidak valid.' }, 400);
    }
    const payload = body as Record<string, unknown>;

    const token = String(payload.token ?? '').trim();
    if (!token) {
      return json({ ok: false, error: 'Sesi tidak ditemukan. Silakan login ulang.' }, 401);
    }

    const session = await sbPost('/rest/v1/rpc/kpi_session_info', { p_token: token });
    if (!session.ok || !session.data) {
      const msg = session.error || 'Sesi habis atau tidak valid. Silakan login ulang.';
      return json({ ok: false, error: msg }, 401);
    }
    const userId = String((session.data as any).user_id ?? '');

    const imageBase64 = String(payload.imageBase64 ?? '');
    const mimeType = String(payload.mimeType ?? 'image/jpeg');
    const extRaw = String(payload.ext ?? 'jpg');
    let fotoPath: string | null = null;
    let fotoUrl: string | null = null;

    if (imageBase64) {
      if (!ALLOWED_MIME.includes(mimeType)) {
        return json({ ok: false, error: 'Format foto tidak didukung. Gunakan JPG, PNG, WEBP, atau GIF.' }, 400);
      }

      const bytes = base64ToBytes(imageBase64.replace(/^data:[^,]+,/, ''));
      if (bytes.byteLength === 0) {
        return json({ ok: false, error: 'File foto kosong atau gagal dibaca.' }, 400);
      }
      if (bytes.byteLength > MAX_BYTES) {
        return json({ ok: false, error: 'Ukuran foto terlalu besar (maksimal 5 MB).' }, 400);
      }

      const ext = (extRaw.replace(/[^a-zA-Z0-9]/g, '') || 'jpg').toLowerCase();
      const safeUser = userId.split('@')[0].replace(/[^a-zA-Z0-9]/g, '') || 'user';
      const fileName = `${Date.now()}_${crypto.randomUUID()}.${ext}`;
      fotoPath = `piket/${safeUser}/${fileName}`;

      const { supabaseUrl } = getEnv();
      const uploadRes = await fetch(supabaseUrl + '/storage/v1/object/' + BUCKET + '/' + fotoPath, {
        method: 'POST',
        headers: {
          'apikey': (await getEnv()).serviceKey,
          'Authorization': 'Bearer ' + (await getEnv()).serviceKey,
          'Content-Type': mimeType,
          'x-upsert': 'false'
        },
        body: bytes
      });

      if (!uploadRes.ok) {
        const errText = await uploadRes.text();
        return json({ ok: false, error: 'Gagal mengunggah foto bukti. Silakan coba lagi.' }, 500);
      }

      fotoUrl = supabaseUrl + '/storage/v1/object/public/' + BUCKET + '/' + fotoPath;
    }

    const save = await sbPost('/rest/v1/rpc/kpi_save_piket', {
      p_token: token,
      p_data: {
        tanggal: payload.tanggal ?? null,
        jenis: payload.jenis ?? null,
        isSelesai: payload.isSelesai ?? false,
        fotoPath,
        fotoUrl
      }
    });

    if (!save.ok) {
      if (fotoPath) {
        const { supabaseUrl, serviceKey } = getEnv();
        await fetch(supabaseUrl + '/storage/v1/object/' + BUCKET + '/' + fotoPath, {
          method: 'DELETE',
          headers: {
            'apikey': serviceKey,
            'Authorization': 'Bearer ' + serviceKey
          }
        });
      }
      return json({ ok: false, error: save.error || 'Gagal menyimpan laporan piket.' }, 400);
    }

    return json({ ok: true, result: save.data });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ ok: false, error: 'Terjadi kesalahan pada server: ' + message }, 500);
  }
});
