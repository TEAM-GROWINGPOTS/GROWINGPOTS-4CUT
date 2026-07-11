import { list, del } from '@vercel/blob';
import {
  ID_RE,
  sessionPrefix,
  sessionTimes,
  viewPage,
  gonePage,
  notFoundPage,
  landingPage,
  sendHTML,
} from './_shared.js';

export default async function handler(req, res) {
  const { id } = req.query;

  if (!id) return sendHTML(res, 200, landingPage());
  if (!ID_RE.test(id)) return sendHTML(res, 404, notFoundPage());

  const { blobs } = await list({ prefix: sessionPrefix(id) });
  if (blobs.length === 0) return sendHTML(res, 404, notFoundPage());

  const { expiresAt } = sessionTimes(blobs);
  if (Date.now() > expiresAt) {
    await del(blobs.map((b) => b.url));
    return sendHTML(res, 410, gonePage());
  }

  // addRandomSuffix 업로드는 'photo-xxxx.jpg' 형태가 되므로 파일명 앞부분(kind)으로 매칭
  const latest = (kind) =>
    blobs
      .filter((b) => (b.pathname.split('/').pop() || '').startsWith(kind))
      .sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt))[0] ?? null;

  const photo = latest('photo');
  const video = latest('video');
  if (!photo && !video) return sendHTML(res, 404, notFoundPage());

  return sendHTML(res, 200, viewPage(expiresAt, photo, video));
}
