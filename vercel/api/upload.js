import { put, list, del } from '@vercel/blob';
import { ID_RE, KINDS, sessionPrefix, sessionTimes } from './_shared.js';

// 서버리스 함수 요청 본문 제한(4.5MB) 아래에서 동작. 앱은 영상 비트레이트를 캡해 이 안에 들어온다.
const MAX_BODY = Math.floor(4.4 * 1024 * 1024);

export const config = {
  api: { bodyParser: false },
};

export default async function handler(req, res) {
  if (req.method !== 'PUT') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  const requiredKey = process.env.GC_UPLOAD_KEY;
  if (requiredKey && req.headers['x-gc-key'] !== requiredKey) {
    return res.status(401).json({ ok: false, error: 'bad upload key' });
  }

  const { id, kind } = req.query;
  if (!ID_RE.test(id || '') || !KINDS[kind]) {
    return res.status(400).json({ ok: false, error: 'bad id or kind' });
  }

  const body = await readBody(req);
  if (!body) return res.status(400).json({ ok: false, error: 'empty body' });
  if (body.length > MAX_BODY) return res.status(413).json({ ok: false, error: 'too large' });

  const prefix = sessionPrefix(id);
  const existing = await list({ prefix });

  // 세션 만료 후 재사용 방지
  if (existing.blobs.length > 0) {
    const { expiresAt } = sessionTimes(existing.blobs);
    if (Date.now() > expiresAt) {
      await del(existing.blobs.map((b) => b.url));
      return res.status(410).json({ ok: false, error: 'expired' });
    }
  }

  // 같은 종류의 이전 업로드(재시도)는 교체
  const stale = existing.blobs.filter((b) => b.pathname.endsWith(KINDS[kind].file));
  if (stale.length > 0) {
    await del(stale.map((b) => b.url));
  }

  await put(`${prefix}${KINDS[kind].file}`, body, {
    access: 'public',
    contentType: KINDS[kind].type,
    addRandomSuffix: true, // URL 추측 방지 — 조회는 항상 list()로
    cacheControlMaxAge: 300,
  });

  const after = await list({ prefix });
  const { expiresAt } = sessionTimes(after.blobs);
  return res.status(200).json({ ok: true, id, kind, bytes: body.length, expiresAt });
}

async function readBody(req) {
  // 런타임이 이미 본문을 버퍼로 만들어 둔 경우
  if (req.body !== undefined && req.body !== null) {
    return Buffer.isBuffer(req.body) ? req.body : Buffer.from(req.body);
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY + 1024) break; // 초과분은 더 읽지 않음
    chunks.push(chunk);
  }
  return chunks.length ? Buffer.concat(chunks) : null;
}
