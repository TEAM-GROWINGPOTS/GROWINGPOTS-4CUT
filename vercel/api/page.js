import { list, del } from '@vercel/blob';
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

  const latest = (file) =>
    blobs
      .filter((b) => b.pathname.includes(file))
      .sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt))[0] ?? null;

  const photo = latest(KINDS.photo.file);
  const video = latest(KINDS.video.file);
  if (!photo && !video) return sendHTML(res, 404, notFoundPage());

  return sendHTML(res, 200, viewPage(expiresAt, photo, video));
}
