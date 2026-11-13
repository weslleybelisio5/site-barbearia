-- ============================================================
-- BARBEARIA DO CHARLEY - SCRIPT 2: AREA DO CLIENTE
-- Lista de espera, notificacoes, vinculo de agendamento a conta e lembretes.
-- Rode DEPOIS do script 1. Pode ser rodado de novo sem estragar nada.
-- ============================================================

-- ---------- Preferencia de contato (aceite para novidades por WhatsApp) ----------
alter table public.profiles add column if not exists marketing_opt_in boolean not null default false;

-- ---------- Lista de espera ----------
create table if not exists public.waitlist (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  service_ids uuid[] not null,
  desired_date date not null,
  from_time time not null default '10:00',
  to_time time not null default '20:00',
  status text not null default 'active'
    check (status in ('active','notified','booked','cancelled','expired')),
  notified_at timestamptz,
  created_at timestamptz not null default now(),
  check (to_time > from_time)
);
create index if not exists idx_waitlist_date on public.waitlist (desired_date, status);

alter table public.waitlist enable row level security;
drop policy if exists waitlist_read on public.waitlist;
create policy waitlist_read on public.waitlist for select using (client_id = auth.uid() or public.is_admin());
drop policy if exists waitlist_admin on public.waitlist;
create policy waitlist_admin on public.waitlist for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.join_waitlist(
  p_service_ids uuid[], p_date date, p_from time default '10:00', p_to time default '20:00'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'America/Recife')::date;
  v_n int; v_id uuid;
begin
  if v_uid is null then raise exception 'Entre na sua conta para usar a lista de espera.'; end if;
  if p_date is null or p_date < v_today or p_date > v_today + public.setting_int('booking_window_days', 60) then
    raise exception 'Escolha uma data válida.';
  end if;
  if p_to <= p_from then raise exception 'O horário final precisa ser depois do inicial.'; end if;
  select count(*) into v_n from public.services where id = any(p_service_ids) and is_active;
  if p_service_ids is null or v_n is distinct from array_length(p_service_ids, 1) then
    raise exception 'Escolha serviços válidos.';
  end if;
  select count(*) into v_n from public.waitlist where client_id = v_uid and status = 'active';
  if v_n >= 5 then raise exception 'Você já tem 5 pedidos ativos na lista de espera.'; end if;
  insert into public.waitlist (client_id, service_ids, desired_date, from_time, to_time)
  values (v_uid, p_service_ids, p_date, p_from, p_to) returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.cancel_waitlist(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.waitlist set status = 'cancelled'
   where id = p_id and client_id = auth.uid() and status in ('active','notified');
  if not found then raise exception 'Pedido não encontrado.'; end if;
end $$;

-- Quando um horario vaga (cancelamento ou remarcacao), avisa quem esta na lista de espera
create or replace function public.notify_waitlist() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date; t_s time; t_e time; w record;
begin
  if old.status in ('pending','confirmed') and old.start_at > now()
     and (new.status = 'cancelled' or new.start_at <> old.start_at) then
    d   := (old.start_at at time zone 'America/Recife')::date;
    t_s := (old.start_at at time zone 'America/Recife')::time;
    t_e := (old.end_at   at time zone 'America/Recife')::time;
    for w in select * from public.waitlist
             where status = 'active' and desired_date = d and from_time < t_e and to_time > t_s
               and client_id is distinct from old.client_id loop
      insert into public.notifications (user_id, type, title, body, data)
      values (w.client_id, 'waitlist_slot', 'Abriu um horário!',
              'Vagou um horário no dia ' || to_char(d, 'DD/MM') || '. Entre no site e agende antes que outra pessoa pegue.',
              jsonb_build_object('date', d, 'waitlist_id', w.id));
      update public.waitlist set status = 'notified', notified_at = now() where id = w.id;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_waitlist on public.appointments;
create trigger trg_notify_waitlist after update on public.appointments
  for each row execute function public.notify_waitlist();

-- ---------- Notificacoes: cliente so marca como lida (nao edita o texto) ----------
drop policy if exists notif_update on public.notifications;

create or replace function public.mark_notification_read(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update public.notifications set read_at = now() where id = p_id and user_id = auth.uid() and read_at is null;
$$;
create or replace function public.mark_all_notifications_read() returns void
language sql security definer set search_path = public as $$
  update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

-- ---------- Vincular um agendamento feito sem conta a minha conta (usa o codigo secreto) ----------
create or replace function public.claim_appointment(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta primeiro.'; end if;
  update public.appointments set client_id = auth.uid()
   where guest_token = p_token and client_id is null returning id into v_id;
  if v_id is null then raise exception 'Não foi possível vincular este agendamento.'; end if;
  return jsonb_build_object('id', v_id);
end $$;

-- ---------- Lembretes automaticos (24h e 2h antes) ----------
create table if not exists public.reminders_sent (
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  kind text not null,
  sent_at timestamptz not null default now(),
  primary key (appointment_id, kind)
);
alter table public.reminders_sent enable row level security;  -- sem politicas = ninguem acessa direto

create or replace function public.send_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare a record; k text; n int := 0;
begin
  for a in select * from public.appointments
           where status in ('pending','confirmed') and client_id is not null
             and start_at > now() and start_at <= now() + interval '24 hours' loop
    foreach k in array array['24h','2h'] loop
      if (k = '24h' and a.start_at > now() + interval '2 hours')
         or (k = '2h' and a.start_at <= now() + interval '2 hours') then
        begin
          insert into public.reminders_sent (appointment_id, kind) values (a.id, k);
          insert into public.notifications (user_id, type, title, body, data)
          values (a.client_id, 'reminder_' || k,
                  case when k = '24h' then 'Lembrete: seu horário é amanhã' else 'Lembrete: seu horário é daqui a pouco' end,
                  to_char(a.start_at at time zone 'America/Recife', 'DD/MM "às" HH24:MI'),
                  jsonb_build_object('appointment_id', a.id));
          n := n + 1;
        exception when unique_violation then null;  -- ja enviado
        end;
      end if;
    end loop;
  end loop;
  return n;
end $$;

-- Agenda a execucao a cada 15 minutos (se o recurso pg_cron estiver disponivel no seu projeto)
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'AVISO: nao foi possivel ativar o pg_cron automaticamente (%). Ative em Database > Extensions e rode este script de novo.', sqlerrm;
  end;
  begin
    perform cron.schedule('lembretes-barbearia', '*/15 * * * *', 'select public.send_reminders()');
    raise notice 'OK: lembretes agendados a cada 15 minutos.';
  exception when others then
    raise notice 'AVISO: lembretes automaticos NAO foram agendados (%).', sqlerrm;
  end;
end $$;
