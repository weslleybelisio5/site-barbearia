# Auditoria técnica — Barbearia do Charley
**Data:** 13/11/2026  
**Repositório:** `main`  
**Projeto Supabase:** `maecwsusnglojqmltpcz`

## Escopo executado
- Leitura do repositório, do workflow de empacotamento e dos módulos centrais do frontend.
- Inspeção do projeto Supabase ativo, tabelas/RLS, migrações, funções privilegiadas e permissões de execução.
- Execução de verificações SQL somente de leitura e de um teste negativo de autorização dentro de transação.
- Consulta dos Security, Performance e Health Advisors do Supabase.

## Resultados confirmados
- Projeto Supabase em estado `ACTIVE_HEALTHY`, PostgreSQL 17.11.
- O frontend usa uma chave `sb_publishable_`, destinada ao cliente. Não foi encontrada chave `service_role` no arquivo público de configuração analisado.
- Teste como role `anon`: as consultas às tabelas `profiles`, `customers`, `appointments`, `cash_sessions` e `sales` retornaram zero linhas.
- Teste negativo como usuário autenticado comum: tentativa de alterar o próprio `profiles.role` para `admin` foi recusada pelo trigger `protect_profile_role` com `Sem permissao para alterar esse campo.`.
- A função `report_summary` exige `_require_admin()`; teste anterior sem sessão administrativa foi recusado com `Apenas o administrador pode fazer isso.`.
- Funções internas privilegiadas como `_add_items`, `_alert_once`, `_apply_coupon`, `_notify_admins` e `_require_admin` não concedem EXECUTE a `anon` ou `authenticated` no estado verificado.
- As seis funções privilegiadas expostas a `anon` são operações necessárias ao fluxo público de agendamento/consulta por token: criar, consultar horários, consultar agendamento por token, cancelar/remarcar com token e verificar papel administrativo. Os corpos analisados incluem validação de identidade/posse por token ou usuário, conforme o caso.

## Alertas dos Advisors
### Segurança
- 7 tabelas com RLS ativado e sem políticas: `alert_log`, `assinaturas_clientes`, `fila_espera`, `planos`, `reminders_sent`, `servicos` e `venda_itens`. Sem política, o acesso via API fica bloqueado por padrão; confirmar se são tabelas legadas/internas ou se faltam políticas de uso.
- 1 extensão instalada no schema `public`: `btree_gist`.
- Advisors reportam funções `SECURITY DEFINER` executáveis por usuários autenticados e funções públicas. A existência do alerta não prova vulnerabilidade: é necessário avaliar autorização no corpo. As rotinas administrativas inspecionadas chamam `_require_admin()`; rotinas de cliente verificam `auth.uid()` ou propriedade do registro.
- Foram reportadas políticas permissivas duplicadas em várias tabelas. Elas podem ser consolidadas depois de mapear o acesso funcional; não foram removidas para evitar alteração involuntária das regras de acesso.

### Desempenho
- Advisor reportou 38 chaves estrangeiras sem índice de cobertura. Não foram criados índices em massa: cada índice aumenta custo de escrita/armazenamento e precisa ser priorizado conforme consultas reais e plano de execução.

### Saúde
- Nenhum alerta de saúde retornado pelo Advisor na consulta realizada.

## Ações deliberadamente não executadas
- Nenhuma tabela, registro, política, função, trigger ou extensão foi alterada no banco nesta auditoria.
- Nenhuma credencial foi rotacionada, nenhum usuário foi removido e nenhuma configuração de Auth foi modificada.
- Nenhum deploy foi feito no Netlify. O workflow disponível é manual (`workflow_dispatch`) e o processo de publicação continua exigindo a etapa de upload do ZIP no Netlify.
- Não foi possível executar testes visuais em navegador real, Lighthouse, fluxo completo com sessão de administrador ou testes ponta a ponta de reserva/pagamento neste ambiente.

## Próximas ações recomendadas
1. Confirmar quais das sete tabelas sem políticas são legadas e se podem permanecer inacessíveis pela API.
2. Revisar os 49 avisos de funções privilegiadas autenticadas por função individual, incluindo todas as rotinas de administração e operações de cliente.
3. Priorizar índices FK usando consultas lentas/planos de execução, em vez de criar os 38 indiscriminadamente.
4. Revisar e consolidar políticas duplicadas após testes funcionais com contas anon, cliente e admin.
5. Rodar os testes visuais e funcionais no domínio publicado antes de promover a versão mais recente.

