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

// ---------- 페이지 (Figma 5930:29633 "웹 ui" — #191919 다크 + 라임 토큰) ----------

const INSTAGRAM_URL = process.env.GP_INSTAGRAM_URL || 'https://instagram.com/growingpots';
const LANDING_URL = process.env.GP_LANDING_URL || 'https://growingcut.vercel.app';

// growing pots 워드마크 (Figma header-logo.svg 원본 패스 인라인, 141.69×33.67)
const LOGO_SVG = `<svg class="logo" role="img" aria-label="growing pots" viewBox="0 0 141.691 33.6692" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M125.945 8.7625C125.331 6.68531 123.426 5.15459 121.136 5.15459H120.981C120.867 5.15459 120.649 5.15765 120.404 5.20459C120.147 5.25382 119.734 5.37436 119.344 5.70716C118.543 6.39035 118.545 7.33382 118.546 7.54237L118.546 7.55484V8.77939C117.775 8.84403 117.103 9.27576 116.714 9.90531C115.278 8.74665 113.45 8.12013 111.473 8.07795L111.258 8.07567C108.958 8.07568 106.846 8.85298 105.295 10.3327C104.917 10.6937 104.579 11.0898 104.285 11.516C104.027 11.0822 103.727 10.6777 103.384 10.3076C101.997 8.81239 100.074 8.0597 97.9754 8.05968C96.7711 8.05968 95.5411 8.3558 94.4983 8.94288C94.0396 8.67066 93.5164 8.49669 92.9573 8.44945V8.42776L90.9251 8.42821C89.6732 8.42863 88.6934 9.45396 88.6927 10.6627V27.4804C88.6929 28.6496 89.6265 29.7311 90.9411 29.7313H94.0515C95.2644 29.7311 96.2997 28.7525 96.2999 27.4804V24.2906C96.8662 24.4098 97.4419 24.4682 97.9987 24.4682C100.272 24.4682 102.218 23.5882 103.558 21.9696C103.823 21.65 104.057 21.3088 104.264 20.9501C104.567 21.3924 104.916 21.8024 105.31 22.1744C106.863 23.6447 108.972 24.4139 111.258 24.4139L111.472 24.4116C113.676 24.3651 115.699 23.598 117.199 22.1707C117.731 21.665 118.182 21.0901 118.546 20.4587V22.0885C118.546 23.3843 119.588 24.4727 120.926 24.473H123.772C125.109 24.473 126.153 23.3855 126.153 22.0885V21.4707C126.505 22.0257 126.955 22.5233 127.494 22.9471C128.839 24.0029 130.602 24.4997 132.523 24.4997L132.701 24.4984C134.542 24.4692 136.295 23.9854 137.649 22.9446C139.099 21.83 139.952 20.1736 139.952 18.2171C139.952 17.0274 139.659 15.9184 138.968 14.9981C139.385 14.5996 139.642 14.0384 139.642 13.4249V13.3954L139.641 13.3662C139.59 11.5838 138.822 10.0265 137.523 8.94311C136.248 7.87967 134.576 7.36167 132.802 7.36166C131.017 7.36166 129.269 7.80926 127.915 8.83899C127.74 8.97227 127.573 9.11379 127.416 9.26323C127.018 8.95218 126.515 8.7625 125.952 8.7625H125.945Z" fill="#FFFFFF"/><path d="M60.0822 8.9737C60.6124 8.28087 60.9259 7.41201 60.9259 6.4739C60.9259 3.4215 57.7052 1.37964 54.8063 2.95596C54.248 3.25928 53.7637 3.71081 53.424 4.27276C52.9235 3.97981 52.3516 3.79721 51.7466 3.7517L51.7462 3.75147L51.6473 3.74645C51.4226 3.73958 51.2227 3.76493 51.1426 3.77509L51.1397 3.77545C50.9988 3.79331 50.8424 3.81868 50.6831 3.84715C50.3615 3.90457 49.951 3.98828 49.4765 4.09078C48.5235 4.29665 47.2451 4.5933 45.7625 4.94794C42.7936 5.65809 38.9596 6.61218 35.1725 7.56739C31.3838 8.52302 27.6351 9.48141 24.834 10.2008C23.5291 10.5359 22.4297 10.8194 21.6273 11.0264C21.0557 10.3851 20.0967 9.67332 18.7014 9.67332H17.615C17.2229 9.67345 16.8578 9.77172 16.54 9.94321C16.1881 9.71875 15.7696 9.58701 15.3157 9.58701H12.888C12.4466 9.58707 12.034 9.68845 11.6683 9.86695C10.8025 9.44244 9.81661 9.22215 8.80725 9.19747L8.61522 9.19496C4.08137 9.19498 1.0544 12.7842 1.05439 17.2346C1.05441 18.99 1.50903 20.6225 2.39471 21.9572C2.13785 22.0442 1.85807 22.1954 1.60217 22.4536C1.08714 22.9733 1.00781 23.5847 1.00781 23.9015V24.004L1.01809 24.1061C1.23093 26.2085 2.1165 28.0408 3.63434 29.3375C5.14077 30.6243 7.10733 31.2461 9.25433 31.2509H9.2589C11.6736 31.2509 13.8289 30.4672 15.3705 28.8328C16.0643 28.0973 16.5876 27.2374 16.9531 26.2874C17.2053 26.3773 17.4776 26.4271 17.7632 26.4271H20.6256C20.9279 26.427 21.2124 26.3726 21.4729 26.275C21.8874 27.2532 22.4897 28.1249 23.2583 28.8522C24.8118 30.3225 26.9213 31.0917 29.2071 31.0918L29.4208 31.0895C31.6246 31.0429 33.6478 30.2759 35.1481 28.8486C35.7596 28.2669 36.264 27.5934 36.6521 26.8479L36.7554 27.1719L36.7624 27.1925C37.0973 28.1705 38.0229 28.9112 39.1574 28.9112H41.8872C42.9813 28.9112 43.9756 28.2013 44.3029 27.1192L44.3034 27.1194L44.3498 26.9667L44.3922 27.1082L44.3924 27.108C44.7017 28.1472 45.6627 28.9192 46.8119 28.9192H49.3868C50.4824 28.919 51.4287 28.2162 51.7738 27.2078L53.2477 22.9537C53.5811 23.9083 54.4837 24.6092 55.5749 24.6093H58.251C58.7411 24.6093 59.1929 24.4674 59.5726 24.2251H59.7249C60.067 24.4235 60.4652 24.5386 60.8944 24.5388H63.8189C65.0863 24.5387 66.0887 23.5406 66.157 22.3258C66.1611 22.2529 66.2199 22.1936 66.2929 22.1936C66.3659 22.1936 66.4247 22.2529 66.4288 22.3258C66.497 23.539 67.4974 24.5386 68.7664 24.5388H71.6909C71.6967 24.5388 71.7025 24.5384 71.7083 24.5383C72.1209 25.9932 72.9035 27.2591 74.0373 28.2257C75.5451 29.5111 77.5124 30.1309 79.6575 30.1309C82.0722 30.1309 84.2275 29.3472 85.7691 27.7129C87.2966 26.0935 88.0018 23.8727 88.0018 21.409V10.6705C88.0013 9.47447 87.0343 8.4681 85.8011 8.46726H83.2869C82.8455 8.46727 82.4329 8.56853 82.0671 8.74697C81.1466 8.2955 80.09 8.07499 79.0138 8.07498C76.3905 8.07498 74.2715 9.27672 72.9516 11.1516C72.7828 10.8862 72.5926 10.6333 72.3794 10.3953C71.2182 9.09924 69.6057 8.49037 67.8442 8.45356L67.6732 8.45173C66.5239 8.45174 65.3644 8.71024 64.3612 9.2525C63.8629 8.9817 63.2943 8.82826 62.6943 8.82826H60.9024C60.613 8.82833 60.3372 8.88021 60.0831 8.97462L60.0822 8.9737Z" fill="#FFFFFF"/><path d="M8.61694 11.2277C10.1834 11.2277 11.4243 11.8315 12.0525 12.7883L12.1301 12.2787C12.1921 11.9022 12.51 11.6198 12.89 11.6197H15.3174C15.457 11.6197 15.5734 11.7375 15.5734 11.8786V22.53C15.5733 26.7026 13.2002 29.2204 9.26061 29.2204C5.73977 29.2125 3.37449 27.1967 3.04102 23.9025C3.04102 23.8868 3.0488 23.8789 3.06431 23.8789H4.84006C5.55353 23.8789 6.25942 24.1691 6.72473 24.7181C7.26759 25.3691 8.01203 25.9495 9.23732 25.9495C10.9434 25.9495 12.0214 24.9221 12.0214 23.2672C12.0214 22.6947 11.432 22.3495 10.9279 22.6005C10.261 22.9377 9.43887 23.1259 8.54707 23.1259C5.32095 23.1337 3.0876 20.7337 3.0876 17.2356C3.0876 13.7374 5.36752 11.2277 8.61694 11.2277ZM29.2088 16.7864C32.8692 16.7864 35.5448 19.257 35.5448 22.9355C35.5448 26.614 32.8693 29.0612 29.2088 29.0612C25.5484 29.0612 22.8495 26.614 22.8495 22.9355C22.8495 19.257 25.5251 16.7865 29.2088 16.7864ZM79.0156 10.1077C80.5821 10.1077 81.8229 10.7117 82.4511 11.6686L82.5287 11.1587C82.5908 10.7822 82.9086 10.5 83.2886 10.5H85.8014C85.8944 10.5 85.972 10.5783 85.972 10.6723V21.41C85.972 25.5826 83.5989 28.1004 79.6592 28.1004C76.1461 28.1004 73.7729 26.0847 73.4394 22.7905C73.4394 22.7748 73.4472 22.767 73.4627 22.767H75.2387C75.9521 22.767 76.6578 23.0571 77.1231 23.6061C77.666 24.2571 78.4106 24.8375 79.6359 24.8375C81.3421 24.8375 82.42 23.81 82.42 22.155C82.42 21.5825 81.8306 21.2375 81.3265 21.4885C80.6596 21.8258 79.8375 22.0139 78.9457 22.0139C75.7196 22.0139 73.486 19.6139 73.486 16.1158C73.486 12.6177 75.7661 10.1077 79.0156 10.1077ZM97.9771 10.0924C101.18 10.0924 103.413 12.3512 103.414 16.1003C103.414 19.8494 101.436 22.4377 98.0004 22.4377C96.4106 22.4377 94.9371 21.8339 94.2701 20.9476V27.4811C94.2701 27.6066 94.1693 27.7008 94.053 27.7008H90.9431C90.819 27.7008 90.7259 27.5988 90.7259 27.4811V10.6648C90.726 10.5551 90.819 10.4609 90.9275 10.4609V10.4689H92.6492C93.4635 10.4689 94.146 11.0806 94.2468 11.8884C94.8905 10.8139 96.3408 10.0924 97.9771 10.0924ZM35.39 15.2488H37.6236C38.3448 15.2488 38.973 15.7352 39.1669 16.4332L39.8958 19.0451C40.1362 19.9236 40.3611 20.9119 40.5394 21.9315H40.6792C40.8498 20.9903 40.9893 20.4726 41.4313 19.0451L42.5248 15.5C42.5713 15.351 42.711 15.2488 42.8662 15.2488H45.9758C46.1309 15.2488 46.2707 15.3587 46.3172 15.5078L47.3253 19.0451C47.4261 19.3902 47.8527 21.053 48.0388 21.9785H48.1783C48.38 21.0138 48.8144 19.4138 48.9152 19.0451L49.7139 16.2843C49.8923 15.6647 50.4507 15.2411 51.0866 15.2411H53.483C53.6226 15.2411 53.7233 15.3822 53.6769 15.5155L49.8536 26.5511C49.7838 26.755 49.5977 26.8886 49.3883 26.8886H46.8136C46.5964 26.8886 46.4025 26.7394 46.3405 26.5276L45.3399 23.1786C44.8979 21.7041 44.6187 20.5433 44.4791 19.8687C44.4558 19.7668 44.324 19.7668 44.3008 19.8687C44.1689 20.4491 43.9129 21.4139 43.3623 23.2492L42.362 26.5276C42.2999 26.7394 42.106 26.8806 41.8889 26.8806H39.1591C38.942 26.8806 38.7558 26.7395 38.686 26.5356L35.1729 15.5078C35.1264 15.3745 35.2272 15.2334 35.3667 15.2333L35.39 15.2488ZM29.2088 20.0101C27.5802 20.0101 26.4247 21.1787 26.4247 22.9199C26.4248 24.6611 27.557 25.8533 29.2088 25.8534C30.8451 25.8534 31.9695 24.6847 31.9696 22.9199C31.9696 21.1552 30.8374 20.0101 29.2088 20.0101ZM51.5961 5.77846C52.5344 5.84906 53.2478 6.57069 53.2478 7.51974C53.2478 8.50014 52.5266 9.057 51.4951 9.29229L21.3477 16.9139C21.1538 16.9609 21.0221 17.1336 21.0143 17.3296V24.0121C21.0066 24.2238 20.836 24.3965 20.6266 24.3966H17.7649C17.5555 24.3966 17.3847 24.2238 17.3847 24.0121V11.9412C17.3848 11.8079 17.4856 11.7061 17.6174 11.706H18.7031C20.1597 11.706 20.6875 13.3656 20.6885 13.3687C20.6885 13.3687 50.3397 5.68434 51.5961 5.77846ZM58.3246 10.2668C58.565 10.2669 58.7589 10.4628 58.7589 10.7059L58.6867 22.1395C58.6867 22.3826 58.4928 22.5788 58.2525 22.5788H55.5768C55.3364 22.5788 55.1425 22.3826 55.1425 22.1395L55.2147 10.7059C55.2147 10.4628 55.4086 10.2668 55.649 10.2668H58.3246ZM67.6749 10.4844C70.4202 10.4844 72.0022 12.257 72.0023 15.308V22.1945C72.0023 22.3671 71.8628 22.5082 71.6922 22.5083H68.7684C68.5978 22.5082 68.4583 22.3671 68.4583 22.1945V16.1709C68.4583 14.7041 67.6517 13.7473 66.4341 13.7473C65.0304 13.7473 64.1309 14.6806 64.1309 16.1238V22.1945C64.1309 22.3671 63.9912 22.5083 63.8206 22.5083H60.8968C60.7262 22.5082 60.5867 22.3671 60.5867 22.1945H60.5789V11.1902C60.579 11.0099 60.7262 10.861 60.9046 10.8609H62.6961C63.4018 10.8609 64.0144 11.3708 64.1462 12.0688C64.8597 11.0649 66.1704 10.4844 67.6749 10.4844ZM132.804 9.39436C135.58 9.39437 137.542 11.0101 137.612 13.4258C137.612 13.5042 137.55 13.5669 137.473 13.5669H135.96C135.131 13.5669 134.278 13.2846 133.75 12.6337C133.51 12.3357 133.13 12.1552 132.626 12.1551C131.773 12.1551 131.23 12.6023 131.23 13.269C131.23 13.8337 131.695 14.1553 132.548 14.3593L134.82 14.8534C136.821 15.3004 137.922 16.2338 137.922 18.2181C137.922 20.8613 135.697 22.4692 132.525 22.4692C129.353 22.4692 127.383 20.83 127.274 18.4378C127.274 18.3358 127.36 18.2417 127.461 18.2416H129.26C130.012 18.2416 130.687 18.6024 131.214 19.1435C131.524 19.4572 132.013 19.6299 132.68 19.6299C133.851 19.6299 134.394 19.2063 134.394 18.5631C134.394 18.1945 134.2 17.7945 133.293 17.5984L131.044 17.1043C128.795 16.6101 127.693 15.622 127.693 13.4493C127.693 10.8767 129.865 9.39436 132.804 9.39436ZM121.137 7.18728C122.789 7.18728 124.123 8.53619 124.123 10.2068V10.4499C124.123 10.7636 124.084 10.7952 124.394 10.7952H125.953C126.155 10.7952 126.31 10.9599 126.31 11.156V13.4149C126.31 13.6188 126.147 13.7756 125.953 13.7756H124.294C124.201 13.7756 124.123 13.8541 124.123 13.9482V22.0895C124.123 22.2856 123.968 22.4425 123.774 22.4425H120.928C120.734 22.4424 120.579 22.2855 120.579 22.0895V13.956C120.579 13.8619 120.501 13.7834 120.408 13.7834H118.749C118.547 13.7833 118.392 13.6187 118.392 13.4226V11.1637C118.392 10.9599 118.555 10.803 118.749 10.803H120.408C120.501 10.8029 120.579 10.7244 120.579 10.6303V7.55581C120.579 7.24211 120.672 7.18729 120.982 7.18728H121.137ZM111.26 10.1084C114.92 10.1084 117.596 12.5791 117.596 16.2576C117.596 19.9362 114.92 22.3834 111.26 22.3834C107.6 22.3833 104.901 19.9361 104.901 16.2576C104.901 12.5791 107.576 10.1084 111.26 10.1084ZM9.30719 14.357C7.67086 14.357 6.65488 15.5022 6.65486 17.1493C6.65486 18.7964 7.76393 20.0121 9.33048 20.0121C10.9435 20.0121 12.0292 18.8669 12.0292 17.1493C12.0291 15.4316 10.9435 14.357 9.30719 14.357ZM97.1085 13.3865C95.4257 13.3865 94.3012 14.5552 94.3012 16.2964C94.3012 18.0377 95.4567 19.2063 97.1085 19.2063C98.7914 19.2063 99.8538 18.022 99.8538 16.2964C99.8538 14.5709 98.7914 13.3866 97.1085 13.3865ZM111.26 13.3322C109.631 13.3322 108.468 14.5009 108.468 16.2421C108.468 17.9832 109.6 19.1755 111.26 19.1755C112.896 19.1755 114.021 18.0068 114.021 16.2421C114.021 14.4773 112.889 13.3322 111.26 13.3322ZM79.7058 13.2372C78.0695 13.2372 77.0535 14.3824 77.0535 16.0295C77.0535 17.6765 78.1624 18.8923 79.7289 18.8924C81.3419 18.8924 82.4278 17.7472 82.4278 16.0295C82.4278 14.3119 81.3421 13.2373 79.7058 13.2372ZM55.7784 4.7416C57.3217 3.90236 58.8961 4.96112 58.8961 6.47488C58.8961 7.62001 57.9965 8.52212 56.8952 8.52212C55.4605 8.52212 54.4057 7.06308 55.0727 5.51794H55.0649C55.2045 5.18855 55.4605 4.91415 55.7784 4.7416Z" fill="#242424"/></svg>`;

