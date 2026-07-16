import { head, list, del } from '@vercel/blob';
import {
  ID_RE,
  KINDS,
  sessionPrefix,
  sessionTimes,
  viewPage,
  gonePage,
  notFoundPage,
  landingPage,
  sendHTML,
} from './_shared.js';

/** 토큰(vercel_blob_rw_<STOREID>_…)에서 공개 blob 베이스 URL을 유도 */
function blobBase() {
  const m = /^vercel_blob_rw_([A-Za-z0-9]+)_/.exec(process.env.BLOB_READ_WRITE_TOKEN || '');
  return m ? `https://${m[1].toLowerCase()}.public.blob.vercel-storage.com` : null;
}

async function headSafe(url) {
  try {
    return await head(url);
  } catch {
    return null; // BlobNotFoundError 등 — 없는 파일
  }
}

/**
 * 세션 blob 조회. 결정적 경로에 head() 2회(simple op, 월 10K)로 확인해
 * list()(advanced op, 월 2K) 사용을 없앤다. 구버전(랜덤 suffix) 세션은 list()로 폴백.
 */
async function findSession(prefix) {
  const base = blobBase();
  if (base) {
    const blobs = (
      await Promise.all(
        Object.values(KINDS).map((k) => headSafe(`${base}/${prefix}${k.file}`))
      )
    ).filter(Boolean);
    if (blobs.length > 0) return blobs;
  }
  const { blobs } = await list({ prefix });
  return blobs;
}

export default async function handler(req, res) {
  const { id } = req.query;

  if (!id) return sendHTML(res, 200, landingPage());
  if (!ID_RE.test(id)) return sendHTML(res, 404, notFoundPage());

  const blobs = await findSession(sessionPrefix(id));
  if (blobs.length === 0) return sendHTML(res, 404, notFoundPage());

  const { expiresAt } = sessionTimes(blobs);
  if (Date.now() > expiresAt) {
    await del(blobs.map((b) => b.url));
    return sendHTML(res, 410, gonePage());
  }

  // 파일명 앞부분(kind)으로 매칭 — 구버전 랜덤 suffix('photo-xxxx.jpg')도 커버
  const latest = (kind) =>
    blobs
      .filter((b) => (b.pathname.split('/').pop() || '').startsWith(kind))
      .sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt))[0] ?? null;

  const photo = latest('photo');
  const video = latest('video');
  if (!photo && !video) return sendHTML(res, 404, notFoundPage());

  return sendHTML(res, 200, viewPage(expiresAt, photo, video));
}
