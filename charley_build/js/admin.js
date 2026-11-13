import { $, $$, esc, brl, fmtTime, fmtDate, fmtDateLong, todayRecife, addDays, durText, maskPhone, onlyDigits, waLink,
         registerSW, getSettings, toast, confirmBox } from './common.js';
import { api, currentProfile } from './api.js';
import { reschedulePanel } from './resched.js';
import { viewCaixa, viewProdutos, viewDespesas, viewVendas, viewConteudo, viewAvaliacoes, viewTarefas, viewMetas, viewCampanhas, viewRelatorios, viewAssinaturas, viewPlanos, viewCupons, viewPrivacidade, viewKits, viewListaEspera } from './modulos.js';

registerSW();
const root = $('#adm');
const STATUS = { pending: ['Aguardando', 'warn'], confirmed: ['Confirmado', 'ok'], completed: ['Concluído', 'ok'], cancelled: ['Cancelado', 'bad'], no_show: ['Faltou', 'bad'] };
const METHODS = { pix: 'Pix', cash: 'Dinheiro', debit: 'Débito', credit: 'Crédito', other: 'Outro' };
const TABS = [['resumo', 'Visão geral'], ['agenda', 'Agenda'], ['clientes', 'Clientes'], ['servicos', 'Serviços'], ['caixa','Caixa'], ['vendas','Vendas'], ['produtos','Estoque'], ['kits','Kits'], ['despesas','Despesas'], ['cupons','Cupons'], ['planos','Planos'], ['assinaturas','Assinaturas'], ['lista-espera','Lista de espera'], ['galeria','Galeria'], ['conteudo','Avisos do site'], ['faq','FAQ'], ['avaliacoes','Avaliações'], ['tarefas','Tarefas'], ['metas','Metas'], ['campanhas','Campanhas'], ['privacidade','LGPD'], ['relatorios','Relatórios'], ['horarios', 'Horários'], ['avisos', 'Notificações']];
const S = { date: todayRecife(), view: 'day', tab: 'resumo', services: [] };
const field = (id, label, attrs = '') => `<label for="${id}">${label}</label><input id="${id}" ${attrs}>`;
const dayStart = (ymd) => new Date(ymd + 'T00:00:00-03:00').toISOString();
const ymdOf = (iso) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Recife' }).format(new Date(iso));
const dowOf = (ymd) => new Date(ymd + 'T12:00:00Z').getUTCDay();
const wd = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const toIso = (ymd, hhmm) => new Date(`${ymd}T${hhmm}:00-03:00`).toISOString();

function modal(html) {
  const d = document.createElement('dialog'); d.className = 'dlg big';
  d.innerHTML = `<button type="button" class="dlg-x" aria-label="Fechar janela" title="Fechar">×</button>${html}`; document.body.appendChild(d);
  d.addEventListener('close', () => d.remove()); d.querySelector('.dlg-x').addEventListener('click', () => d.close()); d.showModal();
  $$('[data-close]', d).forEach((b) => b.addEventListener('click', (e) => { e.preventDefault(); d.close(); }));
  return d;
}
const guard = async (fn) => { try { return await fn(); } catch (e) { toast(e.message, 'error'); return null; } };

async function init() {
  root.innerHTML = '<div class="adm-wrap"><div class="card"><p class="loading"><span class="spin"></span>Verificando acesso…</p></div></div>';
  try {
    const me = api.session() ? await currentProfile() : null;
    if (!me || String(me.role || '').toLowerCase() !== 'admin') {
      const diagnostic = api.lastProfileDiagnostic();
      root.innerHTML = `<div class="adm-wrap"><div class="card" style="max-width:560px"><h1>Painel do Charley</h1>
        <p>${me ? 'Esta conta não tem acesso ao painel.' : api.session() ? 'Não foi possível confirmar seu perfil administrativo.' : 'Entre com a conta do administrador para continuar.'}</p>
        ${diagnostic ? `<div class="notice error" role="alert">${esc(diagnostic)}</div>` : ''}
        <div class="row"><a class="btn" href="conta.html">${me ? 'Voltar à minha conta' : 'Entrar'}</a>
        <button class="btn ghost" id="diag" type="button">Diagnosticar conexão</button></div>
        <pre id="diag-result" class="mini" style="white-space:pre-wrap;overflow-wrap:anywhere"></pre></div></div>`;
      $('#diag')?.addEventListener('click', async () => {
        const out = $('#diag-result'); out.textContent = 'Verificando tabelas e permissões…';
        try { const report = await api.diagnose(); out.textContent = JSON.stringify(report, null, 2); }
        catch (error) { out.textContent = error.message; }
      });
    } else {
      shell();
      route();
      window.addEventListener('hashchange', route);
    }
  } catch (error) {
    root.innerHTML = `<div class="adm-wrap"><div class="card"><h1>Painel do Charley</h1><div class="notice error">${esc(error.message || 'Falha ao iniciar o painel.')}</div><a class="btn" href="conta.html">Voltar</a></div></div>`;
  }
}

