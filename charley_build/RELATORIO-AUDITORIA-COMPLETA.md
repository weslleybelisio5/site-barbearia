# Barbearia do Charley — auditoria do briefing e pacote de entrega

**Base analisada:** pacote V6 + experiência mobile (`charley_build`), briefing mestre de 11 páginas e Script 4 fornecido pelo proprietário.

**Importante:** esta é uma auditoria estática do código e dos SQLs disponíveis. Não houve acesso autenticado ao projeto Supabase/Netlify, nem execução de transações com dados reais. Portanto, “presente no código” não significa que foi validado em produção.

## Resultado executivo

- Sintaxe dos arquivos JavaScript: **OK** (`node --check` em todos os arquivos JS).
- Referências locais `src`/`href` dos HTMLs: **OK** (nenhum arquivo local referenciado ausente).
- Central de ajuda, assistente guiado, efeitos CSS leves e suporte a `prefers-reduced-motion`: **presentes**.
- Não foram adicionadas dependências, APIs de IA, automações de WhatsApp ou serviços pagos.
- Não foi feito deploy nem executado SQL nesta entrega.
- O teste real de autenticação, RLS, RPCs, concorrência de reservas, pagamentos e dados depende do Supabase conectado.

## Matriz de requisitos

Legenda: **Presente no pacote** = há implementação identificável; **Parcial / validar** = existe parte do fluxo, mas não há comprovação suficiente de todos os critérios; **Pendente / externo** = depende de implementação, configuração ou teste que não pode ser comprovado apenas pelo pacote local.

| Área do briefing | Situação | Observação objetiva |
|---|---|---|
| Identidade visual, idioma, moeda e fuso | Parcial / validar | Estrutura visual e textos estão presentes; conferir todos os horários/datas no Supabase e em produção. |
| Site público, serviços, contato, FAQ, termos e privacidade | Presente no pacote | Páginas HTML existentes; mapa/link e conteúdo final de privacidade precisam de confirmação do proprietário. |
| Catálogo público de produtos e kits | Parcial / validar | Páginas e consultas existem; confirmar publicação e políticas das views públicas. |
| Seleção de múltiplos serviços e preço/duração estimados | Parcial / validar | Fluxo de agendamento existe; testar combinações, serviços químicos e regra “luzes/platinado já incluem corte”. |
| Disponibilidade, almoço, dias fechados e bloqueios | Parcial / validar | Regras são dependentes das funções SQL e dos dados do banco; não houve teste de concorrência. |
| Calendário diário, semanal e mensal | Pendente / validar | Não foi comprovado no painel um calendário visual completo nos três modos. |
| Encaixe e atendimento presencial sem reserva | Parcial / validar | Há função de atendimento avulso no Script 4; testar vínculo com cliente, pagamento e caixa. |
| Cancelamento, remarcação, tolerância e falta | Parcial / validar | Existem páginas e RPCs no cliente; regras e permissões exigem teste integrado. |
| Área do cliente e histórico | Parcial / validar | Conta e histórico estão presentes; validar isolamento RLS por usuário. |
| Lista de espera FIFO e convite de 15 minutos | Parcial / validar | Script 4 contém fila/ofertas e processamento; depende de execução agendada para expirar convites e de testes de disputa. |
| Planos, ciclos de 30 dias e créditos | Parcial / validar | Script 4/V6 têm estrutura e RPCs; validar pagamento único, ciclo, expiração e consumo após conclusão. |
| Produtos, estoque, kits e vendas | Parcial / validar | CRUD e movimentação existem; testar baixa atômica, kit composto e venda combinada com atendimento. |
| Caixa | Parcial / validar | Interface e RPCs estão no pacote; testar abertura única, movimentos, fechamento e divergência no banco real. |
| Financeiro, despesas e contas | Parcial / validar | Despesas e relatórios existem; confirmar contas a pagar/receber, categorização e ausência de receita duplicada. |
| Metas da barbearia | Parcial / validar | Campos adicionais e progresso foram incluídos no V6; conferir fórmulas e períodos. |
| Campanhas e consentimento | Parcial / validar | Segmentação e WhatsApp individual manual; não há disparo automático em massa (intencional por custo/segurança). |
| Avaliações verificadas | Parcial / validar | RPC exige atendimento concluído e login; testar envio e aprovação no banco conectado. |
| Galeria e novidades | Presente no pacote | CRUD e publicação identificáveis; validar limites de imagem e exibição pública. |
| Tarefas internas | Presente no pacote | Cadastro e status identificáveis; alertas/avisos de atraso precisam de validação. |
| LGPD / solicitações | Parcial / validar | Formulário e gestão existem; anonimização não substitui revisão jurídica e retenção legal. |
| Autenticação, permissões e RLS | Pendente / crítico validar | O código chama funções protegidas, mas políticas de todas as tabelas e testes negativos não foram auditados integralmente. |
| Histórico/auditoria de alterações | Parcial / validar | Há registros em partes do sistema; cobertura integral das entidades exigidas não foi comprovada. |
| PWA e uso offline | Presente no pacote, parcial | Manifest, service worker e página offline existem; agendamentos e operações continuam exigindo internet. |
| SEO, Open Graph e dados estruturados | Parcial / validar | Metadados existem em parte; cobertura de todas as páginas e schema não foi confirmada. |
| Cookies e consentimento de analytics | Pendente / validar | Não foi comprovado fluxo completo de consentimento antes de analytics. |
| Backups e exportação | Parcial / validar | Exportação CSV existe em módulos; backup avançado não está incluído no escopo gratuito. Fazer exportação manual periódica. |
| Segurança de uploads, rate limiting e proteção contra abuso | Pendente / validar | Exige revisão das políticas/storage e testes no Supabase; não declarar seguro sem esses testes. |
| Testes E2E em celular/tablet/desktop | Pendente | Não foram executados testes reais de navegador/dispositivo nem E2E autenticado. |

