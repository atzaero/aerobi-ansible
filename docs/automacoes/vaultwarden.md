# Vaultwarden — automações

Backend Bitwarden-compatible self-hosted, em `vault.aerobi.com.br`. Provisionado por [`roles/vaultwarden`](../../roles/vaultwarden) com Postgres dedicado, SMTP Gmail, `/admin` tailnet-only.

## APIs disponíveis

| API | Para que serve | Auth |
| --- | --- | --- |
| `/alive` | Health check público | nenhuma |
| `/admin/...` | Gestão do servidor (users, orgs, diagnostics, config) | `Authorization: Bearer <ADMIN_TOKEN>` + tailnet |
| API Bitwarden via `bw` CLI | CRUD em items do cofre (cofres pessoais e orgs) | Login de user normal (+ unlock por sessão) |
| `bw serve` | API REST local na 8087 do laptop | Sem auth (escutar só em `127.0.0.1`) |

Detalhe importante: nos endpoints `/admin/users`, `/admin/diagnostics` etc., **enviar header `Accept: application/json`** — sem ele, o servidor responde HTML (renderiza o painel).

## O que já está automatizado

- **Provisionamento** via `playbooks/setup_vaultwarden.yml`: container, DB no Postgres, vhost nginx + Certbot, ACL path-level no `/admin`.
- **Healthcheck Docker**: `curl /alive` — distroless não é o caso aqui (a imagem `vaultwarden/server` tem `curl`).
- **Renovação de cert TLS**: Certbot via systemd timer (instalado pela role `nginx_vhost`).

Nada além do baseline. Tudo abaixo é backlog.

## Ideias e backlog

| # | Ideia | Impacto | Esforço | Dependências |
| --- | --- | --- | --- | --- |
| 1 | Espelhamento Ansible Vault → Vaultwarden ao provisionar serviço | Alto | Médio | `bw` CLI, org "Aerobi" |
| 2 | Backup diário do volume `vaultwarden_data` no MinIO | Alto | Baixo | MinIO buckets, `mc` |
| 3 | Aerobi-api consome secrets do Vaultwarden em vez de `.env` | Alto | Alto | `bw serve` na VPS ou SDK |
| 4 | Rotação periódica de senhas operacionais | Alto | Alto | scripts por serviço |
| 5 | Onboarding automatizado de novo membro do time | Médio | Médio | `bw send`, scripts Headscale/SFTPGo |
| 6 | GitHub Actions puxa secrets do Vaultwarden em vez de GH Secrets | Médio | Médio | runner com acesso à tailnet |
| 7 | Audit log de acessos ao `/admin` → push Discord/Telegram | Médio | Baixo | parser de logs, webhook |
| 8 | Monitor "canário" no Uptime Kuma | Médio | Baixo | Uptime Kuma, user canário |
| 9 | Export off-site mensal criptografado (defesa em profundidade) | Médio | Baixo | hardware key ou e-mail seguro |
| 10 | `bw serve` local para devs (substitui `.env.example`) | Baixo | Baixo | nenhuma |
| 11 | Alerta semanal de senhas fracas/antigas | Baixo | Médio | parser de items, score |
| 12 | Sync com hardware key (YubiKey/Solo) para credenciais críticas | Baixo | Alto | hardware física |

### Sequência recomendada

1. **#2 (backup MinIO)** primeiro — protege o investimento.
2. **#1 (espelhamento Vault → Vaultwarden)** — usar [`../../scripts/migrate-secrets-to-vaultwarden.sh`](../../scripts/migrate-secrets-to-vaultwarden.sh) para o bulk inicial; depois disso, adicionar hook no playbook para serviços novos.
3. **#7 + #8** (audit + canário) — observabilidade básica.
4. **#5 (onboarding script)** — paga por si só na primeira contratação.
5. Resto entra em backlog conforme demanda.

### Mini-specs das prioritárias

#### #1 — Espelhamento Ansible Vault → Vaultwarden

**Por quê**: ter senha **só** no `vault.yml` significa que humanos precisam decriptar com Ansible toda vez que vão usar uma credencial (DBeaver, mc admin, painel web). Vaultwarden vira a UI humana; vault.yml continua o source-of-truth de provisionamento.

**Como** (script único de migração + hook no playbook):

1. **Bulk inicial**: rodar [`scripts/migrate-secrets-to-vaultwarden.sh`](../../scripts/migrate-secrets-to-vaultwarden.sh) localmente (mais detalhes no README do script).

   O script cria as Collections faltantes automaticamente (`bw create org-collection`). Você só precisa garantir que a **Org "Aerobi"** existe e que seu user é **owner/admin** dela.