**Conclusão:** os testes executados confirmaram bloqueio de leitura anônima em tabelas sensíveis e bloqueio de autoelevação de privilégio no perfil. Ainda há trabalho de revisão e validação funcional; esta auditoria não certifica o sistema como livre de vulnerabilidades.


---

## Complemento da revisão — 13/11/2026 (continuação)

### Revisão adicional de permissões e funções
- Foram reconsultados os Advisors e inspecionados os corpos das funções `SECURITY DEFINER` acessíveis a `anon` e/ou `authenticated`.
- As 6 funções acessíveis a `anon` foram identificadas como parte do fluxo público: `create_appointment`, `get_available_slots`, `get_guest_appointment`, `cancel_appointment`, `reschedule_appointment` e `is_admin`.
- Nos corpos inspecionados: criação valida serviços, nome, WhatsApp, janela/horário disponível e limite de reservas; cancelamento/remarcação exigem conta proprietária ou token secreto do agendamento; consulta de reserva retorna dados apenas quando o token corresponde. `is_admin` consulta o perfil vinculado a `auth.uid()`.
- As rotinas administrativas autenticadas inspecionadas chamam `_require_admin()` ou aplicam `is_admin()` como condição de leitura. `accept_waitlist_offer` valida que o convite pertence a `auth.uid()`. Não foi encontrado caso de função administrativa autenticada sem proteção de autorização na amostra/consulta realizada.
- O schema `public` permite USAGE, mas não CREATE, para `anon` nem `authenticated`; isso reduz o risco de objetos maliciosos no `search_path` definido pelas funções.
- A lista de 49 avisos de funções SECURITY DEFINER para autenticados é um alerta amplo do Advisor, não evidência isolada de falha. As funções foram filtradas por padrões de guarda; a autorização de negócio permanece dependente dos corpos e dos testes com sessões reais.

### Acesso às tabelas
- Todas as tabelas públicas consultadas estão com RLS ativado.
- As sete tabelas sem políticas permanecem sem acesso efetivo a linhas via RLS; não foram abertas políticas genéricas para silenciar o Advisor.
- A consulta de privilégios mostra que o papel `anon` tem privilégio SQL de SELECT em várias tabelas, mas RLS continua sendo a barreira de linhas. As tabelas sensíveis verificadas anteriormente retornaram zero linhas para `anon`.
- As políticas de perfil incluem leitura/atualização própria e política administrativa; o trigger `protect_profile_role` impediu a autoelevação de papel no teste negativo anterior.

### Outros alertas atuais
- Performance Advisor: 38 FKs sem índice de cobertura e avisos de reavaliação de funções Auth em políticas RLS (otimização sugerida com `(select auth.uid())`). Também há políticas permissivas duplicadas em algumas tabelas.
- Health Advisor: nenhum alerta.
- Não foi feita alteração automática em massa de índices, políticas ou extensão: sem evidência de benefício/correção suficiente para justificar risco de regressão em produção.

### Código e publicação
- Reinspecionados os arquivos de configuração pública, fluxo de agendamento, cliente Supabase, homepage, manifesto e workflow de empacotamento.
- `config.js` contém somente URL do projeto e chave `sb_publishable_`; não há chave `service_role` nesse arquivo.
- O workflow de ZIP usa `actions/checkout@v7` e `actions/upload-artifact@v7`, com gatilho manual. O arquivo de workflow está presente e configura o ZIP a partir de `charley_build`.
- O código de agendamento público foi revisado estaticamente; não foram executados testes end-to-end reais com sessão de administrador/cliente nem teste visual em navegador nesta execução.
- Nenhuma alteração de banco ou código foi necessária com base nas verificações realizadas. Nenhuma publicação foi executada.

**Status técnico atualizado:** os controles de acesso examinados não apresentaram falha comprovada nos testes realizados. Permanecem pendentes testes reais no navegador e com contas cliente/admin, execução do workflow para gerar/validar o ZIP e conferência final no domínio antes da entrega. Não considerar este relatório uma certificação de ausência total de vulnerabilidades.
