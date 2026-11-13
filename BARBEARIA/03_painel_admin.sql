-- ============================================================
-- BARBEARIA DO CHARLEY - SCRIPT 3: PAINEL DO CHARLEY (BASE)
-- Cadastro de clientes, pagamentos e acoes da agenda.
-- Rode DEPOIS dos scripts 1 e 2. Pode ser rodado de novo sem estragar nada.
-- ============================================================

-- ---------- Clientes (inclui quem nunca criou conta) ----------
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null,
  whatsapp text,
  email text,
  birth_date date,
  notes text,
  marketing_opt_in boolean not null default false,
  is_active boolean not null default true,
  is_demo boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_customers_wa on public.customers (whatsapp);
drop trigger if exists trg_customers_updated on public.customers;
create trigger trg_customers_updated before update on public.customers
  for each row execute function public.set_updated_at();

alter table public.appointments add column if not exists customer_id uuid references public.customers(id) on delete set null;
create index if not exists idx_appt_customer on public.appointments (customer_id);

-- ---------- Pagamentos ----------
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid references public.appointments(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  amount numeric(10,2) not null check (amount >= 0),
  method text not null check (method in ('pix','cash','debit','credit','other')),
  note text,
  paid_at timestamptz not null default now(),
  created_by uuid,
  is_demo boolean not null default false
);
create index if not exists idx_pay_paid_at on public.payments (paid_at);

alter table public.customers enable row level security;
alter table public.payments  enable row level security;
drop policy if exists customers_admin on public.customers;
create policy customers_admin on public.customers for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists payments_admin on public.payments;
create policy payments_admin on public.payments for all using (public.is_admin()) with check (public.is_admin());

drop trigger if exists trg_audit_customers on public.customers;
create trigger trg_audit_customers after insert or update or delete on public.customers
  for each row execute function public.audit_row();
drop trigger if exists trg_audit_payments on public.payments;
create trigger trg_audit_payments after insert or update or delete on public.payments
  for each row execute function public.audit_row();

