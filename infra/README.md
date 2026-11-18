# HeatSafe · Infraestrutura Linux (Operating Systems)

> GS CitizenTech 2026.2 · FIAP · Engenharia de Software 3º ano
> Parte do HeatSafe: **o servidor Linux que hospeda a API central (C#) e o serviço de previsão (Java/Spring Boot + MySQL)**, provisionado 100% por Shell Script, monitorado e capaz de se recuperar sozinho de falhas.

## Em uma frase

Um único comando (`sudo ./infra/provision.sh`) transforma uma VM Ubuntu "zerada" no servidor `heatsafe-srv`: rede com IP fixo, DNS local (`api.heatsafe.local`), usuário de serviço, firewall, auditoria, .NET 10 + Java 21 + MySQL, bancos, `.env`, API e previsão rodando como serviços **systemd** atrás do **nginx**, e um monitor de CPU/memória/disco que também roda como serviço e é vigiado por um timer de autocorreção.

## Arquitetura

```
                    Computador do avaliador / app Expo / navegador
                                       │  http://api.heatsafe.local
                                       ▼
┌──────────────────────────── VM Ubuntu 24.04 · heatsafe-srv ────────────────────────────┐
│  ufw: entra só 22 (SSH, com limite) e 80 (HTTP)                                         │
│                                                                                         │
│  nginx :80 ──┬── api.heatsafe.local ──────► heatsafe-api.service      127.0.0.1:5000    │
│              │                               (dotnet HeatSafe.Api.dll, usuário heatsafe) │
│              ├── previsao.heatsafe.local ─► heatsafe-previsao.service 127.0.0.1:8000    │
│              │                               (java -jar Spring Boot + MySQL :3306 local) │
│              └── heatsafe.local ──────────► página de status (status.json do monitor)    │
│                                                                                         │
│  heatsafe-monitor.service  ── a cada 15 s: CPU, memória, disco, serviços ─► alertas.log │
│  heatsafe-healthcheck.timer ── a cada 1 min: reinicia o que caiu/travou ─► healthcheck  │
│  auditd + scripts ─────────── quem fez o quê ─────────────────────────────► auditoria   │
│                                                                                         │
│  /etc/heatsafe/{api,previsao}.env (640)       /var/lib/heatsafe (SQLite da API)          │
│  /var/log/heatsafe/*.log (todos os logs)      /opt/heatsafe (código, API, venv, scripts) │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Onde está cada critério da avaliação

| Critério (pontos) | Onde | O que demonstra |
|---|---|---|
| Provisionamento de infra: redes, DNS, IP **(2)** | `scripts/provision_infra.sh` | hostname `heatsafe-srv`, IP estático via netplan, DNS externos, DNS local em `/etc/hosts`, fuso/NTP, usuário de serviço, firewall ufw, SSH endurecido |
| Provisionamento da aplicação **(2)** | `scripts/provision_app.sh` | clona os 2 repositórios do grupo, instala .NET 10 (versão lida do `.csproj`), Java 21 e MySQL, cria banco/usuário e um `.env` por serviço, compila (`dotnet publish` e Maven), sobe tudo como systemd, configura o nginx e testa pelos nomes DNS |
| Monitoramento com alertas de CPU, disco e memória **(2)** | `scripts/monitor.sh` | ALERTA / CRÍTICO / RESOLVIDO com limites configuráveis, maiores consumidores, anti-spam, webhook opcional, página de status |
| Monitoramento como serviço tolerante a falhas **(1)** | `systemd/heatsafe-monitor.service`, `heatsafe-healthcheck.timer`, `scripts/healthcheck.sh` | `Restart=always` + timer que detecta monitor **travado** (heartbeat), serviço parado ou sem resposta HTTP |
| Logs de auditoria e execução **(1)** | `scripts/lib/common.sh`, `hooks/evento_servico.sh`, regras do `auditd` | cada script registra INÍCIO/ETAPA/OK/FALHA/FIM com usuário real (mesmo via sudo); o systemd registra cada queda e o motivo; o auditd registra quem deu `kill -9` |
| Funcionamento completo **(2)** | `provision.sh`, `scripts/teste_ponta_a_ponta.sh`, `scripts/status.sh` | um comando sobe tudo; o teste de ponta a ponta simula o ESP32 enviando uma leitura perigosa e confere alerta, visitas e previsão pelo DNS |

## Requisitos da VM

- **Ubuntu Server 24.04 LTS** (também funciona no 22.04), com systemd e acesso à internet
- 2 vCPU, **2 GB de RAM** (4 GB se for compilar a API C# na própria VM), 20 GB de disco
- Rede no VirtualBox: **NAT** já funciona. Para acessar do seu computador pelo navegador, adicione um segundo adaptador **Host-only** ou use **Bridge** (ver "Acessar do seu computador")
- Um usuário com `sudo` (o que você cria na instalação)

## Passo a passo

**1. Criar a VM** (Windows + VirtualBox): rode [`vm/criar_vm.ps1`](vm/criar_vm.ps1) passando o caminho da ISO do Ubuntu Server 24.04, instale o Ubuntu (marque **Install OpenSSH server**) e entre por SSH com `ssh -p 2222 <usuario>@localhost`.

**2. Dentro da VM:**
```bash
git clone https://github.com/<conta>/GS-HeatSafe-Linux.git heatsafe
cd heatsafe

# (opcional) ajustar IP, limites dos alertas, repositórios...
nano infra/config/heatsafe.conf

# provisionar TUDO (infra -> aplicação -> monitor)
sudo bash infra/provision.sh

# conferir
./infra/scripts/status.sh
./infra/scripts/teste_ponta_a_ponta.sh
```
O provisionamento completo leva de 10 a 15 minutos (a maior parte é baixar e compilar o .NET e o Java). A API e o serviço de previsão são baixados automaticamente dos repositórios do grupo.

> Se aparecer `Permission denied`, o Git perdeu a permissão de execução (comum quando o arquivo passa pelo Windows). Rode uma vez: `chmod +x infra/provision.sh infra/scripts/*.sh infra/scripts/hooks/*.sh` e, para gravar isso no repo, `git update-index --chmod=+x infra/provision.sh infra/scripts/*.sh infra/scripts/hooks/*.sh`.

Etapas separadas, se precisar: `sudo ./infra/provision.sh infra`, `... app` ou `... monitor`. Todos os scripts são **idempotentes**: rodar de novo não estraga nada (segredos do `.env` são preservados; arquivos de sistema ganham backup em `/var/backups/heatsafe` antes de mudar).

> Quando os colegas mudarem o código da API ou da previsão, rode `sudo ./infra/provision.sh app` de novo: o script baixa a última versão dos repositórios, recompila e reinicia os serviços (a versão anterior fica guardada em `/opt/heatsafe/api.anterior` e `/opt/heatsafe/previsao.anterior`).

## Configuração (`config/heatsafe.conf`)

| Variável | Padrão | Para quê |
|---|---|---|
| `HS_HOSTNAME` / `HS_DOMAIN` | `heatsafe-srv` / `heatsafe.local` | identidade do servidor |
| `NET_MODE` | `static` | `static` fixa o IP; `dhcp` mantém DHCP e só define DNS |
| `NET_IP` / `NET_GATEWAY` | vazio | vazio = fixa o IP e o gateway que a VM já tem. Ex.: `192.168.56.10/24` |
| `NET_DNS` | `1.1.1.1,8.8.8.8` | DNS externos |
| `HS_DNS_NAMES` | `heatsafe.local api… previsao… monitor…` | nomes do DNS local |
| `API_REPO_URL` / `API_REPO_BRANCH` | HeatSafe-Backend / `master` | repositório da API C# |
| `PREVISAO_REPO_URL` / `PREVISAO_REPO_BRANCH` | GS-HeatSafe-SOA / `main` | repositório do serviço de previsão (Java) |
| `API_CSPROJ` | `HeatSafe.Api/HeatSafe.Api.csproj` | projeto Web da API; a versão do .NET é lida dele |
| `JAVA_VERSION` / `JAVA_OPTS` | `21` / `-Xmx512m…` | versão do Java e memória da JVM |
| `MYSQL_DB` / `MYSQL_USER` | `heatsafe` | banco e usuário do MySQL da previsão (senha gerada e guardada em `previsao.env`) |
| `ASPNET_ENV` | `Development` | `Development` liga o Swagger para a demonstração |
| `CPU_*`, `MEM_*`, `DISK_*` | 70/90, 75/90, 80/90 | limites de ALERTA/CRÍTICO em % |
| `MON_INTERVAL` | `15` | segundos entre leituras |
| `ALERT_WEBHOOK_URL` | vazio | webhook do Discord/Slack/Teams para receber os alertas no celular |

## Como a aplicação do grupo é hospedada

O `provision_app.sh` baixa direto dos repositórios do grupo e configura cada parte **só por variáveis de ambiente**, sem alterar o código dos colegas:

| | API central | Serviço de previsão (SOA) |
|---|---|---|
| Repositório | [HeatSafe-Backend](https://github.com/GustavooHM/HeatSafe-Backend) (`master`) | [GS-HeatSafe-SOA](https://github.com/3ESPG/GS-HeatSafe-SOA) (`main`) |
| Tecnologia | C# / ASP.NET Core **.NET 10**, EF Core + SQLite | **Java 21** / Spring Boot 4, Flyway + **MySQL 8** |
| Build | `dotnet publish -c Release` → `/opt/heatsafe/api` | `./mvnw package` → `/opt/heatsafe/previsao/heatsafe-previsao.jar` |
| Serviço | `heatsafe-api.service` em `127.0.0.1:5000` | `heatsafe-previsao.service` em `127.0.0.1:8000` |
| Endereço público | `http://api.heatsafe.local` (Swagger em `/swagger`) | `http://previsao.heatsafe.local` (Swagger em `/swagger-ui.html`) |
| Variáveis (`/etc/heatsafe/…`) | `api.env`: `ConnectionStrings__HeatSafe`, `Forecast__BaseUrl=http://previsao.heatsafe.local/`, `Jwt__SigningKey` (gerada), `ASPNETCORE_URLS` | `previsao.env`: `PORT`, `SERVER_ADDRESS=127.0.0.1`, `DB_URL`, `DB_USER`, `DB_PASSWORD` (gerada) |
| Banco | criado pela própria API ao iniciar (`MigrateAsync` + dados de exemplo) | tabelas criadas pelo Flyway; carga dos 3.996 dias do INMET na 1ª subida |
| Health | `GET /health` | `GET /health` |

Cada serviço tem o **seu próprio arquivo de ambiente** (permissão 640): a API não enxerga a senha do MySQL e a previsão não enxerga a chave do JWT. A integração SOA acontece pelo DNS local: a API consulta `http://previsao.heatsafe.local/previsao/amanha?estacao=A701` (todo dia após as 19h).

## Logs e auditoria

Tudo fica em **`/var/log/heatsafe/`** (grupo `heatsafe`, rotação diária, 14 dias):

| Arquivo | Conteúdo |
|---|---|
| `auditoria.log` | Trilha de auditoria de **todos** os scripts: data, host, usuário real (mesmo com sudo), script, PID, ação (INICIO, ETAPA, OK, FALHA, BACKUP, AUTOCORRECAO, TESTE_FALHA, FIM) e detalhe |
| `provision_*.log`, `teste_falha.log` | Saída completa de cada execução (log de execução) |
| `servicos.log` | Cada vez que um serviço sobe ou cai, com PID e motivo (`resultado=signal status=KILL`) |
| `alertas.log` | Alertas do monitor: ALERTA, CRITICO, RESOLVIDO, RECUPERADO |
| `monitor.log` | Uma linha por leitura: CPU, memória, disco, load e estado dos serviços |
| `healthcheck.log` | Verificações e autocorreções do timer |

Além disso:
- **journald:** `journalctl -t heatsafe-auditoria`, `-t heatsafe-monitor`, `-u heatsafe-api`
- **auditd (nível do kernel):** `sudo ausearch -k heatsafe_kill9 -i` mostra **quem** mandou o `kill -9`; também há chaves para `/etc/hosts` (`heatsafe_dns`), netplan (`heatsafe_rede`), `.env` (`heatsafe_config`), units (`heatsafe_systemd`), firewall, usuários e sudoers

## Testes de falha

```bash
sudo ./infra/scripts/teste_falha.sh api       # kill -9 na API -> systemd reinicia em ~3 s (mostra HTTP 502 -> 200)
sudo ./infra/scripts/teste_falha.sh previsao  # kill -9 no serviço de previsão
sudo ./infra/scripts/teste_falha.sh monitor   # kill -9 no próprio monitor
sudo ./infra/scripts/teste_falha.sh travar    # congela o monitor (SIGSTOP): o systemd não percebe, o heartbeat sim
sudo ./infra/scripts/teste_falha.sh parar     # systemctl stop na API -> o timer de healthcheck religa
sudo ./infra/scripts/teste_falha.sh cpu       # CPU a 100% -> CRITICO -> RESOLVIDO
sudo ./infra/scripts/teste_falha.sh memoria   # consome memória até passar do limite
sudo ./infra/scripts/teste_falha.sh disco     # enche o disco até passar do limite (e apaga no final)
sudo ./infra/scripts/teste_falha.sh todos

./infra/scripts/teste_ponta_a_ponta.sh        # fluxo completo: ESP32 -> API -> status/visitas + previsão (SOA)
```

Cada teste mostra o estado antes, a falha, a recuperação segundo a segundo e as evidências (servicos.log, journal, auditd). Depois rode `sudo ./infra/scripts/coletar_evidencias.sh` para salvar tudo em `infra/evidencias/<data-hora>/` e versionar no GitHub.

**Duas camadas de tolerância a falhas:**
1. `Restart=always` (+ `StartLimitIntervalSec=0`): se o processo **morrer**, o systemd o reinicia em 3–5 s, sem limite de tentativas.
2. `heatsafe-healthcheck.timer` (a cada 1 min, como root): cobre o que o systemd não vê. Reinicia serviço **parado** ou em `failed`, monitor **travado** (heartbeat com mais de 45 s) e serviço "ativo" que **não responde HTTP** em 2 verificações seguidas. Para manutenção planejada: `sudo touch /etc/heatsafe/manutencao` pausa a autocorreção.

## Acessar do seu computador

1. No VirtualBox, adicione um adaptador **Host-only** à VM (ou use **Bridge**) e descubra o IP com `ip -br a`. Para fixar esse IP, ponha em `NET_IFACE`/`NET_IP` no `heatsafe.conf`.
2. No seu computador, adicione ao arquivo hosts (`C:\Windows\System32\drivers\etc\hosts` no Windows, `/etc/hosts` no Linux/Mac):
   ```
   192.168.56.10  heatsafe.local api.heatsafe.local previsao.heatsafe.local monitor.heatsafe.local
   ```
3. Abra `http://heatsafe.local` (status ao vivo), `http://api.heatsafe.local/swagger` e `http://previsao.heatsafe.local/swagger-ui.html`.
   Sem DNS (ex.: ESP32): `http://<IP>/api/...` e `http://<IP>/previsao-svc/...`.

## Segurança aplicada

- API e previsão escutam só em `127.0.0.1`; o firewall bloqueia as portas 5000/8000 e libera só 22 e 80.
- Serviços rodam como `heatsafe` (conta de sistema sem login), com sandbox do systemd (`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`) e limite de memória (cgroups).
- `.env` com permissão `640 root:heatsafe`, segredos gerados com `openssl rand` e mascarados em qualquer saída.
- SSH sem login de root, com limite de tentativas; ufw com `limit` na porta 22.
- Nenhum dado pessoal real: os dados de idosos são simulados (regra da GS); os logs de infra não registram dados da aplicação.

## Estrutura

```
infra/
├── provision.sh                      # orquestrador: infra -> app -> monitor -> status
├── vm/criar_vm.ps1                   # cria a VM no VirtualBox (Windows)
├── config/
│   ├── heatsafe.conf                 # TODAS as configurações
│   └── logrotate-heatsafe
├── scripts/
│   ├── provision_infra.sh            # rede, IP, DNS, hostname, usuário, firewall, SSH, auditd
│   ├── provision_app.sh              # repositórios, .NET, Java, MySQL, .env, systemd, nginx
│   ├── provision_monitor.sh          # monitor e healthcheck como serviços
│   ├── monitor.sh                    # daemon de monitoramento (CPU, memória, disco, serviços)
│   ├── healthcheck.sh                # autocorreção (chamado pelo timer)
│   ├── teste_falha.sh                # testes de falha para o vídeo
│   ├── teste_ponta_a_ponta.sh        # fluxo completo da aplicação pelo DNS/nginx
│   ├── status.sh                     # painel no terminal
│   ├── coletar_evidencias.sh         # junta evidências em infra/evidencias/
│   ├── hooks/evento_servico.sh       # registra cada subida/queda de serviço
│   └── lib/common.sh                 # logs, auditoria, erros, utilidades
├── systemd/                          # modelos das units (.service e .timer)
├── nginx/                            # proxy reverso + página de status
├── evidencias/                       # saídas coletadas na VM (prints e logs)
└── ROTEIRO_VIDEO.md                  # roteiro do vídeo de 7 minutos
```

## Solução de problemas

| Sintoma | O que fazer |
|---|---|
| VM muito lenta, mensagens "soft lockup"/"rcu stall", teste de CPU travando | O VirtualBox está rodando sobre o Hyper-V. Confirme no Windows: `Select-String "$env:USERPROFILE\VirtualBox VMs\heatsafe-srv\Logs\VBox.log" -Pattern "fall back to NEM"`. Se aparecer, desative **Integridade da memória** (Segurança do Windows → Isolamento de núcleo), suspenda o BitLocker por 1 reinício (`manage-bde -protectors -disable C: -RebootCount 1`), rode `bcdedit /set hypervisorlaunchtype off` (admin) e reinicie. Para desfazer: `bcdedit /set hypervisorlaunchtype auto` e religar a Integridade da memória |
| VM lenta só quando minimizada | `powercfg /powerthrottling disable /path "C:\Program Files\Oracle\VirtualBox\VirtualBoxVM.exe"` (admin) e deixe o notebook na tomada |
| Perdi o SSH depois do `provision_infra` | O IP mudou (você definiu `NET_IP`). Conecte no IP novo, ou entre pelo console da VM. |
| `heatsafe-api` falhou | `journalctl -u heatsafe-api -n 50`. Geralmente é a string de conexão ou falta do `/health` (não é erro) |
| `heatsafe-previsao` falhou | `journalctl -u heatsafe-previsao -n 80`. Confira se o MySQL está ativo (`systemctl status mysql`) |
| Pouca RAM ao compilar a API | Aumente a VM para 4 GB, ou publique a API no seu computador e copie a pasta |
| Quero parar tudo para manutenção | `sudo touch /etc/heatsafe/manutencao` e depois `sudo systemctl stop heatsafe-api` |
| Ver tudo ao vivo | `watch -c -n 5 ./infra/scripts/status.sh` ou `tail -f /var/log/heatsafe/alertas.log` |