2. **Para serviços futuros**, adicionar um `post_tasks` no playbook do serviço:
   ```yaml
   - name: Espelhar credencial no Vaultwarden (via bw CLI no controller)
     delegate_to: localhost
     command: >
       scripts/upsert-vw-item.sh
       --collection "Infrastructure"
       --name "Postgres Aerobi"
       --field "{{ <serviço>_user }}={{ <serviço>_password }}"
     environment:
       BW_SESSION: "{{ lookup('env', 'BW_SESSION') }}"
   ```

**Source-of-truth**: `vault.yml`. Vaultwarden é **mirror read-only para humanos**. Mudou a senha? Atualize o vault.yml, re-rode o sync. Nunca o contrário (Vaultwarden não rode `ALTER USER` em produção).

#### #2 — Backup diário do volume no MinIO

**Por quê**: volume `vaultwarden_data` tem o DB com todos os items. Perdeu o volume = perdeu cofre. RTO atual: indefinido (nenhum backup). RPO objetivo: 24h.

**Como**:

```bash
# /home/deploy/scripts/backup-vaultwarden.sh — chamado por cron 03:00 diário
set -euo pipefail
BACKUP_NAME="vaultwarden-$(date -u +%FT%H%M%SZ).tgz"

docker run --rm \
  -v vaultwarden_data:/data \
  -v /tmp:/out \
  alpine tar czf /out/$BACKUP_NAME -C /data .

mc cp /tmp/$BACKUP_NAME aerobi/aerobi-prod-backups/vaultwarden/
rm /tmp/$BACKUP_NAME

# Retenção: manter 30 dias
mc find aerobi/aerobi-prod-backups/vaultwarden/ --older-than 30d --exec "mc rm {}"
```

Crontab `deploy@vps-prod`:
```cron
0 3 * * * /home/deploy/scripts/backup-vaultwarden.sh >> /home/deploy/scripts/backup-vaultwarden.log 2>&1 || curl -fsS "https://uptime-kuma-push-url/?status=down"
```

**Restore**:
```bash
docker stop vaultwarden
mc cp aerobi/aerobi-prod-backups/vaultwarden/vaultwarden-YYYY-MM-DD.tgz /tmp/
docker run --rm -v vaultwarden_data:/data -v /tmp:/in alpine \
  sh -c 'rm -rf /data/* && tar xzf /in/vaultwarden-YYYY-MM-DD.tgz -C /data'
docker start vaultwarden
```

#### #7 — Audit log de acessos ao `/admin`

**Por quê**: o `/admin` é a chave do reino. Token vazado = adversário consegue listar users, resetar 2FA de qualquer um, exfiltrar org keys. Detectar acesso anômalo cedo é crítico.

**Como** (poll do log a cada N min, push para Discord webhook se houver hit):

```bash
# /home/deploy/scripts/audit-vaultwarden-admin.sh — cron a cada 15 min
WEBHOOK_URL="<discord webhook>"
LOG_FILE="/var/lib/docker/volumes/vaultwarden_data/_data/vaultwarden.log"
SINCE_FILE="/home/deploy/scripts/.audit-last-position"

LAST=$(cat $SINCE_FILE 2>/dev/null || echo 0)
CURRENT=$(wc -l < $LOG_FILE)

if [ $CURRENT -gt $LAST ]; then
  NEW=$(tail -n $((CURRENT - LAST)) $LOG_FILE | grep -iE 'admin|/admin')
  if [ -n "$NEW" ]; then
    curl -X POST $WEBHOOK_URL \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"⚠️ Acesso /admin Vaultwarden detectado:\n\`\`\`\n$NEW\n\`\`\`\"}"
  fi
fi
echo $CURRENT > $SINCE_FILE
```

Refinar com lista de IPs whitelisted (seu laptop na tailnet) para suprimir falso positivo.

#### #8 — Monitor canário no Uptime Kuma

**Por quê**: `/alive` retorna 200 mesmo se o DB estiver corrompido e nenhum item puder ser lido. Health-check superficial.

**Como** (criar um item dummy fixo, monitor faz GET via API e valida resposta):

1. Criar item no cofre `Aerobi/Health` chamado `canary-vaultwarden`, valor: `OK-aerobi-canary-v1`.
2. No Uptime Kuma: monitor tipo HTTP(s) Keyword → URL `https://vault.aerobi.com.br/api/items/<id>` com header de auth + keyword esperada `OK-aerobi-canary-v1`.
3. Alertar se status ≠ 200 ou keyword ausente.

## Scripts úteis (copiar e colar)

