const http = require('http');

const BUILD_SHA = process.env.BUILD_SHA || 'dev';
const CLUSTER = process.env.CLUSTER || 'unknown';
const OVERLAY = process.env.OVERLAY || 'base';
const PORT = parseInt(process.env.PORT || '8080', 10);

function page() {
  const accentCloud = '#58a6ff';
  const accentOnprem = '#3fb950';
  const accent = OVERLAY === 'onprem' ? accentOnprem : accentCloud;
  const tagBg = OVERLAY === 'onprem' ? '#1a3a1a' : '#0d419d';
  const tagBorder = OVERLAY === 'onprem' ? '#238636' : '#1f6feb';
  const tagLabel = OVERLAY === 'onprem' ? 'GitOps &bull; On-Prem' : 'GitOps &bull; Live Demo';
  const overlayDetail = OVERLAY === 'onprem' ? 'onprem overlay' : 'cloud overlay';
  const networkRow = OVERLAY === 'onprem'
    ? `<div class="meta"><div class="meta-label">Network</div><div class="meta-value" style="color:${accent}">Tailscale</div></div>`
    : `<div class="meta"><div class="meta-label">Replicas</div><div class="meta-value" style="color:${accent}">2</div></div>`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Palladium Platform Demo</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d1117; color: #c9d1d9;
      min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 2rem;
    }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 12px; padding: 2.5rem; max-width: 680px; width: 100%; }
    .tag { display: inline-block; background: ${tagBg}; color: ${accent}; font-size: 0.7rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; padding: 3px 10px; border-radius: 20px; border: 1px solid ${tagBorder}; margin-bottom: 1.25rem; }
    h1 { font-size: 2rem; font-weight: 700; color: #e6edf3; }
    .sub { color: #8b949e; font-size: 0.95rem; margin-top: 0.4rem; margin-bottom: 2rem; }
    .cluster-block { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 1.25rem 1.5rem; margin-bottom: 2rem; display: flex; gap: 2rem; flex-wrap: wrap; }
    .meta { flex: 1; min-width: 120px; }
    .meta-label { font-size: 0.7rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em; }
    .meta-value { font-size: 1rem; font-weight: 600; margin-top: 0.2rem; }
    .sha { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.85rem; color: #e6edf3; background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 2px 6px; }
    .section-label { font-size: 0.75rem; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 1rem; }
    .pipeline { display: flex; align-items: center; gap: 0.4rem; margin-bottom: 2rem; flex-wrap: wrap; }
    .step { background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.9rem 1rem; min-width: 110px; text-align: center; flex: 1; }
    .step-icon { font-size: 1.2rem; }
    .step-name { font-size: 0.8rem; font-weight: 600; color: #e6edf3; margin-top: 0.3rem; }
    .step-detail { font-size: 0.7rem; color: #8b949e; margin-top: 0.15rem; }
    .arrow { color: #3fb950; font-size: 1rem; flex-shrink: 0; }
    .stats { display: flex; gap: 1rem; flex-wrap: wrap; }
    .stat { background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.75rem 1rem; flex: 1; min-width: 110px; }
    .stat-label { font-size: 0.65rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em; }
    .stat-value { font-size: 0.9rem; font-weight: 600; color: #3fb950; margin-top: 0.2rem; }
    .tools { margin-top: 2rem; }
    .tools-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 0.75rem; margin-bottom: 1.25rem; }
    .tool-link { display: block; background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 1rem; text-decoration: none; transition: border-color 0.15s, background 0.15s; }
    .tool-link:hover { border-color: ${accent}; background: #1c2128; }
    .tool-name { font-size: 0.9rem; font-weight: 600; color: #e6edf3; }
    .tool-desc { font-size: 0.7rem; color: #8b949e; margin-top: 0.25rem; }
    .creds { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 1rem 1.25rem; display: flex; gap: 2rem; align-items: center; flex-wrap: wrap; }
    .creds-label { font-size: 0.7rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em; }
    .creds-value { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.85rem; color: ${accent}; margin-top: 0.15rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="tag">${tagLabel}</div>
    <h1>Palladium Platform</h1>
    <p class="sub">Hybrid cloud &mdash; deployed via ArgoCD from a git push</p>
    <div class="cluster-block">
      <div class="meta">
        <div class="meta-label">Cluster</div>
        <div class="meta-value" style="color:${accent}">${CLUSTER}</div>
      </div>
      <div class="meta">
        <div class="meta-label">Overlay</div>
        <div class="meta-value" style="color:${accent}">${OVERLAY}</div>
      </div>
      ${networkRow}
      <div class="meta">
        <div class="meta-label">Commit</div>
        <div class="meta-value"><span class="sha">${BUILD_SHA.slice(0, 7)}</span></div>
      </div>
    </div>
    <div class="section-label">Deployment pipeline</div>
    <div class="pipeline">
      <div class="step"><div class="step-icon">&#128196;</div><div class="step-name">Git push</div><div class="step-detail">platform-demo</div></div>
      <div class="arrow">&#8594;</div>
      <div class="step"><div class="step-icon">&#128260;</div><div class="step-name">CI build</div><div class="step-detail">Docker + ECR</div></div>
      <div class="arrow">&#8594;</div>
      <div class="step"><div class="step-icon">&#9881;&#65039;</div><div class="step-name">ArgoCD</div><div class="step-detail">${overlayDetail}</div></div>
      <div class="arrow">&#8594;</div>
      <div class="step"><div class="step-icon">&#9989;</div><div class="step-name">Deployed</div><div class="step-detail">self-heal on</div></div>
    </div>
    <div class="stats">
      <div class="stat"><div class="stat-label">Sync policy</div><div class="stat-value">Automated</div></div>
      <div class="stat"><div class="stat-label">Self-heal</div><div class="stat-value">Enabled</div></div>
      <div class="stat"><div class="stat-label">Metrics</div><div class="stat-value">Prometheus</div></div>
      <div class="stat"><div class="stat-label">Logs</div><div class="stat-value">Loki</div></div>
    </div>
    <div class="tools">
      <div class="section-label">Platform tools</div>
      <div class="tools-grid">
        <a class="tool-link" href="https://grafana-demo.gideonwarui.com" target="_blank">
          <div class="tool-name">Grafana</div>
          <div class="tool-desc">Dashboards &amp; visualization</div>
        </a>
        <a class="tool-link" href="https://argocd-demo.gideonwarui.com" target="_blank">
          <div class="tool-name">ArgoCD</div>
          <div class="tool-desc">GitOps deployments</div>
        </a>
        <a class="tool-link" href="https://prometheus-demo.gideonwarui.com" target="_blank">
          <div class="tool-name">Prometheus</div>
          <div class="tool-desc">Metrics &amp; Thanos Query</div>
        </a>
        <a class="tool-link" href="https://alertmanager-demo.gideonwarui.com" target="_blank">
          <div class="tool-name">Alertmanager</div>
          <div class="tool-desc">Alert routing &amp; silencing</div>
        </a>
      </div>
      <div class="creds">
        <div><div class="creds-label">Username</div><div class="creds-value">demo</div></div>
        <div><div class="creds-label">Password</div><div class="creds-value">palladium</div></div>
        <div><div class="creds-label">Applies to</div><div class="creds-value">Grafana &amp; ArgoCD</div></div>
      </div>
    </div>
  </div>
</body>
</html>`;
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(page());
});

server.listen(PORT, () => {
  console.log(`listening on :${PORT} sha=${BUILD_SHA} cluster=${CLUSTER} overlay=${OVERLAY}`);
});

module.exports = { page };
