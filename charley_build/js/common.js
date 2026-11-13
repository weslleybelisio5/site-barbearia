import { CONFIG } from './config.js';
import { api } from './api.js';

export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export const brl = (n) => Number(n).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const tz = CONFIG.TZ;
export const fmtTime = (iso) => new Date(iso).toLocaleTimeString('pt-BR', { timeZone: tz, hour: '2-digit', minute: '2-digit' });
export const fmtDate = (iso) => new Date(iso).toLocaleDateString('pt-BR', { timeZone: tz, day: '2-digit', month: '2-digit', year: 'numeric' });
export const fmtDateLong = (iso) => new Date(iso).toLocaleDateString('pt-BR', { timeZone: tz, weekday: 'long', day: 'numeric', month: 'long' });
export const todayRecife = () => new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date()); // AAAA-MM-DD
export const addDays = (ymd, n) => { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const durText = (min) => { const h = Math.floor(min / 60), m = min % 60; return (h ? h + 'h' : '') + (h && m ? ' ' : '') + (m ? m + ' min' : ''); };

export const onlyDigits = (s) => String(s || '').replace(/\D/g, '');
export const waNumber = (s) => { const d = onlyDigits(s); return d.length <= 11 ? '55' + d : d; };
export const waLink = (number, text) => 'https://wa.me/' + waNumber(number) + (text ? '?text=' + encodeURIComponent(text) : '');
export const maskPhone = (v) => {
  const d = onlyDigits(v).slice(0, 11);
  if (d.length <= 2) return d;
  if (d.length <= 6) return `(${d.slice(0, 2)}) ${d.slice(2)}`;
  if (d.length <= 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`;
  return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`;
};

// ---------- Configurações da barbearia (vêm do banco; têm valor padrão se o banco estiver fora) ----------
const DEFAULTS = {
  shop_name: 'Barbearia do Charley',
  shop_address: 'Rua Três de Agosto, Afogados, Recife - PE, CEP 50830-540',
  shop_whatsapp: '5581986324087',
  shop_instagram: 'https://www.instagram.com/barbeariadocharleyy/',
  lunch_start: '13:30', lunch_end: '15:00', cancel_limit_hours: '2',
};
let _settings;
export async function getSettings() {
  if (_settings) return _settings;
  _settings = { ...DEFAULTS };
  try {
    const rows = await api.select('settings', 'select=key,value');
    rows.forEach((r) => { _settings[r.key] = typeof r.value === 'string' ? r.value : JSON.stringify(r.value); });
  } catch { /* usa padrão */ }
  return _settings;
}
export async function getHours() {
  try { return await api.select('business_hours', 'select=*&order=weekday'); } catch { return []; }
}
const DIAS = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'];
export function hoursSummary(rows, s) {
  // agrupa dias com o mesmo horário: "Terça a quinta: 10:00 às 19:00"
  const order = [2, 3, 4, 5, 6, 0, 1];
  const by = Object.fromEntries(rows.map((r) => [r.weekday, r]));
  const t = (x) => String(x).slice(0, 5);
  const groups = [];
  order.forEach((d) => {
    const r = by[d]; if (!r) return;
    const label = r.is_open ? `${t(r.open_time)} às ${t(r.close_time)}` : 'Fechado';
    const last = groups[groups.length - 1];
    if (last && last.label === label) last.days.push(d); else groups.push({ label, days: [d] });
  });
  const lines = groups.map((g) => {
    const names = g.days.length > 1 ? `${DIAS[g.days[0]]} a ${DIAS[g.days[g.days.length - 1]].toLowerCase()}` : DIAS[g.days[0]];
    return { days: names, label: g.label };
  });
  return { lines, lunch: `Intervalo: ${s.lunch_start} às ${s.lunch_end}, nos dias de funcionamento` };
}

// ---------- Mensagens na tela ----------
export function toast(msg, kind = 'info') {
  let box = $('#toasts');
  if (!box) { box = document.createElement('div'); box.id = 'toasts'; box.setAttribute('role', 'status'); box.setAttribute('aria-live', 'polite'); document.body.appendChild(box); }
  const t = document.createElement('div');
  t.className = 'toast ' + kind; t.textContent = msg; box.appendChild(t);
  setTimeout(() => t.remove(), 5000);
}
export function confirmBox(message, okLabel = 'Confirmar') {
  return new Promise((resolve) => {
    const d = document.createElement('dialog'); d.className = 'dlg';
    d.innerHTML = `<form method="dialog"><p>${esc(message)}</p><div class="row end"><button class="btn ghost" value="no">Voltar</button><button class="btn" value="yes">${esc(okLabel)}</button></div></form>`;
    document.body.appendChild(d);
    d.addEventListener('close', () => { resolve(d.returnValue === 'yes'); d.remove(); });
    d.showModal();
  });
}

// ---------- Calendário (.ics) ----------
export function downloadIcs({ id, startIso, endIso, title, description, location }) {
  const z = (iso) => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const e = (t) => String(t || '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Barbearia do Charley//PT-BR', 'CALSCALE:GREGORIAN', 'BEGIN:VEVENT',
    `UID:${id}@barbearia-do-charley`, `DTSTAMP:${z(new Date().toISOString())}`, `DTSTART:${z(startIso)}`, `DTEND:${z(endIso)}`,
    `SUMMARY:${e(title)}`, `DESCRIPTION:${e(description)}`, `LOCATION:${e(location)}`, 'END:VEVENT', 'END:VCALENDAR'];
  const blob = new Blob([lines.join('\r\n')], { type: 'text/calendar;charset=utf-8' });
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'agendamento-barbearia-do-charley.ics';
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

// ---------- Cookies / consentimento ----------
export const getConsent = () => { try { return JSON.parse(localStorage.getItem('bdc_consent')); } catch { return null; } };
const setConsent = (analytics) => { try { localStorage.setItem('bdc_consent', JSON.stringify({ analytics, at: new Date().toISOString() })); } catch {} };

function cookieBanner() {
  if (getConsent()) return;
  openConsent(false);
}
export function openConsent(customize = true) {
  $('#cookie-box')?.remove();
  const b = document.createElement('div'); b.id = 'cookie-box'; b.setAttribute('role', 'dialog'); b.setAttribute('aria-label', 'Preferências de cookies');
  const cur = getConsent();
  b.innerHTML = `<div class="cookie-in">
    <p><strong>Cookies e privacidade.</strong> Usamos apenas o necessário para o site funcionar (como manter você conectado). Cookies de estatística só entram se você permitir. Veja a <a href="privacidade.html">Política de Privacidade</a>.</p>
    <div id="cookie-custom" ${customize ? '' : 'hidden'}>
      <label class="check"><input type="checkbox" checked disabled> Essenciais (sempre ativos)</label>
      <label class="check"><input type="checkbox" id="ck-an" ${cur && cur.analytics ? 'checked' : ''}> Estatísticas de uso</label>
    </div>
    <div class="row">
      <button class="btn" id="ck-yes">Aceitar todos</button>
      <button class="btn ghost" id="ck-no">Rejeitar não essenciais</button>
      <button class="btn ghost" id="ck-cu">${customize ? 'Salvar escolha' : 'Personalizar'}</button>
    </div></div>`;
  document.body.appendChild(b);
  $('#ck-yes').onclick = () => { setConsent(true); b.remove(); };
  $('#ck-no').onclick = () => { setConsent(false); b.remove(); };
  $('#ck-cu').onclick = () => {
    const c = $('#cookie-custom');
    if (c.hidden) { c.hidden = false; $('#ck-cu').textContent = 'Salvar escolha'; }
    else { setConsent($('#ck-an').checked); b.remove(); }
  };
}

// ---------- Cabeçalho, rodapé e botão do WhatsApp ----------
const NAV = [['index.html', 'Início'], ['servicos.html', 'Serviços'], ['produtos.html', 'Produtos'], ['agendar.html', 'Agendar'], ['contato.html', 'Contato'], ['faq.html', 'Dúvidas'], ['ajuda.html', 'Ajuda']];
const accountLabel = () => (api.session() ? 'Minha conta' : 'Entrar');

export async function mountChrome(active) {
  const s = await getSettings();
  const nav = NAV.map(([h, t]) => `<a href="${h}" ${h === active ? 'aria-current="page"' : ''}>${t}</a>`).join('') + `<a href="conta.html" id="acc-link" ${active === 'conta.html' ? 'aria-current="page"' : ''}>${accountLabel()}</a>`;
  $('#app-header').innerHTML = `<div class="wrap bar">
    <a class="brand" href="index.html" aria-label="${esc(s.shop_name)} - início"><img class="mark" src="img/emblema.png" width="44" height="44" alt="" aria-hidden="true"><span>Barbearia<br><b>do Charley</b></span></a>
    <button class="menu-btn" aria-label="Abrir menu" aria-expanded="false" id="menu-btn">☰</button>
    <nav id="main-nav" aria-label="Principal">${nav}<a class="btn small" href="agendar.html">Agendar horário</a></nav></div>`;
  $('#menu-btn').onclick = (e) => { const n = $('#main-nav'); const open = n.classList.toggle('open'); e.currentTarget.setAttribute('aria-expanded', open); };

  if (api.session()) { // mostra quantas notificações não lidas existem
    api.select('notifications', 'select=id&read_at=is.null').then((r) => {
      if (r.length) { const a = $('#acc-link'); if (a) a.innerHTML += ` <span class="badge warn" aria-label="${r.length} avisos novos">${r.length}</span>`; }
    }).catch(() => {});
  }
  const hours = hoursSummary(await getHours(), s);
  const hl = hours.lines.length ? hours.lines.map((l) => `<li>${esc(l.days)}: ${esc(l.label)}</li>`).join('') + `<li>${esc(hours.lunch)}</li>` : '';
  $('#app-footer').innerHTML = `<div class="footer-visual" aria-hidden="true"><span class="footer-orbit orbit-a"></span><span class="footer-orbit orbit-b"></span><span class="footer-core"></span></div>
    <div class="wrap footer-inner">
      <div class="footer-main">
        <div class="footer-brand-block"><a class="footer-brand" href="index.html"><img src="img/emblema.png" alt="" width="54" height="54"><span>BARBEARIA<br><b>DO CHARLEY</b></span></a>
          <p>Seu estilo. Seu momento.<br><span>Precisão no corte, cuidado em cada detalhe.</span></p>
          <div class="footer-social"><a href="${waLink(s.shop_whatsapp)}" target="_blank" rel="noopener" aria-label="WhatsApp">WA</a><a href="${esc(s.shop_instagram)}" target="_blank" rel="noopener" aria-label="Instagram">IG</a></div>
        </div>
        <div class="footer-column"><span class="footer-kicker">ENCONTRE A GENTE</span><h3>Visite a barbearia</h3><p>${esc(s.shop_address)}</p><a class="footer-link" href="https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(s.shop_address)}" target="_blank" rel="noopener">Como chegar <span>↗</span></a></div>
        <div class="footer-column"><span class="footer-kicker">PLANEJE SUA VISITA</span><h3>Horários</h3><ul class="plain">${hl}</ul><a class="footer-link" href="agendar.html">Escolher horário <span>→</span></a></div>
        <div class="footer-column"><span class="footer-kicker">TUDO EM UM LUGAR</span><h3>Links úteis</h3><ul class="plain"><li><a href="servicos.html">Serviços e preços</a></li><li><a href="faq.html">Dúvidas frequentes</a></li><li><a href="privacidade.html">Privacidade</a></li><li><a href="termos.html">Termos de uso</a></li><li><a href="#" id="open-ck">Preferências de cookies</a></li></ul></div>
      </div>
      <div class="footer-cta"><div><span class="footer-kicker">SEU PRÓXIMO CORTE COMEÇA AQUI</span><strong>Pronto para renovar o visual?</strong></div><a class="btn" href="agendar.html">Agendar horário <span aria-hidden="true">↗</span></a></div>
      <div class="footer-bottom"><span>© ${new Date().getFullYear()} ${esc(s.shop_name)}. Todos os direitos reservados.</span><span>Feito para valorizar seu estilo.</span></div>
    </div>`;
  $('#open-ck').onclick = (e) => { e.preventDefault(); openConsent(true); };
  const footer = $('#app-footer');
  if ('IntersectionObserver' in window) {
    const footerObserver = new IntersectionObserver((entries) => entries.forEach((entry) => {
      if (entry.isIntersecting) { footer.classList.add('is-visible'); footerObserver.disconnect(); }
    }), { threshold: 0.08 });
    footerObserver.observe(footer);
  } else footer.classList.add('is-visible');
  const footerVisual = $('.footer-visual', footer);
  if (footerVisual && window.matchMedia('(hover:hover) and (pointer:fine)').matches) {
    footer.addEventListener('pointermove', (event) => {
      const rect = footer.getBoundingClientRect();
      const x = (event.clientX - rect.left) / rect.width - .5;
      const y = (event.clientY - rect.top) / rect.height - .5;
      footerVisual.style.setProperty('--mx', (x * 16) + 'px');
      footerVisual.style.setProperty('--my', (y * 12) + 'px');
    });
    footer.addEventListener('pointerleave', () => { footerVisual.style.setProperty('--mx','0px'); footerVisual.style.setProperty('--my','0px'); });
  }

  const w = document.createElement('a');
  w.className = 'wa-float'; w.target = '_blank'; w.rel = 'noopener'; w.setAttribute('aria-label', 'Chamar no WhatsApp');
  w.href = waLink(s.shop_whatsapp, 'Olá! Vim pelo site da Barbearia do Charley.');
  w.innerHTML = '<svg viewBox="0 0 32 32" width="30" height="30" aria-hidden="true"><path fill="currentColor" d="M16 3C9 3 3.4 8.6 3.4 15.5c0 2.3.6 4.400 1.700 6.300L3 29l7.400-2c1.800 1 3.800 1.500 5.700 1.500 6.900 0 12.500-5.600 12.500-12.500S22.900 3 16 3zm6.300 17.700c-.3.800-1.600 1.500-2.200 1.600-.6.100-1.300.1-2.100-.1-.5-.2-1.100-.4-1.900-.7-3.300-1.400-5.400-4.700-5.600-4.900-.2-.2-1.300-1.700-1.300-3.200s.8-2.300 1.100-2.600c.3-.3.600-.4.800-.4h.6c.2 0 .5-.1.700.5l1 2.300c.1.200.1.400 0 .6l-.4.600-.5.600c-.2.200-.4.400-.2.800.2.400 1 1.600 2.100 2.600 1.400 1.200 2.600 1.600 3 1.800.4.200.6.100.8-.1l1.100-1.300c.2-.3.500-.2.800-.1l2.200 1.100c.3.100.5.200.6.300.1.200.1.800-.2 1.600z"/></svg>';
  document.body.appendChild(w);
  mountHelpAssistant();
  cookieBanner();
}

export function registerSW() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
}


// Assistente guiado leve: não executa alterações em reservas; encaminha para os fluxos reais.
function mountHelpAssistant() {
  if ($('#charley-help')) return;
  const root = document.createElement('div'); root.id = 'charley-help'; root.className = 'charley-help';
  root.innerHTML = `<button class="assistant-launch" type="button" aria-expanded="false" aria-controls="assistant-panel"><span class="assistant-spark">✦</span><span>Precisa de ajuda?</span></button><section class="assistant-panel" id="assistant-panel" hidden aria-label="Assistente da Barbearia do Charley"><header><div><b>Assistente Charley</b><small>Ajuda rápida com seu horário</small></div><button type="button" class="assistant-close" aria-label="Fechar assistente">×</button></header><div class="assistant-body"><p class="assistant-welcome">Olá! 👋 O que você gostaria de fazer?</p><div class="assistant-options"><a href="agendar.html"><span>✂</span><span><b>Quero agendar</b><small>Escolher serviço, dia e horário</small></span><i>›</i></a><a href="minha-reserva.html"><span>◷</span><span><b>Cancelar ou remarcar</b><small>Encontrar minha reserva</small></span><i>›</i></a><a href="ajuda.html"><span>ⓘ</span><span><b>Ver tutoriais</b><small>Aprender passo a passo</small></span><i>›</i></a><a href="https://wa.me/5581986324087?text=Ol%C3%A1!%20Preciso%20de%20ajuda%20com%20meu%20agendamento." target="_blank" rel="noopener"><span>☏</span><span><b>Falar com a barbearia</b><small>Atendimento pelo WhatsApp</small></span><i>↗</i></a></div><small class="assistant-note">Por segurança, alterações de reserva são confirmadas na página oficial do agendamento.</small></div></section>`;
  document.body.appendChild(root);
  const launch = $('.assistant-launch', root), panel = $('.assistant-panel', root);
  const close = () => { panel.hidden = true; launch.setAttribute('aria-expanded', 'false'); };
  launch.addEventListener('click', () => { panel.hidden = !panel.hidden; launch.setAttribute('aria-expanded', String(!panel.hidden)); });
  $('.assistant-close', root).addEventListener('click', close);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
}