### Pegar admin token do vault

```bash
ansible localhost -m debug -a "var=vault_vaultwarden_admin_token" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
```

### Health público

```bash
curl -sI https://vault.aerobi.com.br/alive
```

### Listar users (tailnet + JSON)

```bash
TOKEN='<cole_aqui>'
curl -sk https://vault.aerobi.com.br/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" | jq
```

### Diagnostics (versão, DB, SMTP)

```bash
curl -sk https://vault.aerobi.com.br/admin/diagnostics \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" | jq
```

### Convidar user (envia e-mail via SMTP)

```bash
curl -sk -X POST https://vault.aerobi.com.br/admin/invite \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email": "novo@aerobi.com.br"}'
```

### Bw CLI — primeira configuração

```bash
# Instalar
npm install -g @bitwarden/cli

# Apontar pro servidor self-hosted
bw config server https://vault.aerobi.com.br

# Login (interativo)
bw login eleram@protonmail.com

# Unlock por sessão (retorna BW_SESSION)
export BW_SESSION=$(bw unlock --raw)
```

### Bw CLI — descobrir IDs da org e collections

```bash
bw sync
bw list organizations | jq '.[] | {id, name}'
bw list collections --organizationid <UUID-org> | jq '.[] | {id, name}'
```

### Bw CLI — criar item login com custom fields

```bash
ORG=<UUID-org>
COLL=<UUID-collection>

bw get template item | jq --arg org "$ORG" --arg coll "$COLL" '
  .organizationId = $org
  | .collectionIds = [$coll]
  | .name = "Exemplo Serviço"
  | .login = {"username": "user", "password": "senha", "uris": [{"uri": "https://exemplo"}]}
  | .fields = [
      {"name": "campo_extra", "value": "valor", "type": 0},
      {"name": "campo_secreto", "value": "senha", "type": 1}
    ]' \
  | bw encode | bw create item
```

`type: 0` = texto normal; `type: 1` = hidden (mascarado na UI).

## Riscos e gotchas

- **`bw login` salva credenciais em `~/.config/Bitwarden CLI/`**. Em máquina compartilhada, fazer `bw logout` quando terminar. Lock automático ≠ logout — `bw lock` só limpa `BW_SESSION`, não a credencial salva.
- **`BW_SESSION` em ambiente**: scripts que setam `export BW_SESSION=...` deixam o token visível em `ps -e ww`. Para scripts longos, prefira `bw unlock` por chamada (caro) ou unset depois.
- **Vaultwarden NÃO substitui Ansible Vault** para provisionamento. Playbooks rodam em CI/headless — não vão chamar `bw get item` no meio do `setup_vaultwarden.yml`. Mantenha vault.yml como source-of-truth de provisionamento, Vaultwarden como UI humana espelhada.
- **`/admin` JSON vs HTML**: sem `Accept: application/json`, retorna o HTML do painel. Scripts quebram silenciosamente parseando HTML como JSON.
- **Senhas em `notes` do item são pesquisáveis pelo `bw search`**. Se algo é estritamente sensível, usar `fields` com `type: 1` (hidden) ou `securenote` separado.
- **Org owner unique-point-of-failure**: se você sair, ninguém recupera. Documentar processo de recovery (export off-site, segunda conta admin) é o item #9 do backlog — não adiar muito.
- **Reset de admin do server ≠ reset de senha de user**: o `ADMIN_TOKEN` é separado das contas. Esquecer o token = recuperar via vault.yml (ainda funciona); esquecer senha de user = enviar reset por SMTP.

## Issues no GitHub

Backlog completo de Vaultwarden: [12 issues abertas com label `vaultwarden` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avaultwarden+label%3Aautomation).

Filtros úteis:

- [🔴 Alta prioridade](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avaultwarden+label%3Apriority-high) — começar por aqui (3 issues: backup, espelhamento, audit)
- [🟡 Média prioridade](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avaultwarden+label%3Apriority-medium) — 5 issues
- [🟢 Baixa prioridade](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avaultwarden+label%3Apriority-low) — 4 issues

Fonte do backlog: [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml).

## Referências

- Docs upstream: https://github.com/dani-garcia/vaultwarden/wiki
- Bitwarden API docs (mesma do Vaultwarden): https://bitwarden.com/help/api/
- Bw CLI: https://bitwarden.com/help/cli/
- Script de migração de secrets: [`scripts/migrate-secrets-to-vaultwarden.sh`](../../scripts/migrate-secrets-to-vaultwarden.sh)
- Docs dos scripts: [`scripts/README.md`](../../scripts/README.md)
