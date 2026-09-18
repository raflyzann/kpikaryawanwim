// =====================================================================
// SUPABASE EDGE FUNCTION: upload-piket
// File: supabase/functions/upload-piket/index.ts
// ---------------------------------------------------------------------
// Versi tanpa upload foto. Langsung panggil RPC kpi_save_piket.
// =====================================================================

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
}

async function sbPost(path: string, body: unknown, { service = false }: { service?: boolean } = {}): Promise<{ ok: boolean; data?: any; error?: string }> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return { ok: false, error: 'Konfigurasi server tidak lengkap.' };
  }

  const headers: Record<string, string> = {
    'apikey': service ? serviceKey : '',
    'Content-Type': 'application/json',
    'Prefer': 'return=representation'
  };
  if (service) {
    headers['Authorization'] = 'Bearer ' + serviceKey;
  }

  const res = await fetch(supabaseUrl.replace(/\/+$/, '') + path, {
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

    const save = await sbPost('/rest/v1/rpc/kpi_save_piket', {
      p_token: token,
      p_data: {
        tanggal: payload.tanggal ?? null,
        jenis: payload.jenis ?? null,
        isSelesai: payload.isSelesai ?? false
      }
    });

    if (!save.ok) {
      return json({ ok: false, error: save.error || 'Gagal menyimpan laporan piket.' }, 400);
    }

    return json({ ok: true, result: save.data });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ ok: false, error: 'Terjadi kesalahan pada server: ' + message }, 500);
  }
});
