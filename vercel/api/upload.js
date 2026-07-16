import { put } from '@vercel/blob';
import { ID_RE, KINDS, TTL_MS, sessionPrefix } from './_shared.js';

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

  // 결정적 경로 + 덮어쓰기 — 업로드당 Blob 고급 연산을 put 1회로 최소화 (Hobby 월 2K 한도 대비).
  // 랜덤 suffix를 빼도 세션 ID(10자 랜덤) 자체가 페이지 URL과 같은 엔트로피라 URL 추측 방어는 동등하다.
  // 재시도는 같은 경로를 덮어쓰고, 만료 판정은 페이지 접근 시 uploadedAt 기준으로 수행된다.
  await put(`${sessionPrefix(id)}${KINDS[kind].file}`, body, {
    access: 'public',
    contentType: KINDS[kind].type,
    addRandomSuffix: false,
    allowOverwrite: true,
    cacheControlMaxAge: 300,
  });

  // expiresAt은 근사값(첫 업로드가 사진이므로 실제와 수십 초 이내) — 앱은 이 값을 표시하지 않는다
  return res.status(200).json({ ok: true, id, kind, bytes: body.length, expiresAt: Date.now() + TTL_MS });
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
