import { $, $$, esc, brl, fmtTime, fmtDateLong, todayRecife, addDays, durText, maskPhone, onlyDigits, waLink,
         mountChrome, registerSW, getSettings, toast, downloadIcs } from './common.js';
import { api, currentProfile } from './api.js';
import { loadServices, priceLabel } from './services.js';

registerSW();
await mountChrome('agendar.html');
const settings = await getSettings();

const st = { services: [], sel: new Set(), date: '', slots: [], slot: null, busy: false };

// ---------- 1. serviços ----------
function chosen() {
  // mesma ordem usada no banco: serviços que já incluem corte primeiro, depois a ordem do catálogo
  return st.services.filter((s) => st.sel.has(s.id)).sort((a, b) => (b.includes_cut - a.includes_cut) || (a.sort_order - b.sort_order));
}
function totals() {
  const c = chosen();
  return { c, dur: c.reduce((n, s) => n + s.duration_min, 0), price: c.reduce((n, s) => n + Number(s.price), 0), variable: c.some((s) => s.is_variable_price) };
}
function renderServices() {
  const hasInc = st.services.some((s) => st.sel.has(s.id) && s.includes_cut);
  const hasCut = st.services.some((s) => st.sel.has(s.id) && s.is_cut);
  $('#svc-pick').innerHTML = st.services.map((s) => {
    const blocked = (hasInc && s.is_cut) || (hasCut && s.includes_cut);
    const on = st.sel.has(s.id);
    return `<label class="card svc pick ${on ? 'on' : ''} ${blocked ? 'off' : ''}" for="s-${s.id}">
      <input type="checkbox" id="s-${s.id}" data-id="${s.id}" ${on ? 'checked' : ''} ${blocked ? 'disabled' : ''}>
      <div style="flex:1"><h3>${esc(s.name)}</h3><p>${durText(s.duration_min)}${s.includes_cut ? ' · já inclui o corte' : ''}${blocked ? ' · não combina com a seleção atual' : ''}</p></div>
      <div class="price">${priceLabel(s)}</div></label>`;
  }).join('');
  $$('#svc-pick input').forEach((i) => i.addEventListener('change', () => {
    i.checked ? st.sel.add(i.dataset.id) : st.sel.delete(i.dataset.id);
    st.slot = null; renderServices(); renderSummary(); loadSlots();
  }));
}

