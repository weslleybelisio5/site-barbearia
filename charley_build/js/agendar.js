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
    if (mine !== loadSlots.n) return;
    st.slots = rows.map((r) => r.slot_start);
    box.innerHTML = st.slots.length
      ? `<p class="hint">${st.slots.length} horários livres em ${esc(fmtDateLong(st.slots[0]))}:</p><div class="slots">${st.slots.map((iso) => `<button type="button" class="slot" data-iso="${iso}" aria-pressed="false">${fmtTime(iso)}</button>`).join('')}</div>`
      : '<p class="notice">Não há horários livres neste dia. Tente outro dia.</p>';
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
function updateBookingProgress() {
  const active = !st.sel.size ? 'service' : !st.slot ? 'date' : 'details';
  const order = ['service','date','details'];
  document.querySelectorAll('[data-progress]').forEach((el) => {
    const index = order.indexOf(el.dataset.progress), current = order.indexOf(active);
    el.classList.toggle('is-active', index === current);
    el.classList.toggle('is-done', index < current);
  });
}

function renderSummary() {
  updateBookingProgress();
  const t = totals();
  const box = $('#summary');
  if (!box) return;
  if (!t.c.length) { box.hidden = true; $('#go').disabled = true; return; }
  box.hidden = false;
  const end = st.slot ? new Date(new Date(st.slot).getTime() + t.dur * 60000).toISOString() : null;
  box.innerHTML = `<dl>
    <dt>Serviços</dt><dd>${t.c.map((s) => esc(s.name)).join(' + ')}</dd>
    <dt>Duração total</dt><dd>${durText(t.dur)}</dd>
    <dt>${t.variable ? 'Total estimado' : 'Total'}</dt><dd class="price">${t.variable ? 'A partir de ' : ''}${brl(t.price)}</dd>
    ${st.slot ? `<dt>Horário</dt><dd>${esc(fmtDateLong(st.slot))}, ${fmtTime(st.slot)} às ${fmtTime(end)}</dd>` : ''}</dl>`;
  $('#go').disabled = !st.slot || st.busy;
}

// ---------- 3. confirmar ----------
async function submit(e) {
  e.preventDefault();
  const name = $('#name').value.trim(), wa = onlyDigits($('#wa').value);
  const err = $('#form-err'); err.textContent = '';
  
  if (name.length < 2) { err.textContent = 'Informe seu nome.'; return; }
  if (wa.length < 10) { err.textContent = 'Informe um WhatsApp válido.'; return; }
  if (!st.slot) { err.textContent = 'Escolha um horário.'; return; }

  st.busy = true; $('#go').disabled = true; $('#go').textContent = 'Reservando…';

  try {
    const t = totals();
    // Tenta criar o agendamento normal
    const r = await api.rpc('create_appointment', { 
        p_service_ids: t.c.map((s) => s.id), 
        p_start: st.slot, 
        p_name: name, 
        p_whatsapp: wa, 
        p_notes: $('#notes').value.trim() || null 
    });

    showDone(r, t, name);

  } catch (ex) {
    // SE DER ERRO (Horário ocupado), OFERECE A FILA DE ESPERA
    const msgErro = ex.message.toLowerCase();
    if (msgErro.includes('ocupado') || msgErro.includes('conflito') || msgErro.includes('indisponível')) {
        const aceitaFila = confirm("Ops! Alguém acabou de reservar esse horário. deseja entrar na LISTA DE ESPERA e avisar o Charley no WhatsApp?");
        if (aceitaFila) {
            await entrarNaFila(name, wa, chosen());
        }
    } else {
        err.textContent = ex.message;
        toast(ex.message, 'error');
    }
    loadSlots(); 
  } finally { 
      st.busy = false; 
      const go = $('#go'); 
      if (go) go.textContent = 'Confirmar agendamento'; 
      renderSummary(); 
  }
}

// FUNÇÃO PARA LISTA DE ESPERA + WHATSAPP
async function entrarNaFila(nome, telefone, servicos) {
    const nomesServicos = servicos.map(s => s.name).join(' + ');
    const user = api.session()?.user;

    const { error } = await api.from('fila_espera').insert([{
        cliente_id: user ? user.id : null,
        nome_cliente: nome,
        whatsapp_cliente: telefone,
        servico_nomes: nomesServicos
    }]);

    if (error) {
        toast("Erro ao entrar na fila.", "error");
    } else {
        const texto = `Olá Charley! Tentei agendar ${nomesServicos} pelo site, mas o horário acabou de ser ocupado. Entrei na LISTA DE ESPERA. Me avisa se vagar algo?`;
        window.open(waLink(settings.shop_whatsapp, texto), '_blank');
        $('#flow').innerHTML = `<div class="ok-box"><h2>Você está na fila!</h2><p>O Charley foi avisado no WhatsApp. Se o horário vagar, entraremos em contato.</p><a href="index.html" class="btn">Voltar ao início</a></div>`;
    }
}

function showDone(r, t, name) {
  const link = new URL('minha-reserva.html?t=' + r.guest_token, location.href).href;
  const text = `Olá! Acabei de agendar pelo site: ${t.c.map((s) => s.name).join(' + ')} em ${fmtDateLong(r.start_at)} às ${fmtTime(r.start_at)}. Meu nome é ${name}.`;
  
  $('#flow').innerHTML = `<div class="ok-box">
    <h2>Agendamento confirmado!</h2>
    <p>Seu horário está reservado.</p>
    <div class="notice"><b>Guarde este link para gerenciar sua reserva:</b><br><a href="${esc(link)}">${esc(link)}</a></div>
    <div class="row">
      <a class="btn" target="_blank" rel="noopener" href="${esc(waLink(settings.shop_whatsapp, text))}">Avisar Charley no WhatsApp</a>
      <a class="btn ghost" href="index.html">Voltar ao Início</a>
    </div></div>`;
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

if (api.session()) {
  const p = await currentProfile();
  if (p) { $('#name').value = p.full_name || ''; $('#wa').value = maskPhone(p.whatsapp || ''); }
}