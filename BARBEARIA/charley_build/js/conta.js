import { $, $$, esc, brl, fmtTime, fmtDate, fmtDateLong, durText, maskPhone, onlyDigits, todayRecife, addDays,
         mountChrome, registerSW, getSettings, toast, confirmBox, waLink } from './common.js';
import { api, currentProfile } from './api.js';
import { loadServices } from './services.js';
import { reschedulePanel } from './resched.js';

registerSW();
const settings = await getSettings();
const root = $('#conta');
const STATUS = { pending: ['Aguardando confirmação', 'warn'], confirmed: ['Confirmado', 'ok'], completed: ['Concluído', 'ok'], cancelled: ['Cancelado', 'bad'], no_show: ['Não compareceu', 'bad'] };
const field = (id, label, attrs = '') => `<label for="${id}">${label}</label><input id="${id}" ${attrs}>`;

// ---------- volta do e-mail de redefinição de senha ----------
if (location.hash.includes('access_token') && location.hash.includes('type=recovery')) {
  api.auth.setSessionFromHash(location.hash);
  history.replaceState(null, '', location.pathname);
  await mountChrome('conta.html');
  root.innerHTML = `<div class="card" style="max-width:460px"><h2>Crie uma nova senha</h2>
    <form id="newpw" novalidate>${field('pw1', 'Nova senha', 'type="password" autocomplete="new-password" minlength="6"')}
    <p class="err" id="e"></p><button class="btn" type="submit">Salvar nova senha</button></form></div>`;
  $('#newpw').onsubmit = async (e) => {
    e.preventDefault();
    if ($('#pw1').value.length < 6) { $('#e').textContent = 'A senha precisa ter pelo menos 6 caracteres.'; return; }
    try { await api.auth.updatePassword($('#pw1').value); toast('Senha alterada!', 'success'); location.reload(); }
    catch (ex) { $('#e').textContent = ex.message; }
  };
} else {
  await mountChrome('conta.html');
  api.session() ? await renderArea() : renderAuth();
}

