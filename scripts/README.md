# scripts/

Utilitários operacionais que rodam fora do fluxo dos playbooks Ansible. Ideal para tarefas de **bootstrap interativo**, **bulk operations**, ou **scripts que dependem de credenciais que não vivem no vault.yml** (ex: master do Bitwarden CLI).

## Princípios

- **Idempotentes**: rodar 2x não faz dano.
- **Falham ruidosamente**: erro mata o script (`set -euo pipefail`).
- **Nunca logam secrets**: tudo via pipe; nada toca disco em plaintext.
- **Versionados no repo**: serve de documentação histórica + reuso entre projetos.

## Inventário

| Script | O que faz | Onde rodar |
| --- | --- | --- |
| [`migrate-secrets-to-vaultwarden.sh`](#migrate-secrets-to-vaultwardensh) | Lê `vault.yml`, popula org Aerobi no Vaultwarden | Laptop |
| [`create-automation-issues.py`](#create-automation-issuespy) | Cria issues GitHub a partir de `issue-content/automacoes.yml` | Laptop |
| [`issue-content/automacoes.yml`](issue-content/automacoes.yml) | Fonte da verdade do backlog de automações (89 issues) | — (data) |

---

## migrate-secrets-to-vaultwarden.sh

Espelha os secrets do Ansible Vault na org **Aerobi** do Vaultwarden, agrupados por serviço, com Collections criadas automaticamente se necessário.

### Por que existe

Hoje secrets vivem só em `inventory/prod/group_vars/all/vault.yml`. Quando um humano precisa decriptar para usar (conectar com DBeaver, mc admin, abrir painel de algum serviço), precisa rodar `ansible localhost -m debug -a "var=..."` — fricção desnecessária. Vaultwarden vira a **UI humana** com source-of-truth ainda no `vault.yml` (Ansible continua sendo quem provisiona).

### Pré-requisitos

1. **Bw CLI instalado e logado**:
   ```bash
   npm install -g @bitwarden/cli
   bw config server https://vault.aerobi.com.br
   bw login <email-do-owner-da-org-Aerobi>
   ```

   > ⚠️ **Owner ou Admin da org Aerobi.** User comum não pode criar Collections via API e o script vai falhar com 401. Verifique role com:
   > ```bash
   > bw list organizations | jq '.[] | select(.name=="Aerobi") | {role: .type}'
   > ```
   > `type: 0` = Owner, `1` = Admin, `2` = User, `3` = Manager.

2. **Tailscale conectado** (vhost é tailnet-only):
   ```bash
   sudo tailscale up
   ```

3. **Org "Aerobi" existente** no Vaultwarden (criar pela UI antes).

4. **Master do Ansible Vault** em `~/.ansible-vault/aerobi-prod` (já configurado pelo `ansible.cfg`).

### Uso

```bash
./scripts/migrate-secrets-to-vaultwarden.sh
```

### Duas senhas pedidas (não confundir)

| Senha | Quando | De onde vem |
| --- | --- | --- |
| **Master do Bitwarden** | `bw unlock` (única interativa) | Master da sua conta no Vaultwarden, mesma do login em `https://vault.aerobi.com.br` |
| **Master do Ansible Vault** | Automática | Arquivo `~/.ansible-vault/aerobi-prod` (script não pergunta) |

### Operações realizadas

1. **Valida dependências** (`bw`, `ansible`, `jq`, `python3`).
2. **Unlock do Bw CLI** (banner explicativo antes do prompt).
3. **Identifica user logado** e valida que é Owner ou Admin da org.
4. **Garante Collections** (cria as faltantes via `bw create org-collection`):
   - Infrastructure
   - Applications
   - Network & VPN
   - Services & Admin
   - External & Third-Party
5. **Decripta 11 secrets** do `vault.yml` em memória (nada toca disco).
6. **Cria/atualiza 8 items agrupados** na org Aerobi:
   - `Postgres Aerobi` (Infrastructure) — login + custom fields para DB de cada app
   - `Valkey (cache)` (Infrastructure)
   - `MinIO (object storage)` (Infrastructure)
   - `VPS Deploy User (SSH)` (Network & VPN)
   - `Headscale VPS Pre-Auth Key` (Network & VPN) — Secure Note
   - `Vaultwarden Admin Token` (Services & Admin)
   - `SFTP Go Web Admin` (Services & Admin)
   - `Vaultwarden SMTP (Gmail)` (External & Third-Party)

### Idempotência

- Se a Collection já existe: pula criação.
- Se o item já existe (busca por título exato): atualiza em vez de criar duplicado.
- Rodar 2x mostra `Atualizando` em todas as linhas (já mapeado em prod 2026-05-16).

### Segurança

- **Roda localmente no laptop**, nunca na VPS — master de ambos os vaults nunca toca o servidor.
- **Senhas decriptadas em memória apenas**: pipe `decrypt → jq → bw encode → bw create`.
- **`set -euo pipefail`** — falha cedo, sem deixar items meio-criados.
- **Nada de `set -x`** — não dá log de comandos com valores expandidos.

### Output esperado (primeira execução)

```
→ Verificando dependências
→ Verificando status do bw CLI

═══════════════════════════════════════════════════════════════
  PRÓXIMO PASSO — DIGITE SUA MASTER PASSWORD DO BITWARDEN
  ...
═══════════════════════════════════════════════════════════════

? Master password: [hidden]
✓ Bw sync ok
✓ Logado no bw como: elvis.e.amancio@gmail.com
✓ Org 'Aerobi' encontrada (id=...)
✓ Role do user na org: Owner (permite criar Collections e Items na org)
→ Garantindo Collections esperadas (cria faltantes automaticamente)
✓ Collection 'Infrastructure' já existe ...
✓ Todos os 11 secrets decriptados em memória
→ Construindo e enviando items para a org 'Aerobi'
→ Criando 'Postgres Aerobi' → [Infrastructure]
✓ Criado: Postgres Aerobi
...
✓ Migração concluída. 8 items na org 'Aerobi'.
```

### Adaptar para outros projetos

O script é específico do `vault.yml` do aerobi-ansible (11 secrets, 8 mapeamentos hard-coded). Para reusar em `ansible-vps` ou outro projeto:

1. Copiar script + ajustar `decrypt_secret` para os secrets do projeto destino.
2. Adaptar o bloco "Construção dos items" (lista de items + custom fields).
3. Confirmar que existe a org alvo no Vaultwarden e o user logado é Owner/Admin.

Refatorar para data-driven (lista de items em YAML separado) está no backlog — ver issue `feat(scripts): generalizar migrate-secrets para multi-projeto`.

### Troubleshooting

| Erro | Causa | Fix |
| --- | --- | --- |
| `Falha ao criar Collection ... 401 Unauthorized` | User logado é User comum, não Owner/Admin | `bw logout && bw login <owner>` |
| `Falha ao criar Collection ... "Invalid member"` | Bug do template `bw get template org-collection` (versões antigas) — placeholder de group inválido | Atualizar bw CLI ou usar versão atual deste script (constrói JSON do zero) |
| `Master password` pedida 2x | Sessão `BW_SESSION` perdida entre comandos | Roda direto sem interrupção; script usa variável local |
| `vault password not provided` no ansible | `~/.ansible-vault/aerobi-prod` ausente ou senha errada | Conferir o arquivo |
| Conexão recusada em `vault.aerobi.com.br` | Sem `tailscale up` | `sudo tailscale up` |

---

## create-automation-issues.py

Cria issues GitHub no aerobi-ansible e ansible-vps a partir do YAML versionado em [`scripts/issue-content/automacoes.yml`](issue-content/automacoes.yml).

### Por que existe

Backlog de automações operacionais (89 itens em 2 repos) é fonte da verdade no YAML — issues no GitHub são o materializado. Permite:

- **Reusar**: o mesmo YAML pode popular issues em projetos derivados.
- **Versionar**: PR review nas próprias ideias do backlog antes de virarem issues.
- **Idempotência**: rodar de novo não cria duplicados.

### Pré-requisitos

- `gh` CLI logado (`gh auth status`).
- PyYAML (`pip install pyyaml` ou `apt install python3-yaml`).
- Labels e milestone criados nos repos destino:
  ```bash
  # Já feito uma vez via script inline (ver feat/automacoes-backlog branch)
  gh label create automation --color FBCA04 --repo <repo>
  # ... etc para vaultwarden, headscale, sftpgo, minio, postgres, uptime-kuma, valkey, priority-high/medium/low
  gh api -X POST repos/<repo>/milestones -f title="Automações backlog" -f state=open
  ```

### Uso

```bash
# Dry-run — só lista o que seria criado
./scripts/create-automation-issues.py --dry-run

# Cria tudo
./scripts/create-automation-issues.py

# Filtra por repo (útil pra rodar só em um lado)
./scripts/create-automation-issues.py --repo atzaero/aerobi-ansible

# Filtra por serviço
./scripts/create-automation-issues.py --service vaultwarden
```

### Estrutura do YAML

```yaml
issues:
  - repo: atzaero/aerobi-ansible
    title: "feat(<svc>): descrição em pt-BR"
    labels: [automation, <svc>, priority-{high,medium,low}]
    milestone: "Automações backlog"
    body: |
      ## Contexto
      <1-2 frases>

      ## Escopo
      - <bullets>

      ## Critério de aceite
      - [ ] ...

      ## Esforço / Impacto
      <baixo|médio|alto> / <baixo|médio|alto>

      ## Referências
      - <links>
```

### Idempotência

Antes de criar, busca por título exato com `gh issue list --search "in:title \"...\""` no repo destino (estado `all` = open + closed). Se existir, pula com `[skip]`.

### Adicionar issues novas

1. Edite [`scripts/issue-content/automacoes.yml`](issue-content/automacoes.yml) adicionando entradas ao final.
2. Faça `./scripts/create-automation-issues.py --dry-run` para validar.
3. Faça `./scripts/create-automation-issues.py` para criar.
4. Commit do YAML atualizado.
