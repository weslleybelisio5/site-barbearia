-- PATCH V6 — Barbearia do Charley
-- Execute UMA ÚNICA VEZ no Supabase > SQL Editor.
-- Não apaga dados existentes. Adiciona funções necessárias à nova interface.

begin;

-- Metas com mais contexto, sem remover as colunas originais.
alter table public.goals add column if not exists title text;
alter table public.goals add column if not exists description text;
alter table public.goals add column if not exists responsible text;
alter table public.goals add column if not exists start_date date;
alter table public.goals add column if not exists end_date date;

-- Criar assinatura pelo painel administrativo, vinculando cliente + plano.
create or replace function public.admin_create_subscription(
  p_customer uuid,
  p_plan uuid,
  p_activate boolean default false,
  p_method text default 'pix',
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.customers%rowtype;
  pl public.plans%rowtype;
  v_count int;
  v_sub uuid;
  v_cycle jsonb;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then
    raise exception 'Forma de pagamento inválida.';
  end if;
  select * into c from public.customers where id = p_customer and is_active for update;
  if not found then raise exception 'Cliente não encontrado ou inativo.'; end if;
  select * into pl from public.plans where id = p_plan and is_active;
  if not found then raise exception 'Plano não encontrado ou inativo.'; end if;
  if pl.max_subscribers is not null then
    select count(*) into v_count from public.subscriptions
    where plan_id = p_plan and status in ('pending','active','past_due','suspended','cancel_requested','cancelling');
    if v_count >= pl.max_subscribers then raise exception 'Este plano atingiu o limite de assinantes.'; end if;
  end if;
  insert into public.subscriptions(customer_id,plan_id,price,status,note,is_demo)
  values(p_customer,p_plan,pl.price,'pending',nullif(trim(coalesce(p_note,'')),''),c.is_demo)
  returning id into v_sub;
  insert into public.subscription_items(subscription_id,service_id,quantity)
  select v_sub,service_id,quantity from public.plan_items where plan_id=p_plan;
  if p_activate then
    v_cycle := public.admin_activate_subscription(v_sub,p_method);
  end if;
  return jsonb_build_object('id',v_sub,'status',case when p_activate then 'active' else 'pending' end,'cycle',v_cycle);
end $$;

-- Painel da lista de espera. A tabela waitlist é criada pelos scripts-base 1–3.
create or replace function public.admin_waitlist_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',w.id,'client_id',w.client_id,'full_name',p.full_name,'whatsapp',p.whatsapp,
      'service_ids',w.service_ids,'desired_date',w.desired_date,'from_time',w.from_time,
      'to_time',w.to_time,'status',w.status,'notified_at',w.notified_at,'created_at',w.created_at,
      'offer',(select jsonb_build_object('offered_start',o.offered_start,'expires_at',o.expires_at,'status',o.status)
               from public.waitlist_offers o where o.waitlist_id=w.id order by o.created_at desc limit 1)
    ) order by w.desired_date,w.from_time,w.created_at)
    from public.waitlist w left join public.profiles p on p.id=w.client_id
  ),'[]'::jsonb);
end $$;

create or replace function public.admin_waitlist_process_date(p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_date is null then raise exception 'Selecione uma data.'; end if;
  perform public.waitlist_expire();
  perform public.waitlist_process(p_date);
end $$;

create or replace function public.admin_waitlist_set_status(p_id uuid,p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_status not in ('active','cancelled') then raise exception 'Status inválido.'; end if;
  update public.waitlist set status=p_status, notified_at=case when p_status='active' then null else notified_at end
  where id=p_id and status in ('active','notified','cancelled');
  if not found then raise exception 'Pedido não encontrado ou não pode ser alterado.'; end if;
end $$;

-- Monta uma lista de destinatários respeitando o consentimento de marketing.
create or replace function public.admin_prepare_campaign(p_campaign uuid) returns int
language plpgsql security definer set search_path = public as $$
declare c public.campaigns%rowtype; n int;
begin
  perform public._require_admin();
  select * into c from public.campaigns where id=p_campaign for update;
  if not found then raise exception 'Campanha não encontrada.'; end if;
  if nullif(trim(coalesce(c.message,'')),'') is null then raise exception 'Cadastre a mensagem antes de preparar o público.'; end if;
  insert into public.campaign_recipients(campaign_id,customer_id,status)
  select c.id,cu.id,'prepared'
  from public.customers cu
  where cu.is_active and cu.marketing_opt_in and nullif(regexp_replace(coalesce(cu.whatsapp,''),'\D','','g'),'') is not null
    and (
      coalesce(c.segment,'all_optin')='all_optin'
      or (c.segment='new_customers' and cu.created_at >= now()-interval '30 days')
      or (c.segment='inactive_30' and exists(select 1 from public.appointments ax where ax.customer_id=cu.id and ax.status='completed')
          and not exists(select 1 from public.appointments ax where ax.customer_id=cu.id and ax.status='completed' and ax.start_at>=now()-interval '30 days'))
      or (c.segment='frequent' and (select count(*) from public.appointments ax where ax.customer_id=cu.id and ax.status='completed')>=3)
      or (c.segment='subscribers' and exists(select 1 from public.subscriptions su where su.customer_id=cu.id and su.status in ('active','past_due','cancel_requested','cancelling')))
    )
  on conflict(campaign_id,customer_id) do nothing;
  get diagnostics n=row_count;
  update public.campaigns set status='prepared' where id=c.id and status<>'finished';
  return n;
end $$;

-- Ação de LGPD com confirmação explícita no painel.
create or replace function public.admin_process_privacy_request(p_request uuid,p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.privacy_requests%rowtype; v_customer uuid;
begin
  perform public._require_admin();
  select * into r from public.privacy_requests where id=p_request for update;
  if not found then raise exception 'Solicitação não encontrada.'; end if;
  if r.status<>'open' then raise exception 'Esta solicitação já foi processada.'; end if;
  if p_action='anonymize' then
    if r.kind<>'deletion' then raise exception 'Anonimização disponível somente para solicitações de exclusão.'; end if;
    select id into v_customer from public.customers where profile_id=r.profile_id limit 1;
    if v_customer is not null then
      perform public.admin_anonymize_customer(v_customer);
    elsif r.profile_id is not null then
      delete from auth.users where id=r.profile_id;
    end if;
    update public.privacy_requests set status='done',resolved_at=now() where id=p_request;
  elsif p_action='complete' then
    update public.privacy_requests set status='done',resolved_at=now() where id=p_request;
  elsif p_action='reject' then
    update public.privacy_requests set status='rejected',resolved_at=now() where id=p_request;
  else
    raise exception 'Ação inválida.';
  end if;
end $$;

revoke all on function public.admin_create_subscription(uuid,uuid,boolean,text,text) from public,anon;
revoke all on function public.admin_waitlist_list() from public,anon;
revoke all on function public.admin_waitlist_process_date(date) from public,anon;
revoke all on function public.admin_waitlist_set_status(uuid,text) from public,anon;
revoke all on function public.admin_prepare_campaign(uuid) from public,anon;
revoke all on function public.admin_process_privacy_request(uuid,text) from public,anon;
grant execute on function public.admin_create_subscription(uuid,uuid,boolean,text,text) to authenticated;
grant execute on function public.admin_waitlist_list() to authenticated;
grant execute on function public.admin_waitlist_process_date(date) to authenticated;
grant execute on function public.admin_waitlist_set_status(uuid,text) to authenticated;
grant execute on function public.admin_prepare_campaign(uuid) to authenticated;
grant execute on function public.admin_process_privacy_request(uuid,text) to authenticated;

commit;
