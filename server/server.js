#!/usr/bin/env node
'use strict';

/**
 * GROWING CUT 임시 공유 서버 (의존성 없음, Node 18+)
 *
 * 아이패드 앱이 합성한 사진/영상을 업로드하면 4시간짜리 임시 링크를 제공한다.
 * QR로 접속한 휴대폰에서 사진과 '움직이는 네컷' 영상을 내려받을 수 있다.
 *
 *   PUT  /api/s/:id/photo   (image/jpeg)  → { ok, expiresAt }
 *   PUT  /api/s/:id/video   (video/mp4)   → { ok, expiresAt }
 *   GET  /api/health                      → { ok: true }
 *   GET  /s/:id             다운로드 페이지 (만료 시 410)
 *   GET  /f/:id/photo.jpg   인라인 미리보기
 *   GET  /f/:id/video.mp4   인라인 미리보기 (Range 지원)
 *   GET  /d/:id/photo.jpg   다운로드 (Content-Disposition: attachment)
 *   GET  /d/:id/video.mp4   다운로드
 *
 * 주의: 인증 없는 LAN 데모용 서버다. 공용 인터넷에 그대로 노출하지 말 것.
 */

const http = require('http');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');

const PORT = Number(process.env.PORT || 8787);
const TTL_MS = Number(process.env.TTL_HOURS || 4) * 60 * 60 * 1000;
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const MAX_BODY = 500 * 1024 * 1024; // 500MB

const ID_RE = /^[a-z0-9]{6,40}$/i;
const FILES = {
  photo: { name: 'photo.jpg', type: 'image/jpeg' },
  video: { name: 'video.mp4', type: 'video/mp4' },
};

fs.mkdirSync(DATA_DIR, { recursive: true });

// ---------- 세션 저장소 ----------

function sessionDir(id) {
  return path.join(DATA_DIR, id);
}

async function sessionMeta(id) {
  try {
    const raw = await fsp.readFile(path.join(sessionDir(id), 'meta.json'), 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function ensureSession(id) {
  const dir = sessionDir(id);
  await fsp.mkdir(dir, { recursive: true });
  let meta = await sessionMeta(id);
  if (!meta) {
    meta = { id, createdAt: Date.now() };
    await fsp.writeFile(path.join(dir, 'meta.json'), JSON.stringify(meta));
  }
  return meta;
}

function isExpired(meta) {
  return Date.now() > meta.createdAt + TTL_MS;
}

async function removeSession(id) {
  await fsp.rm(sessionDir(id), { recursive: true, force: true }).catch(() => {});
}

async function sweepExpired() {
  let entries = [];
  try {
    entries = await fsp.readdir(DATA_DIR);
  } catch {
    return;
  }
  for (const id of entries) {
    if (!ID_RE.test(id)) continue;
    const meta = await sessionMeta(id);
    if (!meta || isExpired(meta)) {
      await removeSession(id);
      log(`만료 세션 정리: ${id}`);
    }
  }
}

// ---------- HTTP 유틸 ----------

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

function sendHTML(res, code, html) {
  res.writeHead(code, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(html);
}

function receiveBody(req, filePath, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    let received = 0;
    const stream = fs.createWriteStream(filePath);
    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > limit) {
        req.destroy();
        stream.destroy();
        fs.rm(filePath, { force: true }, () => {});
        reject(new Error('body too large'));
      }
    });
    req.pipe(stream);
    stream.on('finish', () => resolve(received));
    stream.on('error', reject);
    req.on('error', reject);
  });
}

/** Range를 지원하는 정적 파일 응답 (iOS Safari <video>에 필수) */
async function serveFile(req, res, filePath, contentType, downloadName) {
  let stat;
  try {
    stat = await fsp.stat(filePath);
  } catch {
    return sendJSON(res, 404, { ok: false, error: 'not found' });
  }

  const headers = {
    'Content-Type': contentType,
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
  };
  if (downloadName) {
    headers['Content-Disposition'] = `attachment; filename="${downloadName}"`;
  }

  if (req.method === 'HEAD') {
    res.writeHead(200, { ...headers, 'Content-Length': stat.size });
    return res.end();
  }

  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) {
      res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` });
      return res.end();
    }
    let start = m[1] === '' ? undefined : Number(m[1]);
    let end = m[2] === '' ? undefined : Number(m[2]);
    if (start === undefined) {
      // suffix range: 마지막 N바이트
      start = Math.max(0, stat.size - (end ?? 0));
      end = stat.size - 1;
    } else {
      end = Math.min(end ?? stat.size - 1, stat.size - 1);
    }
    if (start > end || start >= stat.size) {
      res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` });
      return res.end();
    }
    res.writeHead(206, {
      ...headers,
      'Content-Range': `bytes ${start}-${end}/${stat.size}`,
      'Content-Length': end - start + 1,
    });
    fs.createReadStream(filePath, { start, end }).pipe(res);
  } else {
    res.writeHead(200, { ...headers, 'Content-Length': stat.size });
    fs.createReadStream(filePath).pipe(res);
  }
}

