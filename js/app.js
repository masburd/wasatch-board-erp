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
      { href: 'pos.html', label: 'Point of Sale' },
      { href: 'sales-orders.html', label: 'Sales Orders' },
      { href: 'returns.html', label: 'Returns & Exchanges' },
    ]},
    { group: 'Stock', links: [
      { href: 'inventory.html', label: 'Inventory', built: true },
      { href: 'items.html', label: 'Items & BOMs', built: true },
    ]},
    { group: 'Buy', links: [
      { href: 'purchasing.html', label: 'Purchasing' },
      { href: 'review.html', label: 'Due for Review' },
      { href: 'suppliers.html', label: 'Suppliers' },
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
      document.body.appendChild(el);
    }
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

  function qty(value) {
    if (value === null || value === undefined) return '0';
    return Number(value).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  function dateTime(value) {
    return new Date(value).toLocaleString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit',
    });
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
    sb, configured, esc, money, percent, qty, dateTime, toast,
    scanBox, findByCode, initPage, signOut, showSetupNotice,
  };
})();