-- ---------- Encontra ou cria o cadastro do cliente ----------
create or replace function public.ensure_customer(p_name text, p_wa text, p_profile uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; wa text := nullif(regexp_replace(coalesce(p_wa, ''), '\D', '', 'g'), '');
begin
  if p_profile is not null then
    select id into v from public.customers where profile_id = p_profile;
    if v is null and wa is not null then
      select id into v from public.customers where whatsapp = wa and profile_id is null order by created_at limit 1;
      if v is not null then update public.customers set profile_id = p_profile where id = v; end if;
    end if;
  elsif wa is not null then
    select id into v from public.customers where whatsapp = wa order by (profile_id is not null) desc, created_at limit 1;
  end if;
  if v is null then
    insert into public.customers (profile_id, full_name, whatsapp)
    values (p_profile, coalesce(nullif(trim(p_name), ''), 'Cliente'), wa) returning id into v;
  end if;
  return v;
end $$;

-- Mantem o cadastro do cliente igual ao perfil da conta
create or replace function public.sync_customer_from_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if new.role <> 'client' then return new; end if;
  v := public.ensure_customer(new.full_name, new.whatsapp, new.id);
  update public.customers set full_name = coalesce(nullif(new.full_name, ''), full_name),
         whatsapp = coalesce(nullif(new.whatsapp, ''), whatsapp), email = new.email,
         birth_date = new.birth_date, marketing_opt_in = new.marketing_opt_in
   where id = v;
  return new;
end $$;
drop trigger if exists trg_sync_customer on public.profiles;
create trigger trg_sync_customer after insert or update on public.profiles
  for each row execute function public.sync_customer_from_profile();

-- Cadastra clientes que ja existem
do $$
declare r record;
begin
  for r in select * from public.profiles where role = 'client' loop
    perform public.ensure_customer(r.full_name, r.whatsapp, r.id);
  end loop;
  update public.customers c set email = p.email, birth_date = p.birth_date, marketing_opt_in = p.marketing_opt_in
    from public.profiles p where c.profile_id = p.id;
  for r in select id, guest_name, guest_whatsapp, client_id from public.appointments where customer_id is null loop
    update public.appointments set customer_id = public.ensure_customer(r.guest_name, r.guest_whatsapp, r.client_id) where id = r.id;
  end loop;
end $$;

-- ---------- Agendamento online agora tambem cadastra o cliente ----------
create or replace function public.create_appointment(
  p_service_ids uuid[], p_start timestamptz, p_name text, p_whatsapp text,
  p_barber uuid default null, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[]; v_n int; v_dur int; v_total numeric; v_barber uuid;
  v_id uuid; v_token uuid; v_status text; v_client uuid := auth.uid();
  v_name text := nullif(trim(p_name), '');
  v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
  v_has_inc boolean; v_has_cut boolean; v_end timestamptz; v_cnt int; v_cust uuid;
begin
  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;
  if v_ids is null or array_length(v_ids, 1) is null then raise exception 'Selecione pelo menos um serviço.'; end if;

  select count(*), sum(duration_min), sum(price), bool_or(includes_cut), bool_or(is_cut)
    into v_n, v_dur, v_total, v_has_inc, v_has_cut
  from public.services where id = any(v_ids) and is_active;
  if v_n is distinct from array_length(v_ids, 1) then raise exception 'Algum serviço escolhido não está disponível.'; end if;
  if v_has_inc and v_has_cut then raise exception 'Esse serviço já inclui o corte. Remova o "Corte" da seleção.'; end if;

  if v_client is not null then
    select coalesce(v_name, full_name), case when length(v_wa) >= 10 then v_wa else whatsapp end
      into v_name, v_wa from public.profiles where id = v_client;
  end if;
  if v_name is null or length(v_name) < 2 then raise exception 'Informe seu nome.'; end if;
  if v_wa is null or length(v_wa) < 10 or length(v_wa) > 13 then raise exception 'Informe um WhatsApp válido com DDD.'; end if;

  select count(*) into v_cnt from public.appointments
   where guest_whatsapp = v_wa and status in ('pending','confirmed') and start_at > now();
  if v_cnt >= 5 then raise exception 'Você já tem muitos horários marcados. Fale com a barbearia pelo WhatsApp.'; end if;

  v_barber := coalesce(p_barber, (select id from public.barbers where is_active order by created_at limit 1));
  v_end := p_start + make_interval(mins => v_dur);

  if not exists (select 1 from public.get_available_slots((p_start at time zone 'America/Recife')::date, v_dur, v_barber) s
                 where s.slot_start = p_start) then
    raise exception 'Esse horário não está mais disponível. Escolha outro.';
  end if;

  v_status := case when public.setting_text('auto_confirm', 'true') = 'true' then 'confirmed' else 'pending' end;
  v_cust := public.ensure_customer(v_name, v_wa, v_client);

  begin
    insert into public.appointments
      (barber_id, client_id, customer_id, guest_name, guest_whatsapp, start_at, end_at, status, source, notes, estimated_total)
    values (v_barber, v_client, v_cust, v_name, v_wa, p_start, v_end, v_status, 'online', p_notes, v_total)
    returning id, guest_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'Esse horário acabou de ser reservado por outra pessoa. Escolha outro.';
  end;

  insert into public.appointment_items (appointment_id, service_id, service_name, duration_min, price_estimated, is_variable_price, sequence)
  select v_id, s.id, s.name, s.duration_min, s.price, s.is_variable_price, row_number() over (order by s.includes_cut desc, s.sort_order)
  from public.services s where s.id = any(v_ids);

  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'new_appointment',
         case when v_status = 'pending' then 'Novo agendamento para aprovar' else 'Novo agendamento' end,
         v_name || ' - ' || to_char(p_start at time zone 'America/Recife', 'DD/MM "às" HH24:MI'),
         jsonb_build_object('appointment_id', v_id)
  from public.profiles p where p.role = 'admin' and p.is_active;
  if v_client is not null then
    insert into public.notifications (user_id, type, title, body, data)
    values (v_client, 'appointment_' || v_status,
            case when v_status = 'pending' then 'Agendamento recebido' else 'Agendamento confirmado' end,
            to_char(p_start at time zone 'America/Recife', 'DD/MM "às" HH24:MI'), jsonb_build_object('appointment_id', v_id));
  end if;

  return jsonb_build_object('id', v_id, 'guest_token', v_token, 'status', v_status, 'start_at', p_start,
                            'end_at', v_end, 'estimated_total', v_total, 'duration_min', v_dur);
end $$;

-- vincular agendamento a conta tambem liga o cliente
create or replace function public.claim_appointment(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; p public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta primeiro.'; end if;
  update public.appointments set client_id = auth.uid()
   where guest_token = p_token and client_id is null returning id into v_id;
  if v_id is null then raise exception 'Não foi possível vincular este agendamento.'; end if;
  select * into p from public.profiles where id = auth.uid();
  update public.appointments set customer_id = public.ensure_customer(p.full_name, p.whatsapp, p.id) where id = v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- ============================================================
-- ACOES DO ADMINISTRADOR (todas recusam quem nao e admin)
-- ============================================================
create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas o administrador pode fazer isso.'; end if;
end $$;

create or replace function public._add_items(p_appt uuid, p_ids uuid[]) returns void
language sql security definer set search_path = public as $$
  insert into public.appointment_items (appointment_id, service_id, service_name, duration_min, price_estimated, is_variable_price, sequence)
  select p_appt, s.id, s.name, s.duration_min, s.price, s.is_variable_price, row_number() over (order by s.includes_cut desc, s.sort_order)
  from public.services s where s.id = any(p_ids);
$$;

-- Agendar manualmente (encaixe permitido: pode ser fora do horario normal, mas nunca em cima de outro cliente)
create or replace function public.admin_create_appointment(
  p_service_ids uuid[], p_start timestamptz, p_name text default null, p_whatsapp text default null,
  p_customer_id uuid default null, p_notes text default null, p_barber uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[]; v_n int; v_dur int; v_total numeric; v_barber uuid; v_id uuid; v_end timestamptz;
  v_has_inc boolean; v_has_cut boolean; v_cust uuid := p_customer_id; v_name text; v_wa text; v_profile uuid;
begin
  perform public._require_admin();
  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;
  if v_ids is null or array_length(v_ids, 1) is null then raise exception 'Selecione pelo menos um serviço.'; end if;
  select count(*), sum(duration_min), sum(price), bool_or(includes_cut), bool_or(is_cut)
    into v_n, v_dur, v_total, v_has_inc, v_has_cut from public.services where id = any(v_ids) and is_active;
  if v_n is distinct from array_length(v_ids, 1) then raise exception 'Algum serviço escolhido não está disponível.'; end if;
  if v_has_inc and v_has_cut then raise exception 'Esse serviço já inclui o corte. Remova o "Corte" da seleção.'; end if;

  if v_cust is not null then
    select full_name, whatsapp, profile_id into v_name, v_wa, v_profile from public.customers where id = v_cust;
    if v_name is null then raise exception 'Cliente não encontrado.'; end if;
  else
    v_name := nullif(trim(p_name), '');
    v_wa := nullif(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), '');
    if v_name is null then raise exception 'Informe o nome do cliente.'; end if;
    v_cust := public.ensure_customer(v_name, v_wa, null);
    select profile_id into v_profile from public.customers where id = v_cust;
  end if;

  v_barber := coalesce(p_barber, (select id from public.barbers where is_active order by created_at limit 1));
  v_end := p_start + make_interval(mins => v_dur);
  begin
    insert into public.appointments (barber_id, client_id, customer_id, guest_name, guest_whatsapp, start_at, end_at, status, source, notes, estimated_total)
    values (v_barber, v_profile, v_cust, v_name, v_wa, p_start, v_end, 'confirmed', 'admin', p_notes, v_total) returning id into v_id;
  exception when exclusion_violation then
    raise exception 'Esse horário já está ocupado por outro agendamento.';
  end;
  perform public._add_items(v_id, v_ids);
  if v_profile is not null then
    insert into public.notifications (user_id, type, title, body, data)
    values (v_profile, 'appointment_confirmed', 'Agendamento confirmado',
            to_char(p_start at time zone 'America/Recife', 'DD/MM "às" HH24:MI'), jsonb_build_object('appointment_id', v_id));
  end if;
  return jsonb_build_object('id', v_id, 'start_at', p_start, 'end_at', v_end, 'estimated_total', v_total);
end $$;

-- Confirmar, cancelar ou marcar falta
create or replace function public.admin_set_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype;
begin
  perform public._require_admin();
  if p_status not in ('confirmed','cancelled','no_show') then raise exception 'Status inválido.'; end if;
  select * into a from public.appointments where id = p_id for update;
  if not found then raise exception 'Agendamento não encontrado.'; end if;
  if a.status not in ('pending','confirmed') then raise exception 'Este agendamento já foi finalizado.'; end if;
  if p_status = 'confirmed' and a.status <> 'pending' then raise exception 'Este agendamento já está confirmado.'; end if;
  update public.appointments set status = p_status where id = p_id;
  if a.client_id is not null and p_status in ('confirmed','cancelled') then
    insert into public.notifications (user_id, type, title, body, data)
    values (a.client_id, 'appointment_' || p_status,
            case when p_status = 'confirmed' then 'Agendamento confirmado' else 'Agendamento cancelado pela barbearia' end,
            to_char(a.start_at at time zone 'America/Recife', 'DD/MM "às" HH24:MI'), jsonb_build_object('appointment_id', p_id));
  end if;
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

-- Concluir atendimento: valor final de cada servico, desconto e forma de pagamento
create or replace function public.complete_appointment(
  p_id uuid, p_prices jsonb default '{}'::jsonb, p_method text default 'cash', p_discount numeric default 0, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype; it record; v_price numeric; v_sub numeric := 0; v_final numeric;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select * into a from public.appointments where id = p_id for update;
  if not found then raise exception 'Agendamento não encontrado.'; end if;
  if a.status not in ('pending','confirmed') then raise exception 'Este agendamento já foi finalizado.'; end if;
  for it in select * from public.appointment_items where appointment_id = p_id loop
    v_price := coalesce((p_prices ->> it.id::text)::numeric, it.price_estimated);
    if v_price < 0 then raise exception 'O valor não pode ser negativo.'; end if;
    update public.appointment_items set price_final = v_price where id = it.id;
    v_sub := v_sub + v_price;
  end loop;
  if coalesce(p_discount, 0) < 0 or coalesce(p_discount, 0) > v_sub then raise exception 'Desconto inválido.'; end if;
  v_final := v_sub - coalesce(p_discount, 0);
  update public.appointments set status = 'completed', final_total = v_final where id = p_id;
  if v_final > 0 then
    insert into public.payments (appointment_id, customer_id, amount, method, note, created_by)
    values (p_id, a.customer_id, v_final, p_method, p_note, auth.uid());
  end if;
  return jsonb_build_object('id', p_id, 'final_total', v_final);
end $$;

-- Atendimento sem hora marcada (cliente que chegou e foi atendido na hora)
create or replace function public.admin_walkin(
  p_service_ids uuid[], p_name text default null, p_whatsapp text default null, p_customer_id uuid default null,
  p_prices jsonb default '{}'::jsonb, p_method text default 'cash', p_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[]; v_n int; v_dur int; v_barber uuid; v_id uuid; v_cust uuid := p_customer_id; v_name text; v_wa text; v_profile uuid;
  s record; v_price numeric; v_sub numeric := 0; v_final numeric; v_total numeric;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;
  if v_ids is null or array_length(v_ids, 1) is null then raise exception 'Selecione pelo menos um serviço.'; end if;
  select count(*), sum(duration_min), sum(price) into v_n, v_dur, v_total from public.services where id = any(v_ids);
  if v_n is distinct from array_length(v_ids, 1) then raise exception 'Algum serviço escolhido não existe.'; end if;
  if v_cust is not null then
    select full_name, whatsapp, profile_id into v_name, v_wa, v_profile from public.customers where id = v_cust;
  else
    v_name := coalesce(nullif(trim(p_name), ''), 'Cliente avulso');
    v_wa := nullif(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), '');
    if v_wa is not null then v_cust := public.ensure_customer(v_name, v_wa, null);
      select profile_id into v_profile from public.customers where id = v_cust; end if;
  end if;
  v_barber := (select id from public.barbers where is_active order by created_at limit 1);
  insert into public.appointments (barber_id, client_id, customer_id, guest_name, guest_whatsapp, start_at, end_at, status, source, estimated_total)
  values (v_barber, v_profile, v_cust, v_name, v_wa, now(), now() + make_interval(mins => v_dur), 'completed', 'walk_in', v_total)
  returning id into v_id;
  perform public._add_items(v_id, v_ids);
  for s in select * from public.appointment_items where appointment_id = v_id loop
    v_price := coalesce((p_prices ->> s.service_id::text)::numeric, s.price_estimated);
    if v_price < 0 then raise exception 'O valor não pode ser negativo.'; end if;
    update public.appointment_items set price_final = v_price where id = s.id;
    v_sub := v_sub + v_price;
  end loop;
  if coalesce(p_discount, 0) < 0 or coalesce(p_discount, 0) > v_sub then raise exception 'Desconto inválido.'; end if;
  v_final := v_sub - coalesce(p_discount, 0);
  update public.appointments set final_total = v_final where id = v_id;
  if v_final > 0 then
    insert into public.payments (appointment_id, customer_id, amount, method, created_by) values (v_id, v_cust, v_final, p_method, auth.uid());
  end if;
  return jsonb_build_object('id', v_id, 'final_total', v_final);
end $$;
