import { TTL_MS } from './_shared.js';

export default function handler(req, res) {
  res.status(200).json({ ok: true, service: 'growingcut', ttlHours: TTL_MS / 3600000 });
}