## Pontos que ainda impedem declarar o sistema pronto para clientes reais

1. Testar login, recuperação de senha e papéis de usuário com contas separadas de cliente e administrador.
2. Revisar RLS de todas as tabelas e views; provar que um cliente não consegue ler ou alterar dados de outro.
3. Testar reserva simultânea do mesmo horário, remarcação atômica e liberação do horário anterior.
4. Testar caixa, vendas, estoque, pagamentos e créditos para garantir atomicidade e ausência de duplicidade.
5. Confirmar rotina de expiração/processamento da lista de espera e notificações internas. Sem agendador, tarefas com prazo podem não avançar sozinhas.
6. Validar configuração Auth/e-mail do Supabase, storage e limites do plano gratuito.
7. Confirmar textos finais de Termos e Privacidade, consentimentos e procedimentos de atendimento LGPD.
8. Executar testes de interface em dispositivos reais e observar erros do console/rede.
9. Confirmar o pin exato do mapa e os horários publicados.

## Dependências de scripts SQL

O pacote contém `PATCH-V6.sql`, que complementa o banco já existente. O Script 4 foi fornecido como `Texto colado.txt`, mas os scripts-base 1, 2 e 3 não fazem parte deste pacote. O código também chama RPCs que devem existir nesses scripts-base. A busca estática não encontrou definições de 11 RPCs nos dois SQLs disponíveis; isso **não prova ausência no banco**, apenas que as definições não estavam nos arquivos analisados.

**Como o proprietário informou que já executou o PATCH-V6.sql, não execute esse patch novamente.** Antes de qualquer nova migração, compare o schema atual do Supabase com o patch e faça backup/exportação manual.

## Experiência adicionada neste pacote

- `ajuda.html`: central de ajuda e tutoriais de cancelamento/remarcação.
- Assistente guiado leve: atalhos para agendar, consultar reserva, tutoriais e WhatsApp.
- Hero com profundidade CSS/SVG e motion discreto.
- Respeito a `prefers-reduced-motion`.
- Sem bibliotecas 3D pesadas, IA paga, API externa ou envio automático de WhatsApp.

O assistente é um guia de navegação: **não executa sozinho cancelamentos ou remarcações dentro do chat**. As operações continuam nos fluxos autenticados do sistema.

## Publicação

Este pacote não foi publicado. Não faça novo deploy até revisar este relatório e testar o backend; isso evita consumir créditos do Netlify em uma versão ainda não validada.


## Complemento — auditoria integrada do Supabase (13/11/2026)

