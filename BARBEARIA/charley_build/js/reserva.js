import { $, $$, esc, brl, fmtTime, fmtDate, fmtDateLong, todayRecife, addDays, durText, waLink,
         mountChrome, registerSW, getSettings, toast, confirmBox, downloadIcs } from './common.js';
import { api } from './api.js';

registerSW();
await mountChrome('');
const settings = await getSettings();
const token = new URLSearchParams(location.search).get('t');
const root = $('#res');

const STATUS = { pending: ['Aguardando confirmação', 'warn'], confirmed: ['Confirmado', 'ok'], completed: ['Concluído', 'ok'], cancelled: ['Cancelado', 'bad'], no_show: ['Não compareceu', 'bad'] };

async function show() {
  if (!token) { return listLocal(); }
  root.innerHTML = '<p class="loading"><span class="spin"></span>Carregando…</p>';
  let a;
  try { a = await api.rpc('get_guest_appointment', { p_token: token }); } catch (e) { root.innerHTML = `<p class="err">${esc(e.message)}</p>`; return; }
  if (!a) { root.innerHTML = '<div class="notice">Não encontramos este agendamento. Confira se o link está completo.</div>'; return; }
  const [label, kind] = STATUS[a.status] || [a.status, ''];
  const active = a.status === 'pending' || a.status === 'confirmed';
  const variable = a.items.some((i) => i.is_variable_price);
  const dur = Math.round((new Date(a.end_at) - new Date(a.start_at)) / 60000);
  root.innerHTML = `<div class="card">
    <p><span class="badge ${kind}">${esc(label)}</span></p>
    <h2>${esc(fmtDateLong(a.start_at))}</h2>
    <p><b>${fmtTime(a.start_at)} às ${fmtTime(a.end_at)}</b> (${durText(dur)})</p>
    <ul class="plain">${a.items.map((i) => `<li>${esc(i.name)} · ${durText(i.duration_min)} · ${i.is_variable_price ? 'a partir de ' : ''}${brl(i.price_estimated)}</li>`).join('')}</ul>
    <p class="price">${variable ? 'Total estimado: a partir de ' : 'Total: '}${brl(a.estimated_total)}</p>
    <p class="muted">${esc(settings.shop_address)}</p>
    ${active ? `<div class="row"><button class="btn" id="ics">Adicionar ao calendário</button><button class="btn ghost" id="resch">Remarcar</button><button class="btn ghost" id="cancel">Cancelar</button></div>` : ''}
    <div id="resch-box" hidden></div><p class="err" id="act-err"></p></div>`;
  if (api.session()) { // visitante já tem conta: pode ligar este agendamento a ela
    const b = document.createElement('button'); b.className = 'btn small ghost'; b.style.marginTop = '12px'; b.textContent = 'Vincular à minha conta';
    b.onclick = async () => { try { await api.rpc('claim_appointment', { p_token: token }); toast('Agendamento vinculado à sua conta.', 'success'); b.remove(); } catch (e) { toast(e.message, 'error'); } };
    $('#res .card').appendChild(b);
  }
  if (!active) return;
  $('#ics').onclick = () => downloadIcs({ id: a.id, startIso: a.start_at, endIso: a.end_at, title: 'Barbearia do Charley - ' + a.items.map((i) => i.name).join(' + '),
    description: 'Serviços: ' + a.items.map((i) => i.name).join(', '), location: settings.shop_address });

  $('#cancel').onclick = async () => {
    if (!(await confirmBox('Deseja realmente cancelar este agendamento?', 'Sim, cancelar'))) return;
    try { await api.rpc('cancel_appointment', { p_id: a.id, p_token: token }); toast('Agendamento cancelado.', 'success'); show(); }
    catch (e) {
      const wa = waLink(settings.shop_whatsapp, `Olá! Preciso cancelar meu agendamento de ${fmtDate(a.start_at)} às ${fmtTime(a.start_at)}.`);
      $('#act-err').innerHTML = `${esc(e.message)} <a href="${esc(wa)}" target="_blank" rel="noopener">Falar com a barbearia</a>`;
    }
  };

  $('#resch').onclick = () => {
    const box = $('#resch-box'); box.hidden = false;
    box.innerHTML = `<h3>Escolha o novo dia e horário</h3><label for="nd">Dia</label><input type="date" id="nd" min="${todayRecife()}" max="${addDays(todayRecife(), Number(settings.booking_window_days || 60))}"><div id="ns"></div>`;
    $('#nd').onchange = async () => {
      const ns = $('#ns'); ns.innerHTML = '<p class="loading"><span class="spin"></span>Buscando…</p>';
      try {
        const rows = await api.rpc('get_available_slots', { p_date: $('#nd').value, p_duration: dur, p_exclude: a.id });
        ns.innerHTML = rows.length ? `<div class="slots">${rows.map((r) => `<button type="button" class="slot" data-iso="${r.slot_start}">${fmtTime(r.slot_start)}</button>`).join('')}</div>` : '<p class="notice">Sem horários livres neste dia.</p>';
        $$('#ns .slot').forEach((b) => b.onclick = async () => {
          if (!(await confirmBox(`Remarcar para ${fmtDateLong(b.dataset.iso)} às ${fmtTime(b.dataset.iso)}?`, 'Remarcar'))) return;
          try { await api.rpc('reschedule_appointment', { p_id: a.id, p_new_start: b.dataset.iso, p_token: token }); toast('Agendamento remarcado.', 'success'); show(); }
          catch (e) { $('#act-err').textContent = e.message; }
        });
      } catch (e) { ns.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
    };
  };
}

function listLocal() {
  let list = [];
  try { list = JSON.parse(localStorage.getItem('bdc_bookings') || '[]'); } catch {}
  root.innerHTML = list.length
    ? `<h2>Agendamentos feitos neste aparelho</h2><div class="grid">${list.map((b) => `<a class="card" href="minha-reserva.html?t=${esc(b.token)}"><b>${esc(fmtDate(b.start_at))} às ${fmtTime(b.start_at)}</b><br><span class="muted">Toque para abrir</span></a>`).join('')}</div>`
    : '<div class="notice">Abra o link que você recebeu ao agendar, ou faça um novo agendamento.</div><p><a class="btn" href="agendar.html">Agendar horário</a></p>';
}
show();