// ---------- 페이지 ----------

function pageShell(title, inner) {
  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${title}</title>
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Pretendard", sans-serif;
    background: #101014; color: #f4f4f6;
    min-height: 100dvh; display: flex; flex-direction: column; align-items: center;
    padding: 28px 20px 48px;
  }
  .brand { font-weight: 800; letter-spacing: .35em; font-size: 13px; color: #ffb1c8; margin-bottom: 6px; }
  h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
  .sub { color: #9a9aa4; font-size: 13px; margin-bottom: 20px; text-align: center; line-height: 1.5; }
  .timer { display: inline-block; background: #1e1e26; border: 1px solid #34343e; border-radius: 999px;
    padding: 8px 16px; font-size: 13px; color: #ffd9e8; margin-bottom: 24px; }
  .timer b { color: #ff8fb1; font-variant-numeric: tabular-nums; }
  .card { width: 100%; max-width: 420px; background: #17171c; border: 1px solid #26262e;
    border-radius: 20px; padding: 16px; margin-bottom: 18px; }
  .card h2 { font-size: 15px; margin-bottom: 12px; color: #d6d6de; }
  .card img, .card video { width: 100%; border-radius: 12px; display: block; background: #000; }
  .btn { display: block; width: 100%; text-align: center; margin-top: 12px; padding: 14px;
    border-radius: 14px; font-size: 16px; font-weight: 700; text-decoration: none;
    background: #ff8fb1; color: #2b0d19; }
  .btn.ghost { background: #26262e; color: #f4f4f6; }
  .foot { color: #6b6b74; font-size: 12px; margin-top: 12px; text-align: center; line-height: 1.6; }
  .big { font-size: 64px; margin: 40px 0 16px; }
</style>
</head>
<body>
<div class="brand">GROWING CUT</div>
${inner}
</body>
</html>`;
}

function viewPage(id, meta, hasPhoto, hasVideo) {
  const expiresAt = meta.createdAt + TTL_MS;
  return pageShell('그로잉컷 · 네컷 다운로드', `
<h1>네컷이 도착했어요 🎞️</h1>
<p class="sub">아래에서 사진과 움직이는 네컷 영상을<br>기기에 저장할 수 있어요.</p>
<div class="timer">링크 만료까지 <b id="remain">--:--:--</b></div>

${hasPhoto ? `
<div class="card">
  <h2>📷 네컷 사진</h2>
  <img src="/f/${id}/photo.jpg" alt="네컷 사진">
  <a class="btn" href="/d/${id}/photo.jpg" download="growingcut-${id}.jpg">사진 저장</a>
</div>` : ''}

${hasVideo ? `
<div class="card">
  <h2>🎬 움직이는 네컷</h2>
  <video src="/f/${id}/video.mp4" playsinline muted autoplay loop controls></video>
  <a class="btn" href="/d/${id}/video.mp4" download="growingcut-${id}.mp4">영상 저장</a>
</div>` : ''}

<p class="foot">이 링크는 촬영 후 4시간 동안만 유효해요.<br>사진이 안 보이면 잠시 후 새로고침 해주세요.</p>
<script>
  const end = ${expiresAt};
  function tick() {
    const left = end - Date.now();
    if (left <= 0) { location.reload(); return; }
    const h = String(Math.floor(left / 3600000)).padStart(2, '0');
    const m = String(Math.floor(left % 3600000 / 60000)).padStart(2, '0');
    const s = String(Math.floor(left % 60000 / 1000)).padStart(2, '0');
    document.getElementById('remain').textContent = h + ':' + m + ':' + s;
  }
  tick(); setInterval(tick, 1000);
</script>`);
}

function gonePage() {
  return pageShell('링크 만료', `
<div class="big">⏰</div>
<h1>링크가 만료됐어요</h1>
<p class="sub">네컷 링크는 촬영 후 4시간 동안만 유효해요.<br>기기에서 새로 촬영해 주세요.</p>`);
}

function notFoundPage() {
  return pageShell('찾을 수 없음', `
<div class="big">🎞️</div>
<h1>여기엔 아무것도 없어요</h1>
<p class="sub">주소를 다시 확인해 주세요.</p>`);
}

// ---------- 라우팅 ----------

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/api/health') {
      return sendJSON(res, 200, { ok: true, service: 'growingcut', ttlHours: TTL_MS / 3600000 });
    }

    // PUT /api/s/:id/(photo|video)
    if (req.method === 'PUT' && parts[0] === 'api' && parts[1] === 's' && parts.length === 4) {
      const [, , id, kind] = parts;
      if (!ID_RE.test(id) || !FILES[kind]) {
        return sendJSON(res, 400, { ok: false, error: 'bad id or kind' });
      }
      const meta = await ensureSession(id);
      if (isExpired(meta)) {
        await removeSession(id);
        return sendJSON(res, 410, { ok: false, error: 'expired' });
      }
      const filePath = path.join(sessionDir(id), FILES[kind].name);
      const bytes = await receiveBody(req, filePath);
      log(`업로드: ${id}/${kind} (${(bytes / 1024 / 1024).toFixed(1)}MB)`);
      return sendJSON(res, 200, { ok: true, id, kind, bytes, expiresAt: meta.createdAt + TTL_MS });
    }

    // GET /s/:id — 다운로드 페이지
    if (req.method === 'GET' && parts[0] === 's' && parts.length === 2) {
      const id = parts[1];
      if (!ID_RE.test(id)) return sendHTML(res, 404, notFoundPage());
      const meta = await sessionMeta(id);
      if (!meta) return sendHTML(res, 404, notFoundPage());
      if (isExpired(meta)) {
        await removeSession(id);
        return sendHTML(res, 410, gonePage());
      }
      const hasPhoto = fs.existsSync(path.join(sessionDir(id), FILES.photo.name));
      const hasVideo = fs.existsSync(path.join(sessionDir(id), FILES.video.name));
      if (!hasPhoto && !hasVideo) return sendHTML(res, 404, notFoundPage());
      return sendHTML(res, 200, viewPage(id, meta, hasPhoto, hasVideo));
    }

    // GET|HEAD /f|d/:id/(photo.jpg|video.mp4)
    if ((req.method === 'GET' || req.method === 'HEAD') && (parts[0] === 'f' || parts[0] === 'd') && parts.length === 3) {
      const [mode, id, fileName] = parts;
      const kind = fileName === FILES.photo.name ? 'photo' : fileName === FILES.video.name ? 'video' : null;
      if (!ID_RE.test(id) || !kind) return sendJSON(res, 404, { ok: false, error: 'not found' });
      const meta = await sessionMeta(id);
      if (!meta) return sendJSON(res, 404, { ok: false, error: 'not found' });
      if (isExpired(meta)) {
        await removeSession(id);
        return sendJSON(res, 410, { ok: false, error: 'expired' });
      }
      return serveFile(
        req, res,
        path.join(sessionDir(id), FILES[kind].name),
        FILES[kind].type,
        mode === 'd' ? `growingcut-${id}.${kind === 'photo' ? 'jpg' : 'mp4'}` : undefined
      );
    }

    if (req.method === 'GET' && parts.length === 0) {
      return sendHTML(res, 200, pageShell('GROWING CUT', `
<div class="big">🎞️</div>
<h1>그로잉컷 공유 서버</h1>
<p class="sub">아이패드 앱에서 촬영하면 QR로 이 서버의<br>임시 링크(4시간)가 만들어져요.</p>`));
    }

    sendJSON(res, 404, { ok: false, error: 'not found' });
  } catch (err) {
    log('오류:', err.message);
    if (!res.headersSent) sendJSON(res, 500, { ok: false, error: 'internal' });
    else res.end();
  }
});

function lanAddresses() {
  const result = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal) result.push({ name, address: a.address });
    }
  }
  return result;
}

server.listen(PORT, () => {
  console.log('');
  console.log('🎞️  GROWING CUT 공유 서버 시작');
  console.log(`    보관 시간: ${TTL_MS / 3600000}시간 · 데이터: ${DATA_DIR}`);
  console.log('');
  console.log('    앱 설정(⚙️)에 아래 주소 중 하나를 입력하세요:');
  console.log(`      http://localhost:${PORT}  (시뮬레이터 전용)`);
  for (const { name, address } of lanAddresses()) {
    console.log(`      http://${address}:${PORT}  (${name} — 실기기/휴대폰용)`);
  }
  console.log('');
});

setInterval(sweepExpired, 30 * 60 * 1000);
sweepExpired();
