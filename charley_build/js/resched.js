// Painel de remarcação reutilizável (cliente logado ou visitante com código)
import { $, $$, esc, fmtTime, fmtDateLong, todayRecife, addDays, toast, confirmBox, getSettings } from './common.js';
import { api } from './api.js';

export async function reschedulePanel(box, appt, token, onDone) {
  const s = await getSettings();
  const dur = Math.round((new Date(appt.end_at) - new Date(appt.start_at)) / 60000);
  box.hidden = false;
  box.innerHTML = `<h3>Escolha o novo dia e horário</h3><label for="nd-${appt.id}">Dia</label>
    <input type="date" id="nd-${appt.id}" min="${todayRecife()}" max="${addDays(todayRecife(), Number(s.booking_window_days || 60))}"><div class="rs"></div><p class="err rs-err"></p>`;
  const input = $('input', box), out = $('.rs', box), err = $('.rs-err', box);
  input.onchange = async () => {
    out.innerHTML = '<p class="loading"><span class="spin"></span>Buscando…</p>'; err.textContent = '';
    try {
      const rows = await api.rpc('get_available_slots', { p_date: input.value, p_duration: dur, p_exclude: appt.id });
      out.innerHTML = rows.length ? `<div class="slots">${rows.map((r) => `<button type="button" class="slot" data-iso="${r.slot_start}">${fmtTime(r.slot_start)}</button>`).join('')}</div>` : '<p class="notice">Sem horários livres neste dia.</p>';
      $$('.slot', out).forEach((b) => b.onclick = async () => {
        if (!(await confirmBox(`Remarcar para ${fmtDateLong(b.dataset.iso)} às ${fmtTime(b.dataset.iso)}?`, 'Remarcar'))) return;
        try { await api.rpc('reschedule_appointment', { p_id: appt.id, p_new_start: b.dataset.iso, p_token: token || null }); toast('Agendamento remarcado.', 'success'); onDone(); }
        catch (e) { err.textContent = e.message; }
      });
    } catch (e) { out.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
  };
}
