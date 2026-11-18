# Registro de uso de IA — HeatSafe Infraestrutura Linux (Operating Systems)

Este arquivo registra o apoio de IA (Claude, da Anthropic) usado como copiloto nesta disciplina. Todo o conteúdo foi executado, testado e validado na VM pelo integrante responsável, que sabe explicar cada script.

## Prompt inicial

> "Preciso fazer um trabalho (Global Solution) de Operating Systems [...]" — com os slides do professor (conceito, objetivo, entregáveis, percurso da equipe e pontuação) e os arquivos do grupo (PROPOSTA.md, documento da solução escolhida, entrevistas e dados do INMET).

Pedido: criar a infraestrutura Linux do HeatSafe com Shell Script — provisionamento de rede/DNS/IP, provisionamento da aplicação, monitoramento de CPU/disco/memória com alertas, monitoramento como serviço tolerante a falhas, logs de auditoria e teste de falha — seguindo o "Briefing 6 — Operating Systems" do documento do grupo.

## Prompts seguintes (resumo)

1. Passo a passo para criar a VM (VirtualBox + Ubuntu Server 24.04) e acessar por SSH.
2. Adaptação dos scripts aos repositórios reais do grupo: a IA leu os repositórios [HeatSafe-Backend](https://github.com/GustavooHM/HeatSafe-Backend) e [GS-HeatSafe-SOA](https://github.com/3ESPG/GS-HeatSafe-SOA) e ajustou o provisionamento para .NET 10 + Java 21/Spring Boot + MySQL, configurando tudo por variáveis de ambiente, sem alterar o código dos colegas.
3. Diagnóstico de problemas encontrados ao executar na VM (a cada erro, foi enviado o print do terminal).

## Problemas reais encontrados nos testes e como foram resolvidos

| Problema observado na VM | Causa | Correção |
|---|---|---|
| Leitura de CPU subindo devagar (média desde o início) | variável atualizada dentro de um subshell `$(...)` | função `medir_cpu` sem subshell |
| `apt` parado em silêncio após o 1º boot | atualizações automáticas do Ubuntu segurando o lock do dpkg | `esperar_apt` com mensagem de espera |
| Healthcheck sem próxima execução após um boot lento | timer com `OnBootSec`/`OnUnitActiveSec` perde o agendamento | timer por relógio: `OnCalendar=*-*-* *:*:00` |
| Teste de CPU sem alerta | `stress-ng` com prioridade maior que a do monitor | carga com `nice -n 19` |
| VM muito lenta, "soft lockup" | VirtualBox rodando sobre o Hyper-V (modo NEM: "fall back to NEM" no VBox.log) por causa da Integridade da Memória do Windows | desativar Integridade da Memória + `bcdedit /set hypervisorlaunchtype off` (com BitLocker suspenso por 1 reinício) |
| Serviço de previsão era Java, não Python | suposição inicial errada | `provision_app.sh` reescrito após ler o código do grupo |

## Responsabilidade

O integrante executou todos os scripts na VM, conferiu cada saída e coletou as evidências em `infra/evidencias/`. O conteúdo gerado com IA não substitui a compreensão: cada etapa foi explicada e verificada durante o desenvolvimento.