function pageShell(title, inner) {
  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${title}</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.min.css">
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: "Pretendard", -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
    background: #191919; color: #FFFFFF; min-height: 100dvh;
  }
  .page { width: 100%; max-width: 420px; margin: 0 auto; display: flex; flex-direction: column;
    align-items: center; padding: 89px 0 144px; }
  .logo { width: 141.69px; height: 33.67px; display: block; }
  .head { display: flex; flex-direction: column; align-items: center; gap: 39px; }
  .head-top { display: flex; flex-direction: column; align-items: center; gap: 18px; }
  .title { font-size: 24px; font-weight: 600; line-height: 1.3; letter-spacing: -0.24px;
    color: #FFFFFF; text-align: center; }
  .title .accent { color: #D7F856; }
  .sub { font-size: 16px; font-weight: 500; line-height: 1.5; letter-spacing: -0.16px;
    color: #CECECE; text-align: center; }
  .timer { display: flex; align-items: center; gap: 4px; background: rgba(255,255,255,0.1);
    border-radius: 30px; padding: 8px 16px; font-size: 16px; font-weight: 600; line-height: 1.5;
    letter-spacing: -0.16px; color: #CECECE; }
  .timer b { font-weight: 600; color: #D7F856; font-variant-numeric: tabular-nums; }
  .carousel { display: flex; gap: 12px; width: 100%; margin-top: 60px; padding: 0 27.5px;
    overflow-x: auto; scroll-snap-type: x mandatory; scroll-padding-left: 27.5px;
    -webkit-overflow-scrolling: touch; scrollbar-width: none; }
  .carousel::-webkit-scrollbar { display: none; }
  .carousel.single { justify-content: center; }
  .card { flex: 0 0 248px; scroll-snap-align: start; background: #242424; border-radius: 6px;
    overflow: hidden; padding: 15px 18.9px 30px; display: flex; flex-direction: column;
    align-items: center; gap: 12px; }
  .card-main { display: flex; flex-direction: column; align-items: flex-start; gap: 9px; }
  .card-label { width: 210.17px; font-size: 14px; font-weight: 700; line-height: 1.3;
    letter-spacing: -0.14px; color: #E7E7E7; }
  .media { width: 210.17px; height: 372.62px; object-fit: cover; display: block;
    background: #D7F856; border: 0; }
  .btn { display: flex; align-items: center; justify-content: center; width: 209px; height: 33px;
    background: #E3FF75; border-radius: 6px; font-size: 12px; font-weight: 600; line-height: 1.5;
    letter-spacing: -0.12px; color: #191919; text-decoration: none; }
  .dots { display: flex; gap: 8px; margin-top: 31px; }
  .dot { width: 10px; height: 10px; border-radius: 10px; background: #737373;
    transition: width .25s, background-color .25s; }
  .dot.on { width: 20px; background: #E3FF75; }
  .foot { display: flex; flex-direction: column; align-items: center; margin-top: 35px;
    padding: 0 20px; width: 100%; }
  .notice { font-size: 14px; font-weight: 500; line-height: 1.5; letter-spacing: -0.14px;
    color: #ACACAC; text-align: center; }
  .more { margin: 66px 0 18px; font-size: 16px; font-weight: 600; line-height: 1.5;
    letter-spacing: -0.16px; color: #F2FFB8; text-align: center; }
  .linkrow { display: flex; align-items: center; justify-content: center; width: 308px;
    max-width: 100%; height: 44px; background: #373737; border-radius: 8px; font-size: 16px;
    font-weight: 600; line-height: 1.5; letter-spacing: -0.16px; color: #FFFFFF; text-decoration: none; }
  .linkrow + .linkrow { margin-top: 10px; }
  .big { font-size: 64px; margin: 40px 0 16px; }
  .simple { justify-content: center; min-height: 100dvh; padding: 48px 20px; }
  .simple .title { margin-bottom: 12px; }
</style>
</head>
<body>
${inner}
</body>
</html>`;
}

function viewPage(id, meta, hasPhoto, hasVideo) {
  const expiresAt = meta.createdAt + TTL_MS;
  const single = !(hasPhoto && hasVideo);
  return pageShell('growing pots · 네컷 다운로드', `
<main class="page">
  <header class="head">
    <div class="head-top">
      ${LOGO_SVG}
      <h1 class="title"><span class="accent">사진</span>이 도착했어요!</h1>
      <p class="sub">아래에서 사진과 움직이는 영상을<br>기기에 저장할 수 있어요!</p>
    </div>
    <div class="timer"><span>링크 만료까지</span> <b id="remain">--:--:--</b></div>
  </header>

  <section class="carousel${single ? ' single' : ''}" id="car">
${hasPhoto ? `    <article class="card">
      <div class="card-main">
        <p class="card-label">Photo</p>
        <img class="media" src="/f/${id}/photo.jpg" alt="네컷 사진">
      </div>
      <a class="btn" href="/d/${id}/photo.jpg" download="growingcut-${id}.jpg">사진 저장</a>
    </article>` : ''}
${hasVideo ? `    <article class="card">
      <div class="card-main">
        <p class="card-label">Video</p>
        <video class="media" src="/f/${id}/video.mp4" playsinline muted autoplay loop></video>
      </div>
      <a class="btn" href="/d/${id}/video.mp4" download="growingcut-${id}.mp4">영상 저장</a>
    </article>` : ''}
  </section>
${single ? '' : `
  <div class="dots">
    <span class="dot on"></span>
    <span class="dot"></span>
  </div>`}

  <footer class="foot">
    <p class="notice">이 링크는 촬영 후 4시간 동안만 유효해요.<br>사진이 안 보이면 잠시 후 새로고침 해주세요.</p>
    <p class="more">Growing Pots가 더 궁금하다면?</p>
    <a class="linkrow" href="${INSTAGRAM_URL}" target="_blank" rel="noopener">Growing Pots 인스타 보러 가기</a>
    <a class="linkrow" href="${LANDING_URL}" target="_blank" rel="noopener">Growing Pots 랜딩 페이지 보러 가기</a>
  </footer>
</main>
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

  const car = document.getElementById('car');
  const dots = document.querySelectorAll('.dot');
  function syncDots() {
    if (!car || dots.length < 2) return;
    const max = car.scrollWidth - car.clientWidth;
    let idx = max > 0 ? Math.round(car.scrollLeft / max * (dots.length - 1)) : 0;
    idx = Math.max(0, Math.min(dots.length - 1, idx));
    dots.forEach((d, i) => d.classList.toggle('on', i === idx));
  }
  if (car) car.addEventListener('scroll', syncDots, { passive: true });
  syncDots();
</script>`);
}

function gonePage() {
  return pageShell('링크 만료', `
<main class="page simple">
  ${LOGO_SVG}
  <div class="big">⏰</div>
  <h1 class="title">링크가 만료됐어요</h1>
  <p class="sub">네컷 링크는 촬영 후 4시간 동안만 유효해요.<br>기기에서 새로 촬영해 주세요.</p>
</main>`);
}

function notFoundPage() {
  return pageShell('찾을 수 없음', `
<main class="page simple">
  ${LOGO_SVG}
  <div class="big">🎞️</div>
  <h1 class="title">여기엔 아무것도 없어요</h1>
  <p class="sub">주소를 다시 확인해 주세요.</p>
</main>`);
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
      const requiredKey = process.env.GC_UPLOAD_KEY;
      if (requiredKey && req.headers['x-gc-key'] !== requiredKey) {
        return sendJSON(res, 401, { ok: false, error: 'bad upload key' });
      }
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
      return sendHTML(res, 200, pageShell('growing pots', `
<main class="page simple">
  ${LOGO_SVG}
  <div class="big">🎓</div>
  <h1 class="title">growing pots 공유 서버</h1>
  <p class="sub">아이패드 앱에서 촬영하면 QR로 이 서버의<br>임시 링크(4시간)가 만들어져요.</p>
</main>`));
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
  console.log('🎓  growing pots 공유 서버 시작');
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
