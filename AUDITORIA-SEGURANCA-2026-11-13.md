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