function shell() {
  root.innerHTML = `<div class="adm-bar"><b style="color:var(--orange)">Painel do Charley</b>
    <div class="row"><a class="btn small ghost" href="index.html" target="_blank">Ver site</a><a class="btn small ghost" href="conta.html">Minha conta</a><button class="btn small ghost" id="out">Sair</button></div></div>
    <nav class="adm-tabs" id="tabs"></nav><div class="adm-wrap" id="view"></div>`;
  $('#out').onclick = async () => { await api.auth.signOut(); location.href = 'conta.html'; };
}
let routeVersion = 0;
function route() {
  const version = ++routeVersion;
  S.tab = (location.hash.replace('#', '') || 'resumo');
  if (!TABS.some(([k]) => k === S.tab)) S.tab = 'resumo';
  $('#tabs').innerHTML = TABS.map(([k, l]) => `<a href="#${k}" ${k === S.tab ? 'aria-current="page"' : ''}>${l}</a>`).join('');
  const actions = { resumo: viewOverview, agenda: viewAgenda, clientes: viewClientes, servicos: viewServicos, horarios: viewHorarios, avisos: viewAvisos, caixa:()=>viewCaixa(view()), vendas:()=>viewVendas(view()), produtos:()=>viewProdutos(view()), kits:()=>viewKits(view()), despesas:()=>viewDespesas(view()), cupons:()=>viewCupons(view()), privacidade:()=>viewPrivacidade(view()), planos:()=>viewPlanos(view()), assinaturas:()=>viewAssinaturas(view()), 'lista-espera':()=>viewListaEspera(view()), galeria:()=>viewConteudo(view(),'gallery_items','Galeria'), conteudo:()=>viewConteudo(view(),'announcements','Avisos do site'), faq:()=>viewConteudo(view(),'faq_items','Perguntas frequentes'), avaliacoes:()=>viewAvaliacoes(view()), tarefas:()=>viewTarefas(view()), metas:()=>viewMetas(view()), campanhas:()=>viewCampanhas(view()), relatorios:()=>viewRelatorios(view()) }[S.tab];
  const target = view(); target.innerHTML = '<p class="loading"><span class="spin"></span>Carregando módulo…</p>';
  Promise.resolve().then(actions).catch(e => { if(version===routeVersion) target.innerHTML = `<div class="notice error">${esc(e.message||'Não foi possível carregar este módulo.')}</div>`; });
}
const view = () => $('#view');

// Visão geral: consolidado mensal e próximos horários, sem gravar dados.
async function viewOverview() {
  const target = view();
  const today = todayRecife();
  const first = today.slice(0, 8) + '01';
  const [report, appointments, cash] = await Promise.all([
    api.rpc('report_summary', { p_from: first, p_to: today }),
    loadAppts(today, addDays(today, 7)),
    api.rpc('cash_summary').catch(() => null),
  ]);
  const upcoming = appointments.filter(a => ['pending', 'confirmed'].includes(a.status)).slice(0, 6);
  const m = report.appointments || {};
  const cashMethods = cash?.status === "open" ? [["cash","Dinheiro"],["pix","Pix"],["debit","Débito"],["credit","Crédito"],["other","Outro"]].map(([k,label]) => { const paid = Number((cash.payments_by_method || {})[k] || 0); const manual = (cash.movements || []).filter(x => x.method === k).reduce((n,x) => n + (x.kind === "in" ? 1 : -1) * Number(x.amount || 0), 0); return {label,total:paid+manual}; }) : [];
  target.innerHTML = `<div class="row" style="justify-content:space-between;align-items:center;flex-wrap:wrap"><div><h2>Visão geral</h2><p class="muted">Resumo de ${fmtDate(first + 'T12:00:00')} até ${fmtDate(today + 'T12:00:00')}</p></div><button class="btn" id="new-from-home">+ Novo agendamento</button></div>
    <div class="stats"><div class="stat">Faturamento do mês<b>${brl(report.revenue || 0)}</b></div><div class="stat">Despesas pagas<b>${brl(report.expenses || 0)}</b></div><div class="stat">Resultado<b>${brl(report.profit || 0)}</b></div><div class="stat">Ticket médio<b>${brl(report.avg_ticket || 0)}</b></div><div class="stat">Atendimentos concluídos<b>${m.completed || 0}</b></div><div class="stat">Novos clientes<b>${report.new_customers || 0}</b></div></div>
    <div class="grid" style="margin-top:16px"><section class="card"><div class="row" style="justify-content:space-between"><h3>Caixa</h3><span class="badge">${cash?.status === 'open' ? 'Aberto' : 'Fechado'}</span></div>${cash?.status === 'open' ? `<p>Saldo inicial: <b>${brl(cash.opening_amount || 0)}</b></p><p>Dinheiro esperado: <b>${brl(cash.expected_cash || 0)}</b></p><p><b>Resumo por forma</b></p>${cashMethods.map(x => `<p>${x.label}: <b>${brl(x.total)}</b></p>`).join('')}<p class="muted">Os outros meios não alteram o dinheiro físico. Os valores são atualizados ao abrir esta visão.</p>` : '<p class="muted">Não há caixa aberto no momento.</p>'}<button class="btn small ghost" id="open-cash">Abrir módulo Caixa</button></section>
    <section class="card"><div class="row" style="justify-content:space-between"><h3>Próximos horários</h3><button class="btn small ghost" id="open-agenda">Ver agenda</button></div>${upcoming.length ? upcoming.map(a => `<div class="svc"><div><b>${esc(a.guest_name || 'Cliente')}</b><br><span class="muted">${fmtDate(a.start_at)} · ${fmtTime(a.start_at)} · ${(a.appointment_items || []).map(i => esc(i.service_name)).join(' + ')}</span></div><span class="badge">${STATUS[a.status]?.[0] || esc(a.status)}</span></div>`).join('') : '<p class="muted">Nenhum horário pendente ou confirmado nos próximos 7 dias.</p>'}</section></div>
    <section class="card" style="margin-top:16px"><h3>Acessos rápidos</h3><div class="row"><button class="btn small ghost" id="quick-clients">Clientes</button><button class="btn small ghost" id="quick-sales">Vendas</button><button class="btn small ghost" id="quick-plans">Planos e assinaturas</button><button class="btn small ghost" id="quick-wait">Lista de espera</button><button class="btn small ghost" id="quick-reports">Relatórios</button></div></section>`;
  $('#new-from-home').onclick = () => newAppointment();
  $('#open-cash').onclick = () => { location.hash = '#caixa'; };
  $('#open-agenda').onclick = () => { location.hash = '#agenda'; };
  $('#quick-clients').onclick = () => { location.hash = '#clientes'; };
  $('#quick-sales').onclick = () => { location.hash = '#vendas'; };
  $('#quick-plans').onclick = () => { location.hash = '#assinaturas'; };
  $('#quick-wait').onclick = () => { location.hash = '#lista-espera'; };
  $('#quick-reports').onclick = () => { location.hash = '#relatorios'; };
}

