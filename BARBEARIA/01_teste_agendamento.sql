-- ============================================================
-- TESTE DO AGENDAMENTO - não deixa nenhum dado no banco.
-- Cole no SQL Editor e clique em RUN.
-- O resultado aparece como uma MENSAGEM DE ERRO que começa com
-- "RESULTADO DOS TESTES". Isso é proposital: o erro final desfaz tudo
-- que o teste criou. Copie a mensagem inteira e me envie.
-- ============================================================
do $$
declare
  v_out text := '';
  v_tue date := current_date + ((2 - extract(dow from current_date)::int + 6) % 7 + 1);
  v_mon date := current_date + ((1 - extract(dow from current_date)::int + 6) % 7 + 1);
  v_corte uuid; v_luzes uuid;
  v_start timestamptz;
  v_res jsonb; v_id uuid; v_token uuid;
  v_n int;
begin
  select id into v_corte from public.services where name = 'Corte';
  select id into v_luzes from public.services where name = 'Luzes + corte';
  v_out := v_out || E'\nTeste usa terça ' || v_tue || ' e segunda ' || v_mon;

  -- 1. Segunda-feira fechada
  select count(*) into v_n from public.get_available_slots(v_mon, 30);
  v_out := v_out || E'\n1. Segunda sem horários (esperado 0): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;

  -- 2. Terça: primeiro horário 10:00 e último (30 min) 18:30
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '10:00';
  v_out := v_out || E'\n2. Terça tem horário às 10:00 (esperado 1): ' || v_n || case when v_n = 1 then '  OK' else '  FALHOU' end;
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '18:30';
  v_out := v_out || E'\n   Terça tem horário às 18:30 (esperado 1): ' || v_n || case when v_n = 1 then '  OK' else '  FALHOU' end;
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '18:35';
  v_out := v_out || E'\n   Terça NÃO tem 18:35 (esperado 0): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;

  -- 3. Almoço 13:30-15:00 bloqueado (13:00 termina 13:30 = ok; 13:05 invade; 15:00 = ok)
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') between '13:05' and '14:55';
  v_out := v_out || E'\n3. Nenhum horário começa dentro do almoço (esperado 0): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') in ('13:00','15:00');
  v_out := v_out || E'\n   13:00 e 15:00 existem (esperado 2): ' || v_n || case when v_n = 2 then '  OK' else '  FALHOU' end;

  -- 4. Serviço de 120 min não pode atravessar o almoço
  select count(*) into v_n from public.get_available_slots(v_tue, 120)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') between '11:35' and '14:55';
  v_out := v_out || E'\n4. Serviço de 2h não atravessa o almoço (esperado 0): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;

  -- 5. Reservar 10:00
  v_start := (v_tue + time '10:00') at time zone 'America/Recife';
  v_res := public.create_appointment(array[v_corte], v_start, 'Cliente TESTE', '81999990000');
  v_id := (v_res ->> 'id')::uuid; v_token := (v_res ->> 'guest_token')::uuid;
  v_out := v_out || E'\n5. Reserva criada: status=' || (v_res ->> 'status') || ' total=' || (v_res ->> 'estimated_total')
           || case when (v_res ->> 'estimated_total')::numeric = 25 then '  OK' else '  FALHOU' end;

  -- 6. Mesmo horário de novo deve ser recusado
  begin
    perform public.create_appointment(array[v_corte], v_start, 'Outro TESTE', '81999990001');
    v_out := v_out || E'\n6. Dupla reserva no mesmo horário: FALHOU (deixou reservar)';
  exception when others then
    v_out := v_out || E'\n6. Dupla reserva recusada: ' || sqlerrm || '  OK';
  end;

  -- 7. Horário sobreposto (10:15) recusado, 10:30 livre
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') in ('10:00','10:05','10:15','10:25');
  v_out := v_out || E'\n7. 10:00-10:25 ocupados (esperado 0 livres): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '10:30';
  v_out := v_out || E'\n   10:30 livre (esperado 1): ' || v_n || case when v_n = 1 then '  OK' else '  FALHOU' end;

  -- 8. Corte + Luzes+corte deve ser recusado (corte já incluso)
  begin
    perform public.create_appointment(array[v_corte, v_luzes], (v_tue + time '16:00') at time zone 'America/Recife', 'Cliente TESTE', '81999990002');
    v_out := v_out || E'\n8. Corte + Luzes+corte: FALHOU (deixou cobrar corte duas vezes)';
  exception when others then
    v_out := v_out || E'\n8. Corte duplicado recusado: ' || sqlerrm || '  OK';
  end;

  -- 9. Remarcar para 11:00 libera o 10:00
  perform public.reschedule_appointment(v_id, (v_tue + time '11:00') at time zone 'America/Recife', v_token);
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '10:00';
  v_out := v_out || E'\n9. Após remarcar, 10:00 voltou a ficar livre (esperado 1): ' || v_n || case when v_n = 1 then '  OK' else '  FALHOU' end;
  select count(*) into v_n from public.get_available_slots(v_tue, 30)
   where to_char(slot_start at time zone 'America/Recife', 'HH24:MI') = '11:00';
  v_out := v_out || E'\n   11:00 ficou ocupado (esperado 0): ' || v_n || case when v_n = 0 then '  OK' else '  FALHOU' end;

  -- 10. Token errado não cancela
  begin
    perform public.cancel_appointment(v_id, gen_random_uuid());
    v_out := v_out || E'\n10. Cancelar com código errado: FALHOU (deixou cancelar)';
  exception when others then
    v_out := v_out || E'\n10. Código errado recusado: ' || sqlerrm || '  OK';
  end;

  -- 11. Cancelar com o código certo (mais de 2h de antecedência)
  perform public.cancel_appointment(v_id, v_token);
  select count(*) into v_n from public.appointments where id = v_id and status = 'cancelled';
  v_out := v_out || E'\n11. Cancelamento com código correto (esperado 1): ' || v_n || case when v_n = 1 then '  OK' else '  FALHOU' end;

  raise exception E'RESULTADO DOS TESTES (nada foi gravado):%', v_out;
end $$;
