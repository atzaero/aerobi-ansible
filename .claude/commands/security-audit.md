# Security Audit

Varredura de segurança do **repo inteiro** (não só do diff), guiada por
[`docs/SECURITY.md`](../../docs/SECURITY.md). Use periodicamente ou antes de um
bootstrap fresh em prod.

## Diferença pro `/infra-review`

| | `/infra-review` | `/security-audit` |
|---|---|---|
| Escopo | diff `main...HEAD` | repo inteiro + estado |
| Quando | antes de cada PR | auditoria periódica / pré-prod |
| Profundidade | mudanças da branch | superfície de ataque completa |

## Checklist (alinhado a `docs/SECURITY.md`)

### 1. Secrets e Vault
- `grep` por padrões de secret em claro fora do `vault.yml`: senhas, `api_key`,
  `token`, `secret`, connection strings, chaves privadas, pre-auth keys do Headscale.
  ```bash
  grep -rInE '(password|secret|token|api[_-]?key)\s*[:=]\s*["'"'"']?[A-Za-z0-9/+]{8,}' \
    roles/ inventory/ playbooks/ --include='*.yml' --include='*.j2' \
    | grep -v '!vault' | grep -viE 'changeme|vault_|lookup|\{\{'
  ```
- Toda role que consome senha tem default `changeme` + task `fail` fail-fast.
- `git log -p` recente não vazou secret (e nada sensível foi commitado e revertido
  sem rotação).

### 2. Exposição de rede
- Nenhum container com bind `0.0.0.0`/IP público (só `127.0.0.1`):
  ```bash
  grep -rIn '0.0.0.0' roles/ playbooks/ inventory/
  ```
- Nenhum `-p 100.64.0.1:...` em `docker_container` — exposição tailnet só via socat
  sidecar (`*_tailnet_proxy`, `network_mode: host`):
  ```bash
  grep -rIn '100.64.0.1' roles/ playbooks/ inventory/
  ```
- Todo `vhost_tailnet_only=true` tem entrada correspondente em
  `headscale_extra_dns_records` (`roles/headscale/defaults/main.yml`).
- `firewall` (UFW) deny-default; whitelist mínima (22, 80, 443 + UDP 41641 Tailscale).
- Portas expostas batem com `docs/PORTAS.md`.

### 3. Hardening de host
- `ssh_hardening`: sem root login, sem password auth, `MaxAuthTries` baixo.
- `fail2ban` cobre `sshd` (e serviços expostos).
- `become`/NOPASSWD restrito ao `deploy`; sem expansão indevida.
- Headscale: API/pre-auth keys não expostas; ACLs coerentes. Edge (mediamtx) só via
  tailnet.

### 4. TLS e domínios
- vhosts via `nginx_vhost` com Certbot `--reinstall`.
- Domínios seguem `docs/DOMINIOS.md` (infra → `aerobi.com.br`, tailnet-only →
  `100.64.0.1`).

### 5. Higiene do repo
- `.gitignore` cobre `.env`, vault pass, `*.pem`/`*.key`, `id_*`, `secrets/`,
  `.retry`, `.mcp.json`.
- Imagens Docker pinadas (sem `:latest` em prod).

## Workflow

1. Rodar os greps acima + ler `docs/SECURITY.md`.
2. Despachar o agente `infra-reviewer` em modo auditoria (escopo = repo, não diff),
   ou conduzir o checklist manualmente.
3. Reportar findings 🔴/🟡/🔵 com `arquivo:linha`. **Não corrigir automaticamente** —
   apresentar pro usuário priorizar.
4. Findings que viram trabalho → abrir issue com label `security` (e/ou `automation`).

## Saída

Mesmo formato do `infra-reviewer`: seções 🔴/🟡/🔵 + `Total: N crítico, M aviso,
K sugestão`. Encerrar com um veredito curto sobre a postura de segurança atual.