// ====================== AGENDA ======================
async function viewAgenda() {
  const v = view();
  v.innerHTML = `<div class="row" style="align-items:center;justify-content:space-between">
    <div class="row" style="align-items:center"><button class="btn small ghost" id="prev" aria-label="Anterior">‹</button><input type="date" id="dt" value="${S.date}" style="width:auto"><button class="btn small ghost" id="next" aria-label="Próximo">›</button><button class="btn small ghost" id="today">Hoje</button></div>
    <div class="row">${[['day', 'Dia'], ['week', 'Semana'], ['month', 'Mês']].map(([k, l]) => `<button class="btn small ${S.view === k ? '' : 'ghost'}" data-v="${k}">${l}</button>`).join('')}</div></div>
    <div class="row" style="margin:12px 0"><button class="btn small" id="new">+ Novo agendamento</button><button class="btn small ghost" id="walk">+ Atendimento sem hora marcada</button><button class="btn small ghost" id="blk">Bloquear horário</button></div>
    <div id="ag"><p class="loading"><span class="spin"></span>Carregando…</p></div>`;
  const step = S.view === 'day' ? 1 : S.view === 'week' ? 7 : 30;
  $('#prev').onclick = () => { S.date = addDays(S.date, -step); viewAgenda(); };
  $('#next').onclick = () => { S.date = addDays(S.date, step); viewAgenda(); };
  $('#today').onclick = () => { S.date = todayRecife(); viewAgenda(); };
  $('#dt').onchange = (e) => { S.date = e.target.value || S.date; viewAgenda(); };
  $$('[data-v]').forEach((b) => b.onclick = () => { S.view = b.dataset.v; viewAgenda(); });
  $('#new').onclick = () => newAppointment();
  $('#walk').onclick = () => walkIn();
  $('#blk').onclick = () => blockTime();
  await ({ day: renderDay, week: renderWeek, month: renderMonth }[S.view])();
}
const loadAppts = (from, to) => api.select('appointments', `select=id,start_at,end_at,status,source,guest_name,guest_whatsapp,notes,estimated_total,final_total,appointment_items(id,service_name,sequence,price_estimated,is_variable_price)&start_at=gte.${encodeURIComponent(dayStart(from))}&start_at=lt.${encodeURIComponent(dayStart(to))}&order=start_at&limit=250`);

