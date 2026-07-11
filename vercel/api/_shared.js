// 공용 유틸 + 페이지 HTML (밑줄 파일은 라우트로 노출되지 않음)

export const ID_RE = /^[a-z0-9]{6,40}$/i;
export const TTL_MS = Number(process.env.TTL_HOURS || 4) * 60 * 60 * 1000;

export const KINDS = {
  photo: { file: 'photo.jpg', type: 'image/jpeg' },
  video: { file: 'video.mp4', type: 'video/mp4' },
};

export const SESSION_PREFIX = 's/';

export function sessionPrefix(id) {
  return `${SESSION_PREFIX}${id}/`;
}

/** 세션 blob 목록에서 생성 시각(가장 이른 업로드)과 만료 시각을 계산 */
export function sessionTimes(blobs) {
  const createdAt = Math.min(...blobs.map((b) => new Date(b.uploadedAt).getTime()));
  return { createdAt, expiresAt: createdAt + TTL_MS };
}

export function pageShell(title, inner) {
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

export function viewPage(expiresAt, photo, video) {
  return pageShell('그로잉컷 · 네컷 다운로드', `
<h1>네컷이 도착했어요 🎞️</h1>
<p class="sub">아래에서 사진과 움직이는 네컷 영상을<br>기기에 저장할 수 있어요.</p>
<div class="timer">링크 만료까지 <b id="remain">--:--:--</b></div>

${photo ? `
<div class="card">
  <h2>📷 네컷 사진</h2>
  <img src="${photo.url}" alt="네컷 사진">
  <a class="btn" href="${photo.downloadUrl}">사진 저장</a>
</div>` : ''}

${video ? `
<div class="card">
  <h2>🎬 움직이는 네컷</h2>
  <video src="${video.url}" playsinline muted autoplay loop controls></video>
  <a class="btn" href="${video.downloadUrl}">영상 저장</a>
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

export function gonePage() {
  return pageShell('링크 만료', `
<div class="big">⏰</div>
<h1>링크가 만료됐어요</h1>
<p class="sub">네컷 링크는 촬영 후 4시간 동안만 유효해요.<br>기기에서 새로 촬영해 주세요.</p>`);
}

export function notFoundPage() {
  return pageShell('찾을 수 없음', `
<div class="big">🎞️</div>
<h1>여기엔 아무것도 없어요</h1>
<p class="sub">주소를 다시 확인해 주세요.</p>`);
}

export function landingPage() {
  return pageShell('GROWING CUT', `
<div class="big">🎞️</div>
<h1>그로잉컷 공유 서버</h1>
<p class="sub">앱에서 촬영하면 QR로 이 서버의<br>임시 링크(4시간)가 만들어져요.</p>`);
}

export function sendHTML(res, code, html) {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(code).send(html);
}