// ---------- entrar / criar conta ----------
function renderAuth(tab = 'in') {
  root.innerHTML = `<div class="row" role="tablist" style="margin-bottom:14px">
      <button class="btn ${tab === 'in' ? '' : 'ghost'}" data-t="in" role="tab">Entrar</button>
      <button class="btn ${tab === 'up' ? '' : 'ghost'}" data-t="up" role="tab">Criar conta</button></div>
    <div class="card" style="max-width:520px" id="box"></div>`;
  $$('[data-t]').forEach((b) => b.onclick = () => renderAuth(b.dataset.t));
  const box = $('#box');
  if (tab === 'in') {
    box.innerHTML = `<form id="f" novalidate>${field('em', 'E-mail', 'type="email" autocomplete="email"')}
      ${field('pw', 'Senha', 'type="password" autocomplete="current-password"')}<p class="err" id="e" role="alert"></p>
      <button class="btn" type="submit">Entrar</button> <button class="btn ghost" type="button" id="forgot">Esqueci minha senha</button></form>
      <p class="hint">Não precisa de conta para agendar. A conta serve para ver histórico, receber avisos e entrar na lista de espera.</p>`;
    $('#f').onsubmit = async (e) => {
      e.preventDefault();
      try { await api.auth.signIn($('#em').value.trim(), $('#pw').value); location.reload(); } catch (ex) { $('#e').textContent = ex.message; }
    };
    $('#forgot').onclick = async () => {
      const email = $('#em').value.trim();
      if (!/^\S+@\S+\.\S+$/.test(email)) { $('#e').textContent = 'Digite seu e-mail no campo acima e toque de novo em "Esqueci minha senha".'; return; }
      try { await api.auth.recover(email, location.origin + '/conta.html'); toast('Se o e-mail estiver cadastrado, você receberá o link para criar uma nova senha.', 'success'); }
      catch (ex) {
        $('#e').innerHTML = `Não foi possível enviar o e-mail agora. Fale com o Charley pelo <a target="_blank" rel="noopener" href="${esc(waLink(settings.shop_whatsapp, 'Olá! Esqueci a senha da minha conta no site. Meu e-mail: ' + email))}">WhatsApp</a> para ele redefinir.`;
      }
    };
  } else {
    box.innerHTML = `<form id="f" novalidate>
      ${field('nm', 'Nome completo', 'autocomplete="name"')}${field('wa', 'WhatsApp com DDD', 'inputmode="tel" autocomplete="tel" placeholder="(81) 99999-9999"')}
      ${field('em', 'E-mail', 'type="email" autocomplete="email"')}${field('pw', 'Senha (mínimo 6 caracteres)', 'type="password" autocomplete="new-password"')}
      ${field('bd', 'Data de nascimento (opcional)', 'type="date"')}
      <label class="check"><input type="checkbox" id="ok"> Li e aceito os <a href="termos.html" target="_blank">Termos de Uso</a> e a <a href="privacidade.html" target="_blank">Política de Privacidade</a>.</label>
      <label class="check"><input type="checkbox" id="mk"> Quero receber novidades e promoções por WhatsApp (opcional).</label>
      <p class="err" id="e" role="alert"></p><button class="btn" type="submit">Criar conta</button></form>`;
    $('#wa').oninput = (e) => { e.target.value = maskPhone(e.target.value); };
    $('#f').onsubmit = async (e) => {
      e.preventDefault(); const err = $('#e'); err.textContent = '';
      const name = $('#nm').value.trim(), wa = onlyDigits($('#wa').value), em = $('#em').value.trim();
      if (name.length < 2) return void (err.textContent = 'Informe seu nome.');
      if (wa.length < 10 || wa.length > 11) return void (err.textContent = 'Informe um WhatsApp válido com DDD.');
      if (!/^\S+@\S+\.\S+$/.test(em)) return void (err.textContent = 'Informe um e-mail válido.');
      if ($('#pw').value.length < 6) return void (err.textContent = 'A senha precisa ter pelo menos 6 caracteres.');
      if (!$('#ok').checked) return void (err.textContent = 'Para criar a conta, aceite os Termos e a Política de Privacidade.');
      try {
        const r = await api.auth.signUp(em, $('#pw').value, { full_name: name, whatsapp: wa });
        if (!r.loggedIn) { box.innerHTML = '<div class="notice">Conta criada! Enviamos um e-mail de confirmação. Confirme e depois entre.</div>'; return; }
        const p = await currentProfile();
        if (p) await api.update('profiles', 'id=eq.' + p.id, { birth_date: $('#bd').value || null, marketing_opt_in: $('#mk').checked });
        location.reload();
      } catch (ex) { err.textContent = ex.message; }
    };
  }
}

