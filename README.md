# HeatSafe — Infraestrutura Linux (Operating Systems)

| | |
|---|---|
| **Instituição** | FIAP · Engenharia de Software · 3ESPG |
| **Disciplina** | Operating Systems |
| **Atividade** | Global Solution 2026.2 — CitizenTech |
| **Vídeo de demonstração** | https://youtu.be/vA0l51FNoeU (4min24) |

## Integrantes

| Nome | RM |
|---|---|
| Felipe Braunstein e Silva | RM554483 |
| Felipe do Nascimento Fernandes | RM554598 |
| Henrique Ignacio Bartalo | RM555274 |
| Gustavo Henrique Martins | RM556956 |

## Ficha da CitizenTech

| Campo | Resposta |
|---|---|
| **Nome** | HeatSafe |
| **Cidade e bairro** | São Paulo, Itaim Paulista (zona leste): casas térreas com telha de fibrocimento |
| **Cidadão beneficiado** | Idosos que moram ou passam o dia sozinhos em casas quentes; familiares e agentes comunitários de saúde da UBS |
| **Problema, em uma frase** | Nos dias de calor extremo, idosos que passam o dia sozinhos em casas quentes podem passar mal sem perceber o risco, e ninguém fica sabendo a tempo. |
| **Como funciona** | Um ESP32 dentro da casa mede o calor e o movimento; a API central recalcula o índice de calor, classifica o risco, avisa a família e, sem confirmação em 20 minutos, coloca a casa na lista de visitas da UBS. Na véspera de um dia perigoso, consulta o serviço de previsão e liga o modo vigilância. **Este repositório** é o servidor Linux que hospeda a API e o serviço de previsão. |
| **Indicador de impacto** | Tempo entre o alerta e a confirmação da família · % de alertas confirmados em até 30 min · visitas priorizadas pela UBS |
| **O que cada parte faz** | **App Expo (Mobile):** família e agente da UBS acompanham alertas e confirmam visitas · **ESP32 no Wokwi (IoT/IoB):** mede o calor e o movimento dentro da casa e registra a água bebida · **API C# (.NET):** cadastros, leituras, alertas e escalonamento para a UBS · **Serviço SOA (Java/Spring):** previsão do dia perigoso para a API · **ML:** modelo Random Forest com dados do INMET que prevê o dia perigoso · **Cybersecurity:** SentinelaSAST audita o código para os dados de saúde e rotina não vazarem · **Operating Systems:** infraestrutura Linux que hospeda a solução · **Testing:** features e casos de teste no Azure Boards |
| **Links dos repositórios** | **Este (Linux)** · [API C#](https://github.com/GustavooHM/HeatSafe-Backend) · [SOA](https://github.com/3ESPG/GS-HeatSafe-SOA) · [Mobile](https://github.com/3ESPG/GS-HeatSafe-mobile) · [IA/ML](https://github.com/3ESPG/2GS_IA_ML) · [IoT](https://github.com/3ESPG/2GS_IoT_IoB) |
| **ODS** | 3 (Saúde) · 10 (Redução das desigualdades) · 11 (Cidades sustentáveis) · 13 (Ação climática) |

## O que este repositório entrega

Uma VM **Ubuntu Server 24.04** "zerada" vira o servidor **`heatsafe-srv`** com **um único comando**, 100% em Shell Script:

```bash
git clone <este repositório> && cd <pasta>
sudo bash infra/provision.sh
```

O script provisiona a **infra** (IP fixo, DNS local, hostname, firewall, usuário de serviço, auditoria), baixa e compila a **aplicação do grupo** direto dos repositórios no GitHub (API C# .NET 10 e serviço de previsão Java 21 + MySQL), sobe tudo como **serviços systemd** atrás do **nginx**, e liga um **monitor de CPU, memória e disco** que também roda como serviço, vigiado por um timer de autocorreção.

```
  navegador / app / ESP32 ──► http://api.heatsafe.local ──┐
                                                          ▼
 ┌──────────── VM Ubuntu 24.04 · heatsafe-srv · 10.0.2.15 ────────────┐
 │ ufw: entra só 22 (SSH, com limite) e 80 (HTTP)                      │
 │ nginx :80 ─┬─ api.heatsafe.local      ─► heatsafe-api      :5000   │
 │            ├─ previsao.heatsafe.local ─► heatsafe-previsao :8000   │
 │            └─ heatsafe.local          ─► página de status          │
 │ heatsafe-previsao ─► MySQL :3306 (só local)                          │
 │ heatsafe-monitor (a cada 15 s) + heatsafe-healthcheck.timer (1 min) │
 │ auditd + /var/log/heatsafe/*.log  (auditoria e execução)            │
 └─────────────────────────────────────────────────────────────────────┘
```

Documentação técnica completa: **[infra/README.md](infra/README.md)** · Roteiro do vídeo: **[infra/ROTEIRO_VIDEO.md](infra/ROTEIRO_VIDEO.md)**

## Critérios de avaliação e onde estão

| Critério | Pts | Onde | Evidência (VM real, 17/11/2026) |
|---|---|---|---|
| Provisionamento de infra (redes, DNS, IP) | 2 | [`provision_infra.sh`](infra/scripts/provision_infra.sh) | [02-rede](infra/evidencias/20261117-162736/02-rede.txt): IP fixo `10.0.2.15/24` via netplan · [03-dns-local](infra/evidencias/20261117-162736/03-dns-local.txt): `api.heatsafe.local` → `10.0.2.15` · [04-firewall](infra/evidencias/20261117-162736/04-firewall.txt) |
| Provisionamento da aplicação (dependências, configurações, orquestração) | 2 | [`provision_app.sh`](infra/scripts/provision_app.sh) | [log-provision_app](infra/evidencias/20261117-162736/log-provision_app.log): clona 2 repos, instala .NET 10, Java 21 e MySQL, gera `.env` por serviço, compila e sobe via systemd + nginx |
| Monitoramento de infra com alertas de CPU, disco e memória | 2 | [`monitor.sh`](infra/scripts/monitor.sh) | [log-alertas](infra/evidencias/20261117-162736/log-alertas.log): CPU 100% → CRITICO → RESOLVIDO · disco 93% → CRITICO → RESOLVIDO · memória 92% → CRITICO → RESOLVIDO |
| Monitoramento como serviço tolerante a falhas | 1 | [`heatsafe-monitor.service`](infra/systemd/heatsafe-monitor.service), [`healthcheck.sh`](infra/scripts/healthcheck.sh) + [timer](infra/systemd/heatsafe-healthcheck.timer) | [log-healthcheck](infra/evidencias/20261117-162736/log-healthcheck.log): monitor congelado (SIGSTOP) → `TRAVADO` → `AUTOCORRECAO` → PID novo |
| Logs de auditoria e execução dos scripts | 1 | [`lib/common.sh`](infra/scripts/lib/common.sh), [`evento_servico.sh`](infra/scripts/hooks/evento_servico.sh), regras do auditd | [log-auditoria](infra/evidencias/20261117-162736/log-auditoria.log): usuário real, script, etapa e resultado · [08-auditd](infra/evidencias/20261117-162736/08-auditd.txt): `syscall=kill a1=SIGKILL auid=henrique` |
| Funcionamento completo da proposta | 2 | [`teste_ponta_a_ponta.sh`](infra/scripts/teste_ponta_a_ponta.sh) | [log-teste_ponta_a_ponta](infra/evidencias/20261117-162736/log-teste_ponta_a_ponta.log): leitura do ESP32 → `alertaAtivo: true` → visita da UBS `PERIGO_EXTREMO` + previsão SOA respondendo pelo DNS |

## Resultados dos testes de falha (VM real)

| Teste | O que foi feito | Resultado |
|---|---|---|
| Crash da API | `kill -9` no processo da API | systemd reiniciou em **5,5 s** (HTTP 502 → 200, PID 1221 → 5856); `servicos.log` registrou `FALHA status=KILL`; auditd registrou quem enviou o sinal |
| Monitor travado | `kill -STOP` no monitor (processo vivo, mas parado) | o systemd não percebe; o **healthcheck** viu o heartbeat parado há 46 s e reiniciou |
| Reboot | `sudo reboot` | todos os serviços subiram sozinhos; o monitor registrou API/previsão subindo e normalizando em 16 s |
| CPU | `stress-ng` em 100% | `[CRITICO] Uso de CPU em 100%`, apontando o `stress-ng` como maior consumidor; depois `[RESOLVIDO]` |
| Disco | arquivo de 12 GB | `[CRITICO] Uso de disco em / em 93%`; arquivo apagado; `[RESOLVIDO]` |
| Memória | alocação de 2,4 GB | `[CRITICO] Uso de memória em 92%`; `[RESOLVIDO]` |

## Estrutura

```
.
├── README.md                 # este arquivo (Ficha + resumo)
├── prompts.md                # registro do uso de IA
└── infra/
    ├── provision.sh          # provisiona tudo: infra -> app -> monitor -> status
    ├── config/heatsafe.conf  # TODAS as configurações (IP, DNS, repositórios, limites)
    ├── scripts/              # provisionamento, monitor, healthcheck, testes, evidências
    ├── systemd/              # units (.service e .timer)
    ├── nginx/                # proxy reverso + página de status
    ├── vm/criar_vm.ps1       # cria a VM no VirtualBox (Windows) por linha de comando
    ├── evidencias/           # saídas e logs coletados na VM
    ├── README.md             # documentação técnica
    └── ROTEIRO_VIDEO.md      # roteiro do vídeo
```

> Dados: nenhum dado pessoal real. A API usa cadastros fictícios de demonstração; o serviço de previsão usa dados públicos do INMET (estação A701).
