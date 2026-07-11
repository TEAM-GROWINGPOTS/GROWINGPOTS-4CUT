import { list, del } from '@vercel/blob';
import { SESSION_PREFIX, sessionTimes } from './_shared.js';

/**
 * 만료 세션 청소 (Vercel Cron이 호출).
 * 페이지/업로드 접근 시에도 즉시 만료 처리하므로, 크론은 아무도 다시 열지 않은
 * 세션의 저장 용량을 회수하는 역할이다.
 */
export default async function handler(req, res) {
  // Vercel Cron은 CRON_SECRET 환경변수가 있으면 Authorization 헤더를 보낸다
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.authorization !== `Bearer ${secret}`) {
    return res.status(401).json({ ok: false });
  }

  const sessions = new Map();
  let cursor;
  do {
    const page = await list({ prefix: SESSION_PREFIX, cursor, limit: 1000 });
    for (const blob of page.blobs) {
      const key = blob.pathname.split('/').slice(0, 2).join('/');
      if (!sessions.has(key)) sessions.set(key, []);
      sessions.get(key).push(blob);
    }
    cursor = page.cursor;
  } while (cursor);

  let removedSessions = 0;
  let removedBlobs = 0;
  for (const blobs of sessions.values()) {
    const { expiresAt } = sessionTimes(blobs);
    if (Date.now() > expiresAt) {
      await del(blobs.map((b) => b.url));
      removedSessions += 1;
      removedBlobs += blobs.length;
    }
  }

  return res.status(200).json({ ok: true, sessions: sessions.size, removedSessions, removedBlobs });
}
