// Shared by every page: the Supabase connection, the login check,
// the navigation menu and a few small formatting helpers.

const WBC = (() => {
  const cfg = window.WBC_CONFIG || {};
  const configured =
    typeof cfg.url === 'string' && cfg.url.startsWith('https://') &&
    typeof cfg.key === 'string' && cfg.key.length > 20 && !cfg.key.startsWith('PASTE_');

  // The one connection to the database that all pages use.
  const sb = configured ? window.supabase.createClient(cfg.url, cfg.key) : null;

  // Every screen in the plan. "built: false" pages show greyed out until their build step.
  const NAV = [
    { group: 'Sell', links: [
      { href: 'dashboard.html', label: 'Dashboard', built: true },
      { href: 'pos.html', label: 'Point of Sale', built: true },
      { href: 'sales-orders.html', label: 'Sales Orders' },
      { href: 'returns.html', label: 'Returns & Exchanges' },
    ]},
    { group: 'Stock', links: [
      { href: 'inventory.html', label: 'Inventory', built: true },
      { href: 'items.html', label: 'Items & BOMs', built: true },
    ]},
    { group: 'Buy', links: [
      { href: 'purchasing.html', label: 'Purchasing', built: true },
      { href: 'review.html', label: 'Due for Review' },
      { href: 'suppliers.html', label: 'Suppliers', built: true },
    ]},
    { group: 'Make', links: [
      { href: 'production.html', label: 'Production' },
      { href: 'mrp.html', label: 'MRP' },
    ]},
    { group: 'Analyze', links: [
      { href: 'financials.html', label: 'Financials' },
      { href: 'reports.html', label: 'Reports' },
    ]},
    { group: 'System', links: [
      { href: 'settings.html', label: 'Settings' },
      { href: 'about.html', label: 'About this system', built: true },
    ]},
  ];

  // --- helpers -----------------------------------------------------------

  // Make text safe to place inside HTML.
  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, (ch) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]
    ));
  }

  function money(value) {
    if (value === null || value === undefined || value === '') return '—';
    return Number(value).toLocaleString('en-US', { style: 'currency', currency: 'USD' });
  }

  function percent(fraction, digits = 1) {
    if (fraction === null || fraction === undefined || !isFinite(fraction)) return '—';
    return (fraction * 100).toFixed(digits) + '%';
  }

  let toastTimer;
  function toast(message, isError = false) {
    let el = document.getElementById('toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'toast';
      el.setAttribute('role', 'status');
    }
    // An open pop-up sits above the page, so show the message inside it.
    (document.querySelector('dialog[open]') || document.body).appendChild(el);
    el.textContent = message;
    el.className = isError ? 'show error' : 'show';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.className = ''; }, isError ? 6000 : 2500);
  }

  // --- barcode scanning ----------------------------------------------------
  // A USB barcode scanner behaves like a keyboard: it types the code into
  // whichever box has the cursor, then presses Enter. So a "scan box" is a
  // text input that calls onCode(code) on Enter. Typing a code by hand and
  // pressing Enter works the same way.
  function scanBox(input, onCode) {
    input.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      event.preventDefault();
      const code = input.value.trim();
      input.value = '';
      if (code) onCode(code);
    });
  }

  // Find the item a scanned code belongs to (barcode first, then SKU).
  function findByCode(items, code) {
    const wanted = code.trim().toLowerCase();
    return items.find((i) => (i.barcode || '').toLowerCase() === wanted)
        || items.find((i) => (i.sku || '').toLowerCase() === wanted)
        || null;
  }

  // --- phone / laptop camera scanning (the backup to a USB scanner) --------
  // Opens a pop-up showing the camera. Each barcode it reads is passed to
  // onCode(code), exactly as if a USB scanner had typed it. The scanning
  // library (html5-qrcode) is only downloaded the first time this is used.
  // Cameras only work on https pages (the live site) or localhost.
  let cameraLibrary = null;
  function loadCameraLibrary() {
    if (!cameraLibrary) {
      cameraLibrary = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = 'https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js';
        script.onload = resolve;
        script.onerror = () => { cameraLibrary = null; reject(new Error('Could not download the camera scanner.')); };
        document.head.appendChild(script);
      });
    }
    return cameraLibrary;
  }

  async function cameraScan(onCode) {
    let dialog = document.getElementById('camera-dialog');
    if (!dialog) {
      dialog = document.createElement('dialog');
      dialog.id = 'camera-dialog';
      dialog.innerHTML = `
        <h2>Scan with camera</h2>
        <div id="camera-view"></div>
        <p class="muted" id="camera-status" role="status"></p>
        <div class="form-actions"><button type="button" class="btn primary" id="camera-done">Done</button></div>`;
      document.body.appendChild(dialog);
      dialog.querySelector('#camera-done').addEventListener('click', () => dialog.close());
    }
    const status = dialog.querySelector('#camera-status');
    status.textContent = 'Starting camera…';
    dialog.showModal();

    let reader = null;
    dialog.addEventListener('close', async () => {
      try { if (reader && reader.isScanning) await reader.stop(); } catch (e) { /* already stopped */ }
      try { if (reader) reader.clear(); } catch (e) { /* nothing to clear */ }
    }, { once: true });

    try {
      await loadCameraLibrary();
      reader = new window.Html5Qrcode('camera-view');
      let lastCode = '', lastTime = 0;
      await reader.start(
        { facingMode: 'environment' },                     // the back camera on a phone
        { fps: 10, qrbox: { width: 260, height: 130 } },
        (code) => {
          // The camera sees the same barcode many times a second: count it once.
          const now = Date.now();
          if (code === lastCode && now - lastTime < 2000) return;
          lastCode = code; lastTime = now;
          status.textContent = 'Scanned ' + code;
          onCode(code);
        },
        () => { /* no barcode in this frame: keep looking */ });
      status.textContent = 'Point the camera at a barcode.';
    } catch (error) {
      status.textContent = 'Camera not available: ' + (error && error.message ? error.message : error) +
        '. Allow camera access, or type the SKU into the scan box instead.';
    }
  }

  function soNumber(id) {
    return 'SO-' + String(id).padStart(5, '0');
  }

  function qty(value) {
    if (value === null || value === undefined) return '0';
    return Number(value).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  function dateTime(value) {
    return new Date(value).toLocaleString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit',
    });
  }

  // Today's date as YYYY-MM-DD in the computer's own time zone (for date boxes).
  function today() {
    const now = new Date();
    return new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  }

  // Show a stored date (YYYY-MM-DD) as "Nov 16, 2026".
  function date(value) {
    if (!value) return '—';
    return new Date(value + 'T00:00:00').toLocaleDateString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
    });
  }

  function poNumber(id) {
    return 'PO-' + String(id).padStart(5, '0');
  }

  function showSetupNotice() {
    document.body.innerHTML = `
      <main class="center-card">
        <h1>Almost there</h1>
        <p>The app is not connected to Supabase yet.</p>
        <p>Open <code>js/config.js</code> and paste in your Project URL and publishable key, then reload this page.</p>
      </main>`;
  }

  // --- login check + page frame -----------------------------------------

  // Call at the top of every staff page. Sends people who are not logged in
  // to the login page, draws the menu, and returns who is logged in.
  async function initPage(pageTitle) {
    if (!configured) { showSetupNotice(); return null; }

    const { data: { session } } = await sb.auth.getSession();
    if (!session) { window.location.replace('index.html'); return null; }

    const { data: profile, error } = await sb
      .from('profiles').select('*').eq('id', session.user.id).maybeSingle();

    if (error || !profile || profile.role !== 'staff') {
      document.body.innerHTML = `
        <main class="center-card">
          <h1>Staff access needed</h1>
          <p>You are signed in as <strong>${esc(session.user.email)}</strong>, but this login is not marked as staff.</p>
          <p>${error ? esc(error.message) : 'Run <code>sql/03_make_me_staff.sql</code> in Supabase for this email, then reload.'}</p>
          <button id="signout-btn" class="btn">Sign out</button>
        </main>`;
      document.getElementById('signout-btn').onclick = signOut;
      return null;
    }

    drawFrame(pageTitle, profile);
    return { user: session.user, profile };
  }

  function drawFrame(pageTitle, profile) {
    const current = window.location.pathname.split('/').pop() || 'index.html';
    const content = document.getElementById('content');

    const groups = NAV.map((g) => `
      <div class="nav-group">${esc(g.group)}</div>
      ${g.links.map((l) => l.built
        ? `<a href="${l.href}" class="${l.href === current ? 'active' : ''}">${esc(l.label)}</a>`
        : `<span class="soon" title="Not built yet">${esc(l.label)}</span>`
      ).join('')}`).join('');

    const shell = document.createElement('div');
    shell.className = 'shell';
    shell.innerHTML = `
      <nav class="sidebar">
        <div class="brand">Wasatch Board Co.<small>ERP</small></div>
        ${groups}
      </nav>
      <div class="main">
        <header class="topbar">
          <h1>${esc(pageTitle)}</h1>
          <div class="user">
            <span>${esc(profile.full_name || profile.email)}</span>
            <button id="signout-btn" class="btn small">Sign out</button>
          </div>
        </header>
        <div id="content-slot"></div>
      </div>`;
    document.body.prepend(shell);
    shell.querySelector('#content-slot').replaceWith(content);
    content.hidden = false;
    document.title = pageTitle + ' · Wasatch Board Co. ERP';
    document.getElementById('signout-btn').onclick = signOut;
  }

  async function signOut() {
    await sb.auth.signOut();
    window.location.replace('index.html');
  }

  return {
    sb, configured, esc, money, percent, qty, dateTime, today, date, poNumber, toast,
    scanBox, findByCode, cameraScan, soNumber, initPage, signOut, showSetupNotice,
  };
})();