async function renderDay() {
  const box = $('#ag');
  try {
    const [list, blocks] = await Promise.all([loadAppts(S.date, addDays(S.date, 1)),
      api.select('availability_blocks', `select=*&end_at=gt.${encodeURIComponent(dayStart(S.date))}&start_at=lt.${encodeURIComponent(dayStart(addDays(S.date, 1)))}&order=start_at`)]);
    const active = list.filter((a) => ['pending', 'confirmed'].includes(a.status));
    const done = list.filter((a) => a.status === 'completed');
    const revenue = done.reduce((n, a) => n + Number(a.final_total || 0), 0);
    const expected = active.reduce((n, a) => n + Number(a.estimated_total || 0), 0);
    box.innerHTML = `<h2 class="cap">${esc(new Date(S.date + 'T12:00:00Z').toLocaleDateString('pt-BR', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long' }))}</h2>
      <div class="stats"><div class="stat">Agendados<b>${active.length}</b></div><div class="stat">Concluídos<b>${done.length}</b></div><div class="stat">Faturado hoje<b>${brl(revenue)}</b></div><div class="stat">A receber (estimado)<b>${brl(expected)}</b></div></div>
      ${blocks.map((b) => `<div class="notice">🔒 Bloqueado ${fmtTime(b.start_at)} às ${fmtTime(b.end_at)}${b.reason ? ': ' + esc(b.reason) : ''} <button class="btn small ghost" data-rb="${b.id}">Remover</button></div>`).join('')}
      <div class="grid" style="grid-template-columns:1fr">${list.length ? list.map(apCard).join('') : '<p class="empty">Nenhum agendamento neste dia.</p>'}</div>`;
    $$('[data-rb]').forEach((b) => b.onclick = () => guard(async () => { await api.remove('availability_blocks', 'id=eq.' + b.dataset.rb); toast('Bloqueio removido.', 'success'); renderDay(); }));
    list.forEach((a) => wireCard(a));
  } catch (e) { box.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
}
function apCard(a) {
  const [label, kind] = STATUS[a.status] || [a.status, ''];
  const items = (a.appointment_items || []).slice().sort((x, y) => x.sequence - y.sequence);
  const variable = items.some((i) => i.is_variable_price);
  const open = ['pending', 'confirmed'].includes(a.status);
  const total = a.final_total ?? a.estimated_total;
  return `<article class="card ap ${a.status}" id="ap-${a.id}"><div class="row" style="justify-content:space-between"><span class="t">${fmtTime(a.start_at)} – ${fmtTime(a.end_at)}</span><span class="badge ${kind}">${label}${a.source !== 'online' ? ' · ' + (a.source === 'walk_in' ? 'sem hora' : 'manual') : ''}</span></div>
    <p style="margin:6px 0"><b>${esc(a.guest_name || 'Cliente')}</b> ${a.guest_whatsapp ? `· <a target="_blank" rel="noopener" href="${esc(waLink(a.guest_whatsapp))}">${esc(maskPhone(a.guest_whatsapp.slice(-11)))}</a>` : ''}</p>
    <p class="muted" style="margin:0">${items.map((i) => esc(i.service_name)).join(' + ')} · ${durText(Math.round((new Date(a.end_at) - new Date(a.start_at)) / 60000))}</p>
    <p class="price" style="text-align:left">${a.final_total == null && variable ? 'A partir de ' : ''}${brl(total)}</p>${a.notes ? `<p class="mini">📝 ${esc(a.notes)}</p>` : ''}
    ${open ? `<div class="row">${a.status === 'pending' ? '<button class="btn small" data-a="confirm">Confirmar</button>' : ''}<button class="btn small" data-a="done">Concluir</button><button class="btn small ghost" data-a="resch">Remarcar</button><button class="btn small ghost" data-a="noshow">Faltou</button><button class="btn small ghost" data-a="cancel">Cancelar</button></div><div class="rbox" hidden></div>` : ''}</article>`;
}
function wireCard(a) {
  const c = $('#ap-' + a.id); if (!c) return;
  const on = (k, fn) => { const b = $(`[data-a=${k}]`, c); if (b) b.onclick = fn; };
  const refresh = () => (S.tab === 'agenda' ? viewAgenda() : route());
  on('confirm', () => guard(async () => { await api.rpc('admin_set_status', { p_id: a.id, p_status: 'confirmed' }); toast('Confirmado.', 'success'); refresh(); }));
  on('noshow', async () => { if (await confirmBox('Marcar que o cliente faltou?', 'Sim, faltou')) guard(async () => { await api.rpc('admin_set_status', { p_id: a.id, p_status: 'no_show' }); refresh(); }); });
  on('cancel', async () => { if (await confirmBox('Cancelar este agendamento? O cliente será avisado se tiver conta.', 'Sim, cancelar')) guard(async () => { await api.rpc('admin_set_status', { p_id: a.id, p_status: 'cancelled' }); toast('Cancelado.', 'success'); refresh(); }); });
  on('resch', () => reschedulePanel($('.rbox', c), a, null, refresh));
  on('done', () => completeModal(a, refresh));
}

function methodSelect(id) { return `<label for="${id}">Forma de pagamento</label><select id="${id}">${Object.entries(METHODS).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select>`; }

function completeModal(a, done) {
  const items = (a.appointment_items || []).slice().sort((x, y) => x.sequence - y.sequence);
  const d = modal(`<form method="dialog" id="cf"><h2>Concluir atendimento</h2><p class="muted">${esc(a.guest_name || 'Cliente')} · ${fmtTime(a.start_at)}</p>
    ${items.map((i) => `<label for="p-${i.id}">${esc(i.service_name)}${i.is_variable_price ? ' (preço variável)' : ''}</label><input id="p-${i.id}" data-item="${i.id}" type="number" step="0.01" min="0" value="${Number(i.price_estimated).toFixed(2)}">`).join('')}
    ${field('disc', 'Desconto (R$)', 'type="number" step="0.01" min="0" value="0"')}${methodSelect('met')}
    <p class="price" id="tot" style="text-align:left"></p><p class="err" id="e"></p>
    <div class="row end"><button class="btn ghost" data-close>Voltar</button><button class="btn" value="ok">Registrar pagamento</button></div></form>`);
  const calc = () => { const s = $$('[data-item]', d).reduce((n, i) => n + (Number(i.value) || 0), 0); $('#tot', d).textContent = 'Total a receber: ' + brl(Math.max(0, s - (Number($('#disc', d).value) || 0))); };
  $$('input', d).forEach((i) => i.addEventListener('input', calc)); calc();
  $('#cf', d).onsubmit = async (e) => {
    e.preventDefault();
    const prices = {}; $$('[data-item]', d).forEach((i) => { prices[i.dataset.item] = Number(i.value) || 0; });
    try { await api.rpc('complete_appointment', { p_id: a.id, p_prices: prices, p_method: $('#met', d).value, p_discount: Number($('#disc', d).value) || 0 }); d.close(); toast('Atendimento concluído e pagamento registrado.', 'success'); done(); }
    catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

function servicePicker(name = 'sv') {
  return S.services.filter((s) => s.is_active).map((s) => `<label class="check"><input type="checkbox" name="${name}" value="${s.id}" data-inc="${s.includes_cut}" data-cut="${s.is_cut}"> ${esc(s.name)} <span class="muted">(${durText(s.duration_min)} · ${brl(s.price)})</span></label>`).join('');
}
const pickedServices = (d, name = 'sv') => $$(`input[name=${name}]:checked`, d).map((i) => i.value);

async function customerPicker(d) { // busca simples por nome/whatsapp
  const q = $('#cq', d).value.trim(); const out = $('#cres', d);
  if (q.length < 2) { out.innerHTML = ''; return; }
  const dig = onlyDigits(q);
  const filter = dig.length >= 4 ? `whatsapp.ilike.*${dig}*` : `full_name.ilike.*${q.replace(/[*,()]/g, '')}*`;
  const rows = await api.select('customers', `select=id,full_name,whatsapp&or=(${filter})&order=full_name&limit=6`).catch(() => []);
  out.innerHTML = rows.map((r) => `<button type="button" class="btn small ghost" data-c="${r.id}" data-n="${esc(r.full_name)}" data-w="${esc(r.whatsapp || '')}">${esc(r.full_name)} ${r.whatsapp ? '· ' + esc(maskPhone(r.whatsapp.slice(-11))) : ''}</button>`).join(' ');
  $$('[data-c]', out).forEach((b) => b.onclick = () => { d.dataset.cust = b.dataset.c; $('#nm', d).value = b.dataset.n; $('#wa', d).value = maskPhone(b.dataset.w); out.innerHTML = `<span class="badge ok">Cliente selecionado: ${esc(b.dataset.n)}</span>`; });
}
const custBlock = () => `<label for="cq">Buscar cliente já cadastrado (nome ou WhatsApp)</label><input id="cq" autocomplete="off"><div id="cres" class="row" style="margin-top:6px"></div>
  ${field('nm', 'Nome', '')}${field('wa', 'WhatsApp com DDD (opcional)', 'inputmode="tel"')}`;
function wireCust(d) {
  let t; $('#cq', d).addEventListener('input', () => { clearTimeout(t); delete d.dataset.cust; t = setTimeout(() => customerPicker(d), 250); });
  $('#wa', d).addEventListener('input', (e) => { e.target.value = maskPhone(e.target.value); });
  ['nm', 'wa'].forEach((id) => $('#' + id, d).addEventListener('input', () => { if (id === 'nm') delete d.dataset.cust; }));
}

async function ensureServices() {
  if (S.services.length) return S.services;
  S.services = await api.select('services', 'select=id,name,duration_min,price,is_active,includes_cut,is_cut,is_variable_price,sort_order&order=sort_order').catch(() => []);
  return S.services;
}

async function newAppointment(pre = {}) {
  await ensureServices();
  const d = modal(`<form method="dialog" id="nf"><h2>Novo agendamento</h2>${custBlock()}<label>Serviços</label>${servicePicker()}
    <div class="row"><div style="flex:1">${field('nd', 'Dia', `type="date" value="${S.date}"`)}</div><div style="flex:1">${field('nt', 'Horário', 'type="time" step="300" value="10:00"')}</div></div>
    <label for="nn">Observação</label><textarea id="nn" maxlength="300"></textarea><p class="hint">Pode ser fora do horário normal (encaixe). O sistema só recusa se já houver outro cliente no mesmo horário.</p>
    <p class="err" id="e"></p><div class="row end"><button class="btn ghost" data-close>Voltar</button><button class="btn" value="ok">Agendar</button></div></form>`);
  wireCust(d);
  if (pre.customer) { d.dataset.cust = pre.customer.id; $('#nm', d).value = pre.customer.full_name; $('#wa', d).value = maskPhone(pre.customer.whatsapp || ''); }
  $('#nf', d).onsubmit = async (e) => {
    e.preventDefault(); const ids = pickedServices(d);
    if (!ids.length) return void ($('#e', d).textContent = 'Escolha pelo menos um serviço.');
    if (!d.dataset.cust && $('#nm', d).value.trim().length < 2) return void ($('#e', d).textContent = 'Informe o nome do cliente.');
    try {
      await api.rpc('admin_create_appointment', { p_service_ids: ids, p_start: toIso($('#nd', d).value, $('#nt', d).value), p_name: $('#nm', d).value.trim() || null, p_whatsapp: onlyDigits($('#wa', d).value) || null,
        p_customer_id: d.dataset.cust || null, p_notes: $('#nn', d).value.trim() || null });
      d.close(); toast('Agendamento criado.', 'success'); S.date = $('#nd', d).value; if (S.tab === 'agenda') viewAgenda(); else if (S.tab === 'resumo') viewOverview();
    } catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

async function walkIn() {
  await ensureServices();
  const d = modal(`<form method="dialog" id="wf"><h2>Atendimento sem hora marcada</h2><p class="hint">Para o cliente que chegou e foi atendido na hora.</p>${custBlock()}<label>Serviços</label>${servicePicker()}
    <div id="prices"></div>${field('disc', 'Desconto (R$)', 'type="number" step="0.01" min="0" value="0"')}${methodSelect('met')}<p class="price" id="tot" style="text-align:left"></p>
    <p class="err" id="e"></p><div class="row end"><button class="btn ghost" data-close>Voltar</button><button class="btn" value="ok">Registrar</button></div></form>`);
  wireCust(d);
  const redraw = () => {
    const ids = pickedServices(d), old = {}; $$('[data-sp]', d).forEach((i) => { old[i.dataset.sp] = i.value; });
    $('#prices', d).innerHTML = ids.map((id) => { const s = S.services.find((x) => x.id === id); return `<label for="sp-${id}">Valor de ${esc(s.name)} (R$)</label><input id="sp-${id}" data-sp="${id}" type="number" step="0.01" min="0" value="${old[id] ?? Number(s.price).toFixed(2)}">`; }).join('');
    $$('[data-sp],#disc', d).forEach((i) => i.addEventListener('input', calc)); calc();
  };
  const calc = () => { const s = $$('[data-sp]', d).reduce((n, i) => n + (Number(i.value) || 0), 0); $('#tot', d).textContent = 'Total recebido: ' + brl(Math.max(0, s - (Number($('#disc', d).value) || 0))); };
  $$('input[name=sv]', d).forEach((i) => i.addEventListener('change', redraw));
  $('#wf', d).onsubmit = async (e) => {
    e.preventDefault(); const ids = pickedServices(d);
    if (!ids.length) return void ($('#e', d).textContent = 'Escolha pelo menos um serviço.');
    const prices = {}; $$('[data-sp]', d).forEach((i) => { prices[i.dataset.sp] = Number(i.value) || 0; });
    try {
      await api.rpc('admin_walkin', { p_service_ids: ids, p_name: $('#nm', d).value.trim() || null, p_whatsapp: onlyDigits($('#wa', d).value) || null, p_customer_id: d.dataset.cust || null,
        p_prices: prices, p_method: $('#met', d).value, p_discount: Number($('#disc', d).value) || 0 });
      d.close(); toast('Atendimento registrado.', 'success'); S.date = todayRecife(); if (S.tab === 'agenda') viewAgenda();
    } catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

function blockTime() {
  const d = modal(`<form method="dialog" id="bf"><h2>Bloquear horário</h2><p class="hint">Folga, feriado, consulta, pausa… Ninguém consegue agendar neste período.</p>
    ${field('bd', 'Dia', `type="date" value="${S.date}"`)}<label class="check"><input type="checkbox" id="all"> Dia inteiro</label>
    <div class="row" id="hrs"><div style="flex:1">${field('b1', 'Das', 'type="time" value="12:00"')}</div><div style="flex:1">${field('b2', 'Às', 'type="time" value="13:00"')}</div></div>
    ${field('br', 'Motivo (opcional)', 'maxlength="100"')}<p class="err" id="e"></p><div class="row end"><button class="btn ghost" data-close>Voltar</button><button class="btn" value="ok">Bloquear</button></div></form>`);
  $('#all', d).onchange = (e) => { $('#hrs', d).hidden = e.target.checked; };
  $('#bf', d).onsubmit = async (e) => {
    e.preventDefault(); const day = $('#bd', d).value, all = $('#all', d).checked;
    const s = all ? toIso(day, '00:00') : toIso(day, $('#b1', d).value), en = all ? new Date(new Date(toIso(day, '00:00')).getTime() + 86400000).toISOString() : toIso(day, $('#b2', d).value);
    if (new Date(en) <= new Date(s)) return void ($('#e', d).textContent = 'O horário final precisa ser depois do inicial.');
    try { await api.insert('availability_blocks', [{ start_at: s, end_at: en, reason: $('#br', d).value.trim() || null }]); d.close(); toast('Horário bloqueado.', 'success'); S.date = day; viewAgenda(); }
    catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

async function renderWeek() {
  const box = $('#ag'); const start = addDays(S.date, -dowOf(S.date)); const end = addDays(start, 7);
  try {
    const list = await loadAppts(start, end);
    box.innerHTML = `<div class="week">${Array.from({ length: 7 }, (_, i) => { const day = addDays(start, i); const items = list.filter((a) => ymdOf(a.start_at) === day && !['cancelled'].includes(a.status));
      return `<div class="col"><b ${day === todayRecife() ? 'style="color:var(--orange)"' : ''}>${wd[i]} ${day.slice(8)}/${day.slice(5, 7)}</b>${items.length ? items.map((a) => `<div class="it" data-day="${day}">${fmtTime(a.start_at)} ${esc((a.guest_name || '').split(' ')[0])}<br><span class="muted">${(a.appointment_items || []).map((x) => esc(x.service_name)).join('+')}</span></div>`).join('') : '<p class="hint">livre</p>'}</div>`; }).join('')}</div>`;
    $$('[data-day]').forEach((x) => x.onclick = () => { S.date = x.dataset.day; S.view = 'day'; viewAgenda(); });
  } catch (e) { box.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
}
async function renderMonth() {
  const box = $('#ag'); const first = S.date.slice(0, 8) + '01'; const lastDay = new Date(Date.UTC(+S.date.slice(0, 4), +S.date.slice(5, 7), 0)).getUTCDate();
  const next = addDays(first, lastDay);
  try {
    const list = await loadAppts(first, next);
    const count = {}; list.filter((a) => a.status !== 'cancelled').forEach((a) => { const k = ymdOf(a.start_at); count[k] = (count[k] || 0) + 1; });
    const lead = dowOf(first);
    box.innerHTML = `<h2 class="cap">${esc(new Date(first + 'T12:00:00Z').toLocaleDateString('pt-BR', { timeZone: 'UTC', month: 'long', year: 'numeric' }))}</h2><div class="cal">${wd.map((w) => `<div class="h">${w}</div>`).join('')}${Array(lead).fill('<div></div>').join('')}${Array.from({ length: lastDay }, (_, i) => { const day = addDays(first, i); return `<div class="d ${day === todayRecife() ? 'today' : ''}" data-day="${day}" role="button" tabindex="0">${i + 1}${count[day] ? `<br><span class="n">${count[day]}</span>` : ''}</div>`; }).join('')}</div>`;
    $$('[data-day]').forEach((x) => x.onclick = () => { S.date = x.dataset.day; S.view = 'day'; viewAgenda(); });
  } catch (e) { box.innerHTML = `<p class="err">${esc(e.message)}</p>`; }
}

// ====================== CLIENTES ======================
async function viewClientes() {
  view().innerHTML = `<div class="row" style="align-items:end"><div style="flex:1;min-width:220px">${field('q', 'Buscar por nome ou WhatsApp')}</div><button class="btn" id="addc">+ Novo cliente</button></div><div id="cl" style="margin-top:14px"></div>`;
  let t; const load = async () => {
    const q = $('#q').value.trim(), dig = onlyDigits(q);
    const filter = !q ? '' : dig.length >= 4 ? `&or=(whatsapp.ilike.*${dig}*)` : `&or=(full_name.ilike.*${q.replace(/[*,()]/g, '')}*)`;
    try {
      const rows = await api.select('customers', `select=*&order=full_name&limit=60${filter}`);
      $('#cl').innerHTML = rows.length ? `<div class="grid">${rows.map((c) => `<button class="card" style="text-align:left;cursor:pointer;color:inherit;font:inherit" data-id="${c.id}"><b>${esc(c.full_name)}</b>${c.is_active ? '' : ' <span class="badge bad">inativo</span>'}<br><span class="muted">${c.whatsapp ? esc(maskPhone(c.whatsapp.slice(-11))) : 'sem WhatsApp'}${c.profile_id ? ' · tem conta' : ''}</span></button>`).join('')}</div>` : '<p class="empty">Nenhum cliente encontrado.</p>';
      $$('[data-id]', $('#cl')).forEach((b) => b.onclick = () => customerCard(rows.find((r) => r.id === b.dataset.id)));
    } catch (e) { $('#cl').innerHTML = `<p class="err">${esc(e.message)}</p>`; }
  };
  $('#q').oninput = () => { clearTimeout(t); t = setTimeout(load, 300); };
  $('#addc').onclick = () => customerCard(null);
  load();
}
async function customerCard(c) {
  const hist = c ? await api.select('appointments', `select=*,appointment_items(*)&customer_id=eq.${c.id}&order=start_at.desc&limit=50`).catch(() => []) : [];
  const spent = hist.filter((a) => a.status === 'completed').reduce((n, a) => n + Number(a.final_total || 0), 0);
  const visits = hist.filter((a) => a.status === 'completed').length;
  const d = modal(`<form method="dialog" id="cf"><h2>${c ? esc(c.full_name) : 'Novo cliente'}</h2>
    ${c ? `<div class="stats"><div class="stat">Atendimentos<b>${visits}</b></div><div class="stat">Total gasto<b>${brl(spent)}</b></div></div>` : ''}
    ${field('nm', 'Nome', `value="${esc(c?.full_name || '')}"`)}${field('wa', 'WhatsApp com DDD', `inputmode="tel" value="${esc(maskPhone((c?.whatsapp || '').slice(-11)))}"`)}
    ${field('em', 'E-mail', `type="email" value="${esc(c?.email || '')}"`)}${field('bd', 'Aniversário', `type="date" value="${esc(c?.birth_date || '')}"`)}
    <label for="nt">Observações do Charley (só você vê)</label><textarea id="nt">${esc(c?.notes || '')}</textarea>
    <label class="check"><input type="checkbox" id="mk" ${c?.marketing_opt_in ? 'checked' : ''}> Aceitou receber novidades por WhatsApp</label>
    <label class="check"><input type="checkbox" id="ac" ${c && !c.is_active ? '' : 'checked'}> Cliente ativo</label><p class="err" id="e"></p>
    <div class="row">${c?.whatsapp ? `<a class="btn small ghost" target="_blank" rel="noopener" href="${esc(waLink(c.whatsapp))}">WhatsApp</a>` : ''}${c ? '<button class="btn small ghost" type="button" id="sch">Agendar para este cliente</button>' : ''}</div>
    ${c ? `<h3 style="margin-top:18px">Histórico</h3>${hist.length ? hist.map((a) => `<div class="mini" style="margin:6px 0"><span class="badge ${STATUS[a.status]?.[1] || ''}">${STATUS[a.status]?.[0] || a.status}</span> ${esc(fmtDate(a.start_at))} ${fmtTime(a.start_at)} · ${(a.appointment_items || []).map((i) => esc(i.service_name)).join(' + ')} · ${brl(a.final_total ?? a.estimated_total)}</div>`).join('') : '<p class="muted">Sem atendimentos ainda.</p>'}` : ''}
    <div class="row end" style="margin-top:14px"><button class="btn ghost" data-close>Fechar</button><button class="btn" value="ok">Salvar</button></div></form>`);
  $('#wa', d).oninput = (e) => { e.target.value = maskPhone(e.target.value); };
  if (c) $('#sch', d).onclick = () => { d.close(); location.hash = 'agenda'; newAppointment({ customer: c }); };
  $('#cf', d).onsubmit = async (e) => {
    e.preventDefault(); const row = { full_name: $('#nm', d).value.trim(), whatsapp: onlyDigits($('#wa', d).value) || null, email: $('#em', d).value.trim() || null, birth_date: $('#bd', d).value || null, notes: $('#nt', d).value.trim() || null, marketing_opt_in: $('#mk', d).checked, is_active: $('#ac', d).checked };
    if (row.full_name.length < 2) return void ($('#e', d).textContent = 'Informe o nome.');
    try { c ? await api.update('customers', 'id=eq.' + c.id, row) : await api.insert('customers', [row]); d.close(); toast('Cliente salvo.', 'success'); viewClientes(); }
    catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

// ====================== SERVIÇOS ======================
async function viewServicos() {
  S.services = await api.select('services', 'select=*&order=sort_order').catch(() => S.services);
  view().innerHTML = `<div class="row" style="justify-content:space-between;align-items:center"><h2 style="margin:0">Serviços</h2><button class="btn" id="adds">+ Novo serviço</button></div>
    <p class="hint">Alterar um preço aqui vale para os próximos agendamentos. Agendamentos já feitos mantêm o preço que tinham.</p>
    <div class="grid" style="grid-template-columns:1fr">${S.services.map((s) => `<div class="card svc"><div><b>${esc(s.name)}</b> ${s.is_active ? '' : '<span class="badge bad">desativado</span>'}<br><span class="muted">${durText(s.duration_min)} · ${s.is_variable_price ? 'a partir de ' : ''}${brl(s.price)}${s.includes_cut ? ' · inclui corte' : ''}</span></div><button class="btn small ghost" data-s="${s.id}">Editar</button></div>`).join('')}</div>`;
  $$('[data-s]').forEach((b) => b.onclick = () => serviceForm(S.services.find((x) => x.id === b.dataset.s)));
  $('#adds').onclick = () => serviceForm(null);
}
function serviceForm(s) {
  const d = modal(`<form method="dialog" id="sf"><h2>${s ? 'Editar serviço' : 'Novo serviço'}</h2>${field('nm', 'Nome', `value="${esc(s?.name || '')}"`)}${field('ds', 'Descrição (opcional)', `value="${esc(s?.description || '')}"`)}
    <div class="row"><div style="flex:1">${field('du', 'Duração (minutos)', `type="number" min="1" value="${s?.duration_min || 30}"`)}</div><div style="flex:1">${field('pr', 'Preço (R$)', `type="number" step="0.01" min="0" value="${s ? Number(s.price).toFixed(2) : ''}"`)}</div></div>
    ${field('so', 'Ordem na lista', `type="number" value="${s?.sort_order ?? S.services.length + 1}"`)}
    <label class="check"><input type="checkbox" id="vp" ${s?.is_variable_price ? 'checked' : ''}> Preço variável (mostra "a partir de")</label>
    <label class="check"><input type="checkbox" id="ic" ${s?.includes_cut ? 'checked' : ''}> Já inclui o corte (não combina com "Corte")</label>
    <label class="check"><input type="checkbox" id="cu" ${s?.is_cut ? 'checked' : ''}> É o serviço "Corte" simples</label>
    <label class="check"><input type="checkbox" id="ac" ${s && !s.is_active ? '' : 'checked'}> Disponível para agendamento</label><p class="err" id="e"></p>
    <div class="row end"><button class="btn ghost" data-close>Voltar</button><button class="btn" value="ok">Salvar</button></div></form>`);
  $('#sf', d).onsubmit = async (e) => {
    e.preventDefault();
    const row = { name: $('#nm', d).value.trim(), description: $('#ds', d).value.trim() || null, duration_min: parseInt($('#du', d).value, 10), price: Number($('#pr', d).value), sort_order: parseInt($('#so', d).value, 10) || 0,
      is_variable_price: $('#vp', d).checked, includes_cut: $('#ic', d).checked, is_cut: $('#cu', d).checked, is_active: $('#ac', d).checked };
    if (row.name.length < 2) return void ($('#e', d).textContent = 'Informe o nome.');
    if (!(row.duration_min > 0)) return void ($('#e', d).textContent = 'A duração precisa ser maior que zero.');
    if (!(row.price >= 0)) return void ($('#e', d).textContent = 'Informe um preço válido.');
    try { s ? await api.update('services', 'id=eq.' + s.id, row) : await api.insert('services', [row]); d.close(); toast('Serviço salvo.', 'success'); viewServicos(); }
    catch (ex) { $('#e', d).textContent = ex.message; }
  };
}

// ====================== HORÁRIOS E AJUSTES ======================
async function viewHorarios() {
  const [hours, st, blocks] = await Promise.all([api.select('business_hours', 'select=*&order=weekday'), api.select('settings', 'select=key,value'),
    api.select('availability_blocks', `select=*&end_at=gt.${encodeURIComponent(new Date().toISOString())}&order=start_at`)]);
  const cfg = Object.fromEntries(st.map((r) => [r.key, typeof r.value === 'string' ? r.value : JSON.stringify(r.value)]));
  const t = (x) => (x ? String(x).slice(0, 5) : '');
  const order = [2, 3, 4, 5, 6, 0, 1];
  view().innerHTML = `<h2>Horário de funcionamento</h2><div class="card"><div class="tbl-scroll"><table class="t"><tbody>${order.map((n) => { const h = hours.find((x) => x.weekday === n); return h ? `<tr><th scope="row">${['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'][n]}</th><td><label class="check" style="margin:0"><input type="checkbox" data-o="${n}" ${h.is_open ? 'checked' : ''}> Aberto</label></td><td><input type="time" data-a="${n}" value="${t(h.open_time)}" style="width:120px"></td><td><input type="time" data-f="${n}" value="${t(h.close_time)}" style="width:120px"></td></tr>` : ''; }).join('')}</tbody></table></div>
    <div class="row" style="margin-top:10px"><div style="flex:1">${field('l1', 'Intervalo (almoço) começa', `type="time" value="${esc(cfg.lunch_start || '13:30')}"`)}</div><div style="flex:1">${field('l2', 'Intervalo termina', `type="time" value="${esc(cfg.lunch_end || '15:00')}"`)}</div></div>
    <p class="hint">O intervalo vale para todos os dias abertos e ninguém consegue agendar nele (você ainda pode encaixar manualmente).</p><button class="btn" id="sv-h">Salvar horários</button></div>
    <h2 style="margin-top:28px">Regras do agendamento</h2><div class="card"><label for="ac">Confirmação dos agendamentos online</label><select id="ac"><option value="true" ${cfg.auto_confirm !== 'false' ? 'selected' : ''}>Automática (já nasce confirmado)</option><option value="false" ${cfg.auto_confirm === 'false' ? 'selected' : ''}>Manual (você aprova cada um)</option></select>
    ${field('cl', 'Cliente pode cancelar sozinho até (horas antes)', `type="number" min="0" value="${esc(cfg.cancel_limit_hours || '2')}"`)}${field('bw', 'Agenda aberta para até (dias à frente)', `type="number" min="1" max="365" value="${esc(cfg.booking_window_days || '60')}"`)}
    ${field('lt', 'Tolerância de atraso (minutos)', `type="number" min="0" value="${esc(cfg.late_tolerance_min || '15')}"`)}<button class="btn" id="sv-r" style="margin-top:12px">Salvar regras</button></div>
    <h2 style="margin-top:28px">Dados da barbearia</h2><div class="card">${field('sw', 'WhatsApp (com 55 e DDD)', `value="${esc(cfg.shop_whatsapp || '')}"`)}${field('sa', 'Endereço', `value="${esc(cfg.shop_address || '')}"`)}${field('si', 'Link do Instagram', `value="${esc(cfg.shop_instagram || '')}"`)}<button class="btn" id="sv-d" style="margin-top:12px">Salvar dados</button></div>
    <h2 style="margin-top:28px">Bloqueios futuros</h2>${blocks.length ? blocks.map((b) => `<div class="notice">🔒 ${esc(fmtDate(b.start_at))} ${fmtTime(b.start_at)} → ${esc(fmtDate(b.end_at))} ${fmtTime(b.end_at)} ${b.reason ? '· ' + esc(b.reason) : ''} <button class="btn small ghost" data-rb="${b.id}">Remover</button></div>`).join('') : '<p class="muted">Nenhum bloqueio.</p>'}<p><button class="btn small" id="nb">+ Bloquear horário</button></p>`;
  const setKey = (key, val) => api.update('settings', 'key=eq.' + key, { value: String(val), updated_at: new Date().toISOString() });
  $('#sv-h').onclick = () => guard(async () => {
    for (const n of order) await api.update('business_hours', 'weekday=eq.' + n, { is_open: $(`[data-o="${n}"]`).checked, open_time: $(`[data-a="${n}"]`).value || null, close_time: $(`[data-f="${n}"]`).value || null });
    await setKey('lunch_start', $('#l1').value); await setKey('lunch_end', $('#l2').value); toast('Horários salvos.', 'success');
  });
  $('#sv-r').onclick = () => guard(async () => { await setKey('auto_confirm', $('#ac').value); await setKey('cancel_limit_hours', parseInt($('#cl').value, 10) || 0); await setKey('booking_window_days', parseInt($('#bw').value, 10) || 60); await setKey('late_tolerance_min', parseInt($('#lt').value, 10) || 0); toast('Regras salvas.', 'success'); });
  $('#sv-d').onclick = () => guard(async () => { await setKey('shop_whatsapp', onlyDigits($('#sw').value)); await setKey('shop_address', $('#sa').value.trim()); await setKey('shop_instagram', $('#si').value.trim()); toast('Dados salvos.', 'success'); });
  $$('[data-rb]').forEach((b) => b.onclick = () => guard(async () => { await api.remove('availability_blocks', 'id=eq.' + b.dataset.rb); viewHorarios(); }));
  $('#nb').onclick = () => blockTime();
}

// ====================== AVISOS ======================
async function viewAvisos() {
  view().innerHTML = '<p class="loading"><span class="spin"></span>Carregando…</p>';
  const rows = await api.select('notifications', 'select=*&order=created_at.desc&limit=60').catch(() => []);
  view().innerHTML = `<div class="row" style="justify-content:space-between;align-items:center"><h2 style="margin:0">Avisos</h2>${rows.some((n) => !n.read_at) ? '<button class="btn small ghost" id="ra">Marcar todos como lidos</button>' : ''}</div>` +
    (rows.length ? rows.map((n) => `<div class="card" style="margin:8px 0;${n.read_at ? 'opacity:.7' : 'border-color:var(--orange)'}"><b>${esc(n.title)}</b><br><span class="muted">${esc(n.body || '')}</span><br><span class="hint">${esc(fmtDate(n.created_at))} ${fmtTime(n.created_at)}</span></div>`).join('') : '<p class="empty">Nenhum aviso.</p>');
  $('#ra')?.addEventListener('click', () => guard(async () => { await api.rpc('mark_all_notifications_read'); viewAvisos(); }));
}

init(); // começa só depois de tudo estar definido