Após a auditoria estática acima, o projeto Supabase `barbearia-do-charley` foi conectado e inspecionado diretamente. O banco está ativo em PostgreSQL 17. A estrutura atual contém as tabelas em inglês usadas pela versão V6, além de um conjunto legado em português. O código atual usa principalmente as tabelas em inglês; portanto, a existência das tabelas legadas não significa que seja necessário renomear ou migrar os dados.

### Correções aplicadas

- O gatilho `handle_new_user()` agora grava o perfil novo em `public.profiles` com papel fixo `client`. O trigger de sincronização existente também cria o registro correspondente em `customers`.
- RPCs `SECURITY DEFINER` tiveram execução anônima removida por padrão. Permanecem liberadas anonimamente apenas as operações públicas necessárias para consultar disponibilidade, criar/cancelar/remarcar agendamentos por token e consultar agendamento por token. RPCs administrativas exigem usuário autenticado e checagem administrativa no banco.
- `complete_appointment` recebeu a permissão autenticada necessária, mantendo a validação administrativa interna.
- Views `public_products`, `public_kits` e `public_reviews` foram configuradas como `security_invoker`.
- A role anônima pode consultar apenas os campos públicos necessários. Custo dos produtos, quantidade exata de estoque e identificador do autor da avaliação não ficam expostos. O catálogo informa apenas `in_stock`.
- Foram adicionados índices para consultas frequentes de agenda, bloqueios, movimentos de caixa, pagamentos, itens de venda, destinatários de campanha, avaliações e lista de espera.
- O JavaScript do painel foi corrigido para remover o erro de sintaxe em `viewCaixa`. Foi acrescentada a Visão geral administrativa, melhor diagnóstico de sessão e proteção contra corrida na renovação do refresh token.
- O relatório detalhado de despesas foi alinhado ao mesmo intervalo de pagamentos de despesas pagas utilizado no total do relatório.
- As metas passaram a aceitar mais indicadores e datas personalizadas.

### Validações realizadas no banco

- 2 usuários Auth e 2 perfis existentes; 1 perfil administrador ativo.
- Teste transacional do trigger de cadastro: perfil e registro de cliente foram criados corretamente para um usuário sintético; a transação foi revertida.
- Teste público: 2 produtos e 1 kit retornados pelas views; custo, quantidade exata e perfil do autor de avaliação não acessíveis à role anônima.
- Teste de permissões: role anônima sem permissão para registrar venda administrativa; RPCs administrativas disponíveis à role autenticada e protegidas pela checagem de administrador no corpo.
- Testes transacionais com identidade administrativa simulada: resumo do caixa, relatório, lista de espera, movimentação de caixa, venda, criação de assinatura e conclusão de atendimento executados sem erro. Toda escrita desses testes foi revertida com `ROLLBACK`.
- Sintaxe verificada nos 17 arquivos JavaScript de `charley_build/js/`; nenhum erro de sintaxe.

### Situação dos dados

Na leitura realizada, o banco tinha 4 agendamentos, 5 clientes, 1 sessão de caixa aberta, 5 movimentações manuais, 2 produtos, 1 kit e 1 plano ativo. Ainda não havia registros em `sales`, `payments`, `subscriptions` ou `reviews`. Por isso, módulos de vendas, pagamentos e assinaturas podem aparecer sem lançamentos reais até as primeiras operações legítimas serem registradas.

### Pendências não declaradas como concluídas

- Não houve teste E2E em navegador, nem inspeção visual do domínio Netlify publicado.
- A branch de código está em PR separado e ainda não foi incorporada à branch principal nem publicada. A configuração de deploy não está no repositório.
- Os avisos restantes do Supabase Advisor incluem 7 tabelas legadas com RLS sem políticas (acesso negado por padrão), extensão `btree_gist` em `public`, proteção de senha vazada desativada e avisos de políticas permissivas duplicadas. Esses itens requerem revisão específica; não foram removidas políticas em massa para evitar bloquear funcionalidades existentes.
- As rotinas de WhatsApp continuam manuais, conversa individual por conversa individual. Não há disparo automático nem serviço externo de mensagens.
- A validação funcional de escrita foi feita com transações revertidas; a confirmação final de fluxo real deve ser feita no domínio publicado e por operações reais do administrador, sem usar dados de clientes como teste.