// ---------- 2. horários ----------
async function loadSlots() {
  const { dur } = totals();
  const box = $('#slots');
  st.slots = []; st.slot = null;
  if (!st.sel.size) { box.innerHTML = '<p class="hint">Escolha pelo menos um serviço para ver os horários.</p>'; renderSummary(); return; }
  if (!st.date) { box.innerHTML = '<p class="hint">Escolha o dia.</p>'; renderSummary(); return; }
  box.innerHTML = '<p class="loading"><span class="spin"></span>Buscando horários livres…</p>';
  const mine = ++loadSlots.n;
  try {
    const rows = await api.rpc('get_available_slots', { p_date: st.date, p_duration: dur });
    if (mine !== loadSlots.n) return; // resposta antiga, ignora
    st.slots = rows.map((r) => r.slot_start);
    box.innerHTML = st.slots.length
      ? `<p class="hint">${st.slots.length} horários livres em ${esc(fmtDateLong(st.slots[0]))}:</p><div class="slots">${st.slots.map((iso) => `<button type="button" class="slot" data-iso="${iso}" aria-pressed="false">${fmtTime(iso)}</button>`).join('')}</div>`
      : '<p class="notice">Não há horários livres neste dia para a duração escolhida (a barbearia pode estar fechada ou lotada). Tente outro dia.</p>';
    $$('#slots .slot').forEach((b) => b.addEventListener('click', () => {
      st.slot = b.dataset.iso;
      $$('#slots .slot').forEach((x) => x.setAttribute('aria-pressed', x === b));
      renderSummary();
      $('#step3').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }));
  } catch (e) { if (mine === loadSlots.n) box.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
  renderSummary();
}
loadSlots.n = 0;

// ---------- resumo ----------
function renderSummary() {
  const t = totals();
  const box = $('#summary');
  if (!box) return; // a tela de confirmação já substituiu o formulário
  if (!t.c.length) { box.hidden = true; $('#go').disabled = true; return; }
  box.hidden = false;
  const end = st.slot ? new Date(new Date(st.slot).getTime() + t.dur * 60000).toISOString() : null;
  box.innerHTML = `<dl>
    <dt>Serviços</dt><dd>${t.c.map((s) => esc(s.name)).join(' + ')}</dd>
    <dt>Duração total</dt><dd>${durText(t.dur)}</dd>
    <dt>${t.variable ? 'Total estimado' : 'Total'}</dt><dd class="price">${t.variable ? 'A partir de ' : ''}${brl(t.price)}</dd>
    ${st.slot ? `<dt>Horário</dt><dd>${esc(fmtDateLong(st.slot))}, ${fmtTime(st.slot)} às ${fmtTime(end)}</dd>` : ''}</dl>
    ${t.variable ? '<p class="hint">Serviços químicos têm preço estimado: o Charley avalia pessoalmente e informa o valor final antes de começar.</p>' : ''}`;
  $('#go').disabled = !st.slot || st.busy;
}

// ---------- 3. confirmar ----------
async function submit(e) {
  e.preventDefault();
  const name = $('#name').value.trim(), wa = onlyDigits($('#wa').value);
  const err = $('#form-err'); err.textContent = '';
  if (name.length < 2) { err.textContent = 'Informe seu nome.'; return; }
  if (wa.length < 10 || wa.length > 11) { err.textContent = 'Informe um WhatsApp válido com DDD. Exemplo: (81) 99999-9999.'; return; }
  if (!st.slot) { err.textContent = 'Escolha um horário.'; return; }
  st.busy = true; $('#go').disabled = true; $('#go').textContent = 'Reservando…';
  try {
    const t = totals();
    const r = await api.rpc('create_appointment', { p_service_ids: t.c.map((s) => s.id), p_start: st.slot, p_name: name, p_whatsapp: wa, p_notes: $('#notes').value.trim() || null });
    try {
      const list = JSON.parse(localStorage.getItem('bdc_bookings') || '[]');
      list.unshift({ token: r.guest_token, id: r.id, start_at: r.start_at }); localStorage.setItem('bdc_bookings', JSON.stringify(list.slice(0, 20)));
    } catch {}
    showDone(r, t, name);
  } catch (ex) {
    err.textContent = ex.message; toast(ex.message, 'error');
    loadSlots(); // o horário pode ter sido ocupado: atualiza a lista
  } finally { st.busy = false; const go = $('#go'); if (go) go.textContent = 'Confirmar agendamento'; renderSummary(); }
}

function showDone(r, t, name) {
  const link = new URL('minha-reserva.html?t=' + r.guest_token, location.href).href;
  const pending = r.status === 'pending';
  const text = `Olá! Acabei de agendar pelo site: ${t.c.map((s) => s.name).join(' + ')} em ${fmtDateLong(r.start_at)} às ${fmtTime(r.start_at)}. Meu nome é ${name}.`;
  $('#flow').innerHTML = `<div class="ok-box">
    <h2>${pending ? 'Pedido recebido!' : 'Agendamento confirmado!'}</h2>
    <p>${pending ? 'O Charley vai confirmar o seu horário em breve.' : 'Seu horário está reservado.'}</p>
    <dl class="summary-dl"><p><b>Quando:</b> ${esc(fmtDateLong(r.start_at))}, ${fmtTime(r.start_at)} às ${fmtTime(r.end_at)}</p>
    <p><b>Serviços:</b> ${t.c.map((s) => esc(s.name)).join(' + ')}</p>
    <p><b>${t.variable ? 'Total estimado' : 'Total'}:</b> ${t.variable ? 'A partir de ' : ''}${brl(t.price)}</p>
    <p><b>Local:</b> ${esc(settings.shop_address)}</p></dl>
    <div class="notice"><b>Guarde este link.</b> Com ele você consulta, remarca ou cancela sem precisar de conta:<br><a href="${esc(link)}">${esc(link)}</a></div>
    <div class="row"><button class="btn" id="ics">Adicionar ao calendário</button>
      <a class="btn ghost" href="${esc(link)}">Ver meu agendamento</a>
      <a class="btn ghost" target="_blank" rel="noopener" href="${esc(waLink(settings.shop_whatsapp, text))}">Avisar no WhatsApp</a></div>
    <p class="hint">Você pode cancelar sozinho até ${esc(settings.cancel_limit_hours)} horas antes. Remarcar é possível a qualquer momento, se houver outro horário livre.</p></div>`;
  $('#ics').onclick = () => downloadIcs({ id: r.id, startIso: r.start_at, endIso: r.end_at, title: 'Barbearia do Charley - ' + t.c.map((s) => s.name).join(' + '),
    description: `Serviços: ${t.c.map((s) => s.name).join(', ')}\nTotal ${t.variable ? 'estimado' : ''}: ${brl(t.price)}`, location: settings.shop_address });
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// ---------- início ----------
try {
  st.services = await loadServices();
  renderServices();
} catch (e) { $('#svc-pick').innerHTML = `<p class="err">${esc(e.message)}</p>`; }

const win = Number(settings.booking_window_days || 60);
const dateEl = $('#date');
dateEl.min = todayRecife(); dateEl.max = addDays(todayRecife(), win);
dateEl.addEventListener('change', () => { st.date = dateEl.value; loadSlots(); });
$('#wa').addEventListener('input', (e) => { e.target.value = maskPhone(e.target.value); });
$('#form').addEventListener('submit', submit);
renderSummary();

// se a pessoa estiver conectada, preenche nome e WhatsApp
if (api.session()) {
  const p = await currentProfile();
  if (p) { $('#name').value = p.full_name || ''; $('#wa').value = maskPhone(p.whatsapp || ''); }
}
// vindo da página de serviços com um serviço marcado (?s=id)
