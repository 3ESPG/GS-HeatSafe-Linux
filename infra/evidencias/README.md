# Evidências técnicas

Esta pasta guarda as evidências de que a infraestrutura funciona. Elas são geradas **dentro da VM**:

```bash
sudo ./infra/scripts/teste_falha.sh todos       # gera os eventos de falha e alertas
sudo ./infra/scripts/coletar_evidencias.sh      # salva em infra/evidencias/<data-hora>/
git add infra/evidencias && git commit -m "evidencias da infra" && git push
```

## O que é coletado automaticamente

| Arquivo | Prova |
|---|---|
| `01-sistema.txt` | hostname `heatsafe-srv`, fuso, NTP, usuário de serviço, permissões das pastas |
| `02-rede.txt` | IP fixo, rotas, netplan gerado, DNS, portas em escuta (API e previsão só em 127.0.0.1) |
| `03-dns-local.txt` | `/etc/hosts` e resolução de `api.heatsafe.local`, `previsao.heatsafe.local`… |
| `04-firewall.txt` | regras do ufw |
| `05-servicos.txt` | `systemctl status`, timers, contagem de reinícios automáticos (NRestarts) |
| `06-units-systemd.txt` | units geradas e configuração do nginx |
| `07-aplicacao.txt` | respostas HTTP da API e da previsão pelo DNS, status do monitor, `.env` com segredos mascarados |
| `08-auditd.txt` | eventos do auditd (quem deu `kill -9`, quem mudou `/etc/hosts`, netplan, `.env`…) |
| `09-journal.txt` | journal dos serviços HeatSafe |
| `log-*.log` | trechos de auditoria, alertas, serviços, healthcheck, monitor e execuções |

## Prints recomendados (salvar nesta pasta como PNG)

- [ ] `provision.sh` terminando com o painel de status
- [ ] `status.sh` com todos os serviços `active`
- [ ] `teste_ponta_a_ponta.sh` terminando com "Fluxo completo funcionando"
- [ ] Swagger da API em `http://api.heatsafe.local/swagger`
- [ ] Docs da previsão em `http://previsao.heatsafe.local/swagger-ui.html`
- [ ] Página de status `http://heatsafe.local` durante o teste de CPU (barras vermelhas)
- [ ] `teste_falha.sh api`: HTTP 502 → 200 e o PID mudando
- [ ] `teste_falha.sh travar`: healthcheck destravando o monitor
- [ ] `tail /var/log/heatsafe/auditoria.log`
- [ ] `sudo ausearch -k heatsafe_kill9 -i`

## Observação sobre a coleta de 17/11/2026

O `log-provision_monitor.log` e o `log-auditoria.log` desta coleta mostram `ERRO | linha 160: tr -d '@'`. Era um **falso positivo**: ao gerar o `heatsafe-healthcheck.timer`, que não tem nenhuma `@VARIAVEL@`, o `grep` do `render_template` (em `scripts/lib/common.sh`) não encontrava nada e saía com código 1, o que disparava o trap de erro. O arquivo foi gerado corretamente (a linha seguinte do log mostra o `OK`), mas o registro falso também impedia que um erro real posterior no mesmo script fosse registrado. Corrigido em `render_template` (`grep ... || true`); nas próximas coletas essa linha não aparece mais.