// ---------- área logada ----------
async function renderArea(tab = 'next') {
  root.innerHTML = '<p class="loading"><span class="spin"></span>Carregando…</p>';
  const p = await currentProfile();
  if (!p) { await api.auth.signOut(); return renderAuth(); }
  const [appts, notes, wl, reviewed] = await Promise.all([
    api.select('appointments', 'select=id,start_at,end_at,status,source,guest_name,guest_whatsapp,notes,estimated_total,final_total,appointment_items(id,service_name,sequence,price_estimated,is_variable_price)&order=start_at.desc&limit=120').catch(() => []),
    api.select('notifications', 'select=id,type,title,body,created_at,read_at&order=created_at.desc&limit=30').catch(() => []),
    api.select('waitlist', 'select=*&order=desired_date.asc&limit=50').catch(() => []),
    api.select('reviews', 'select=appointment_id&profile_id=eq.'+p.id).catch(() => []),
  ]);
  const reviewedIds = new Set(reviewed.map(x => x.appointment_id));
  const now = Date.now();
  const next = appts.filter((a) => ['pending', 'confirmed'].includes(a.status) && new Date(a.end_at) > now).sort((a, b) => a.start_at.localeCompare(b.start_at));
  const hist = appts.filter((a) => !next.includes(a));
  const unread = notes.filter((n) => !n.read_at).length;
  const tabs = [['next', `Próximos (${next.length})`], ['hist', 'Histórico'], ['notes', `Avisos${unread ? ' (' + unread + ')' : ''}`], ['wait', 'Lista de espera'], ['me', 'Meus dados']];
  root.innerHTML = `<div class="row" style="justify-content:space-between;align-items:center"><h2 style="margin:0">Olá, ${esc((p.full_name || 'cliente').split(' ')[0])}!</h2>
      <div class="row">${p.role === 'admin' ? '<a class="btn small" href="admin.html">Painel do Charley</a>' : ''}<button class="btn small ghost" id="out">Sair</button></div></div>
    <div class="row" role="tablist" style="margin:16px 0">${tabs.map(([k, l]) => `<button class="btn small ${k === tab ? '' : 'ghost'}" data-k="${k}" role="tab">${l}</button>`).join('')}</div><div id="pane"></div>`;
  $('#out').onclick = async () => { await api.auth.signOut(); location.href = 'conta.html'; };
  $$('[data-k]').forEach((b) => b.onclick = () => renderArea(b.dataset.k));
  const pane = $('#pane');
  const apptCard = (a, actions) => {
    const [label, kind] = STATUS[a.status] || [a.status, ''];
    const items = (a.appointment_items || []).sort((x, y) => x.sequence - y.sequence);
    const total = a.final_total ?? a.estimated_total;
    return `<article class="card" data-id="${a.id}"><p><span class="badge ${kind}">${esc(label)}</span></p>
      <h3>${esc(fmtDateLong(a.start_at))}, ${fmtTime(a.start_at)} às ${fmtTime(a.end_at)}</h3>
      <p class="muted">${items.map((i) => esc(i.service_name)).join(' + ')}</p><p class="price">${a.final_total == null && items.some((i) => i.is_variable_price) ? 'A partir de ' : ''}${brl(total)}</p>
      ${actions ? `<div class="row"><button class="btn small ghost" data-act="resch">Remarcar</button><button class="btn small ghost" data-act="cancel">Cancelar</button></div><div class="rbox" hidden></div><p class="err"></p>` : ''}</article>`;
  };
  if (tab === 'next') {
    pane.innerHTML = next.length ? `<div class="grid">${next.map((a) => apptCard(a, true)).join('')}</div><p><a class="btn" href="agendar.html">Novo agendamento</a></p>`
      : '<div class="notice">Você não tem horários marcados.</div><p><a class="btn" href="agendar.html">Agendar horário</a></p>';
    $$('article[data-id]', pane).forEach((card) => {
      const a = next.find((x) => x.id === card.dataset.id), err = $('.err', card);
      $('[data-act=cancel]', card).onclick = async () => {
        if (!(await confirmBox('Deseja realmente cancelar este agendamento?', 'Sim, cancelar'))) return;
        try { await api.rpc('cancel_appointment', { p_id: a.id }); toast('Agendamento cancelado.', 'success'); renderArea('next'); }
        catch (e) { err.innerHTML = `${esc(e.message)} <a target="_blank" rel="noopener" href="${esc(waLink(settings.shop_whatsapp, `Olá! Preciso cancelar meu horário de ${fmtDate(a.start_at)} às ${fmtTime(a.start_at)}.`))}">Falar no WhatsApp</a>`; }
      };
      $('[data-act=resch]', card).onclick = () => reschedulePanel($('.rbox', card), a, null, () => renderArea('next'));
    });
  } else if (tab === 'hist') {
    pane.innerHTML = hist.length ? `<div class="grid">${hist.map((a) => apptCard(a, false).replace('</article>', `${a.status==='completed'&&!reviewedIds.has(a.id)?`<button class="btn small" data-review="${a.id}">Avaliar atendimento</button>`:reviewedIds.has(a.id)?'<span class="badge">Avaliação enviada</span>':''}</article>`)).join('')}</div>` : '<div class="notice">Seu histórico aparecerá aqui.</div>';
    $$('[data-review]',pane).forEach(b=>b.onclick=()=>{const d=document.createElement('dialog');d.className='dlg';d.innerHTML=`<form id="reviewf"><h2>Avaliar atendimento</h2><label>Nota</label><select id="rating"><option value=5>★★★★★ — Excelente</option><option value=4>★★★★☆ — Muito bom</option><option value=3>★★★☆☆ — Bom</option><option value=2>★★☆☆☆ — Regular</option><option value=1>★☆☆☆☆ — Ruim</option></select><label for="comment">Comentário (opcional)</label><textarea id="comment" maxlength=500 rows=4></textarea><p class="err" id="reviewerr"></p><div class="row end"><button type="button" class="btn ghost" data-close>Voltar</button><button class="btn" type="submit">Enviar avaliação</button></div></form>`;document.body.append(d);d.showModal();$('[data-close]',d).onclick=()=>d.close();$('#reviewf',d).onsubmit=async e=>{e.preventDefault();try{await api.rpc('submit_review',{p_appointment:b.dataset.review,p_rating:Number($('#rating',d).value),p_comment:$('#comment',d).value.trim()||null});toast('Avaliação enviada para aprovação. Obrigado!','success');d.close();renderArea('hist')}catch(ex){$('#reviewerr',d).textContent=ex.message}}});
  } else if (tab === 'notes') {
    pane.innerHTML = (notes.length ? `<p><button class="btn small ghost" id="readall">Marcar todos como lidos</button></p>` : '') +
      (notes.length ? notes.map((n) => `<div class="card" style="margin:8px 0;${n.read_at ? 'opacity:.7' : 'border-color:var(--orange)'}"><b>${esc(n.title)}</b><br><span class="muted">${esc(n.body || '')}</span><br><span class="hint">${esc(fmtDate(n.created_at))} ${fmtTime(n.created_at)}</span></div>`).join('') : '<div class="notice">Nenhum aviso por enquanto.</div>');
    $('#readall')?.addEventListener('click', async () => { await api.rpc('mark_all_notifications_read'); renderArea('notes'); });
    if (unread) api.rpc('mark_all_notifications_read').catch(() => {});
  } else if (tab === 'wait') {
    const svcs = await loadServices().catch(() => []);
    const names = Object.fromEntries(svcs.map((s) => [s.id, s.name]));
    const WL = { active: ['Aguardando', 'warn'], notified: ['Vagou! Agende já', 'ok'], booked: ['Agendado', 'ok'], cancelled: ['Cancelado', 'bad'], expired: ['Expirado', 'bad'] };
    pane.innerHTML = `<div class="card" style="max-width:560px"><h3>Avise-me se vagar um horário</h3>
      <p class="hint">Quando alguém cancelar ou remarcar no dia e na faixa de horário que você escolher, você recebe um aviso aqui no site.</p>
      <form id="wf" novalidate><label>Serviços</label>${svcs.map((s) => `<label class="check"><input type="checkbox" value="${s.id}"> ${esc(s.name)}</label>`).join('')}
      <label for="wd">Dia</label><input type="date" id="wd" min="${todayRecife()}" max="${addDays(todayRecife(), Number(settings.booking_window_days || 60))}">
      <div class="row"><div style="flex:1"><label for="w1">A partir de</label><input type="time" id="w1" value="10:00"></div><div style="flex:1"><label for="w2">Até</label><input type="time" id="w2" value="19:00"></div></div>
      <p class="err" id="we"></p><button class="btn" type="submit">Entrar na lista de espera</button></form></div>
      <h3 style="margin-top:24px">Meus pedidos</h3>${wl.length ? wl.map((w) => { const [l, k] = WL[w.status] || [w.status, '']; return `<div class="card" style="margin:8px 0"><span class="badge ${k}">${l}</span> <b>${esc(fmtDate(w.desired_date + 'T12:00:00Z'))}</b>, ${w.from_time.slice(0, 5)} às ${w.to_time.slice(0, 5)}<br><span class="muted">${w.service_ids.map((i) => esc(names[i] || 'Serviço')).join(' + ')}</span>${['active', 'notified'].includes(w.status) ? ` <button class="btn small ghost" data-w="${w.id}">Cancelar</button>` : ''}</div>`; }).join('') : '<p class="muted">Você ainda não tem pedidos.</p>'}`;
    $('#wf').onsubmit = async (e) => {
      e.preventDefault(); const ids = $$('#wf input[type=checkbox]:checked').map((i) => i.value);
      if (!ids.length) return void ($('#we').textContent = 'Escolha pelo menos um serviço.');
      if (!$('#wd').value) return void ($('#we').textContent = 'Escolha o dia.');
      try { await api.rpc('join_waitlist', { p_service_ids: ids, p_date: $('#wd').value, p_from: $('#w1').value, p_to: $('#w2').value }); toast('Você está na lista de espera.', 'success'); renderArea('wait'); }
      catch (ex) { $('#we').textContent = ex.message; }
    };
    $$('[data-w]').forEach((b) => b.onclick = async () => { try { await api.rpc('cancel_waitlist', { p_id: b.dataset.w }); renderArea('wait'); } catch (ex) { toast(ex.message, 'error'); } });
  } else {
    pane.innerHTML = `<div class="card" style="max-width:520px"><form id="pf" novalidate>
      ${field('nm', 'Nome completo', `value="${esc(p.full_name || '')}"`)}${field('wa', 'WhatsApp com DDD', `inputmode="tel" value="${esc(maskPhone(p.whatsapp || ''))}"`)}
      <label for="em">E-mail</label><input id="em" value="${esc(p.email || '')}" disabled>${field('bd', 'Data de nascimento', `type="date" value="${esc(p.birth_date || '')}"`)}
      <label class="check"><input type="checkbox" id="mk" ${p.marketing_opt_in ? 'checked' : ''}> Aceito receber novidades por WhatsApp.</label>
      <p class="err" id="e"></p><button class="btn" type="submit">Salvar</button></form>
      <h3 style="margin-top:24px">Trocar senha</h3><form id="pw" novalidate>${field('np', 'Nova senha', 'type="password" autocomplete="new-password"')}<button class="btn ghost" type="submit">Trocar senha</button></form>
      <h3 style="margin-top:24px">Privacidade e LGPD</h3><p class="hint">Você pode solicitar acesso, correção ou exclusão/anonimização dos seus dados. A equipe da barbearia analisará o pedido.</p><form id="privacyf"><label for="privacykind">O que você deseja solicitar?</label><select id="privacykind"><option value="access">Acesso aos meus dados</option><option value="correction">Correção dos meus dados</option><option value="deletion">Exclusão ou anonimização dos meus dados</option></select><label for="privacydetails">Detalhes do pedido</label><textarea id="privacydetails" maxlength="1000" rows="3" placeholder="Descreva quais dados deseja consultar, corrigir ou excluir."></textarea><p class="err" id="privacyerr"></p><button class="btn ghost" type="submit">Enviar solicitação LGPD</button></form></div>`;
    $('#wa').oninput = (e) => { e.target.value = maskPhone(e.target.value); };
    $('#pf').onsubmit = async (e) => {
      e.preventDefault(); const wa = onlyDigits($('#wa').value);
      if ($('#nm').value.trim().length < 2) return void ($('#e').textContent = 'Informe seu nome.');
      if (wa.length < 10 || wa.length > 11) return void ($('#e').textContent = 'Informe um WhatsApp válido com DDD.');
      try { await api.update('profiles', 'id=eq.' + p.id, { full_name: $('#nm').value.trim(), whatsapp: wa, birth_date: $('#bd').value || null, marketing_opt_in: $('#mk').checked }); toast('Dados salvos.', 'success'); }
      catch (ex) { $('#e').textContent = ex.message; }
    };
    $('#pw').onsubmit = async (e) => { e.preventDefault(); if ($('#np').value.length < 6) return toast('A senha precisa ter pelo menos 6 caracteres.', 'error'); try { await api.auth.updatePassword($('#np').value); toast('Senha alterada.', 'success'); $('#np').value = ''; } catch (ex) { toast(ex.message, 'error'); } };
    $('#privacyf').onsubmit = async (e) => { e.preventDefault(); const details=$('#privacydetails').value.trim(); if(details.length<5) return void ($('#privacyerr').textContent='Descreva brevemente o que você precisa.'); try { await api.rpc('submit_privacy_request',{p_kind:$('#privacykind').value,p_details:details}); toast('Solicitação LGPD enviada. A barbearia poderá acompanhar o pedido.','success'); $('#privacydetails').value=''; } catch(ex) { $('#privacyerr').textContent=ex.message; } };
  }
}
