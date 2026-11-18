# Roteiro do vídeo · Operating Systems (até 7 minutos)

**Preparação (antes de gravar):**
- Restaure o snapshot **"VM limpa"** no VirtualBox (Ubuntu recém-instalado, sem nada do HeatSafe) e ligue a VM.
- Clone este repositório na VM (`git clone ... heatsafe`); terminal com fonte grande (Ctrl + `+`).
- No seu computador: arquivo hosts com os nomes `*.heatsafe.local` apontando para o IP da VM (ver README).
- A instalação de pacotes e a compilação do .NET levam alguns minutos: **grave tudo e acelere na edição** (2x a 8x), deixando em velocidade normal só os momentos explicados abaixo.

| Tempo | O que mostrar | O que falar (resumo) |
|---|---|---|
| **0:00–0:30** | Slide/README com o diagrama de arquitetura | "Esta é a infraestrutura do HeatSafe: um servidor Linux que hospeda a API C# e o serviço de previsão com ML, provisionado só com Shell Script." |
| **0:30–1:00** | `hostname`, `ip -br a`, `cat /etc/hosts` na VM "zerada"; `nano infra/config/heatsafe.conf` | "A VM está limpa. Toda a configuração fica num arquivo só: hostname, IP, DNS, limites de alerta." |
| **1:00–2:45** | `sudo ./infra/provision.sh` (acelerado). **Pause em velocidade normal** em: hostname → netplan (IP fixo) → `/etc/hosts` resolvendo `api.heatsafe.local` → ufw → clonagem dos repositórios → instalação do .NET 10, Java 21 e MySQL → `.env` com segredos mascarados → migrações → `systemctl restart` → testes de fumaça | "Etapa de infra: rede, IP, DNS... Etapa de aplicação: dependências, variáveis de ambiente, migrações e orquestração com systemd e nginx." |
| **2:45–3:30** | `./infra/scripts/teste_ponta_a_ponta.sh` (o "ESP32" manda uma leitura perigosa e a API gera alerta e visita) + navegador do seu computador: `http://api.heatsafe.local/swagger`, `http://previsao.heatsafe.local/swagger-ui.html`, `http://heatsafe.local` (página de status) | "Tudo no ar e acessível pelo DNS local. Funcionamento completo." Chame um endpoint no Swagger (ex.: previsão de amanhã). |
| **3:30–4:30** | **Teste de falha 1:** `sudo ./infra/scripts/teste_falha.sh api` | "Vou simular um crash com kill -9. Vejam o HTTP 502 e, em cerca de 3 segundos, o systemd sobe a API de novo com outro PID. O log de serviços registra FALHA, status KILL, e o auditd mostra quem mandou o sinal." |
| **4:30–5:15** | **Teste de falha 2:** `sudo ./infra/scripts/teste_falha.sh travar` | "E se o monitor travar sem morrer? O systemd acha que está tudo bem, mas o heartbeat para. O timer de healthcheck percebe e reinicia. São duas camadas de tolerância a falhas." |
| **5:15–6:15** | **Alertas:** `sudo ./infra/scripts/teste_falha.sh cpu` e depois `... disco`, com a página `http://heatsafe.local` aberta ao lado (as barras ficam vermelhas) | "O monitor gera ALERTA, CRÍTICO e RESOLVIDO, mostra o processo que está consumindo e não repete o alerta à toa." |
| **6:15–6:50** | `tail /var/log/heatsafe/auditoria.log`, `ls /var/log/heatsafe`, `sudo ausearch -k heatsafe_kill9 -i \| tail` | "Toda execução fica auditada: quem rodou, quando, cada etapa, sucesso ou falha. E o auditd registra no nível do kernel." |
| **6:50–7:00** | Repositório no GitHub (pasta `infra/` e `evidencias/`) | "Scripts, configurações e evidências estão no repositório. Obrigado!" |

**Dicas:**
- O provisionamento completo leva ~10–15 min: grave tudo e acelere na edição.
- Antes de gravar, confira que o VirtualBox **não** está em modo NEM (ver "Solução de problemas" no README); senão a VM fica lenta e os testes de carga demoram.
- Bônus se sobrar tempo: `sudo reboot` e mostrar no `status.sh` que tudo sobe sozinho no boot.
- Se o vídeo passar de 7 min, corte primeiro o teste de memória e diminua o tempo da instalação (acelere mais).
- Antes de gravar a versão final, rode tudo uma vez para "esquentar" (o download do .NET é o mais demorado).
