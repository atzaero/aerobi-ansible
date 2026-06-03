# Commit Inteligente

Cria commits seguindo Conventional Commits (em PT-BR), agrupando arquivos
relacionados por funcionalidade/contexto.

## Contexto aerobi-ansible

- Branch no formato `<tipo>/<num-issue>-<slug-curto>` (ex: `feat/12-sftpgo`,
  `fix/7-docker-nat`).
- Tipo do commit deve bater com tipo do branch — `feat/12-...` só produz
  commits `feat(...)`.
- Workflow gitflow simples: `main` direto, sem `develop`.

## Boas práticas

✅ **Commits por grupo de arquivos relacionados**

- Um commit = uma mudança coesa e funcional.
- Facilita revisão, rollback e leitura do histórico.

❌ **Evitar commits por arquivo individual**

- Fragmenta o histórico, perde contexto.

## Convenção (Conventional Commits, descrição em PT-BR)

Formato: `tipo(escopo opcional): descrição`

| Tipo | Uso |
|---|---|
| `feat` | Nova funcionalidade (role nova, playbook novo, var nova significativa) |
| `fix` | Correção de bug (idempotência quebrada, role falhando, var errada) |
| `chore` | Manutenção, bumps de versão, pinning, cleanup de defaults |
| `docs` | README, docs/*.md, comentários explicativos em playbooks/roles |
| `refactor` | Reestruturação sem mudança comportamental |
| `test` | Adição/correção de Molecule scenarios |

Exemplos: `feat(sftpgo): ...`, `chore(vault): ...`, `fix(headscale): ...`.

## Escopos comuns no projeto

- `vault` — secrets em `inventory/prod/group_vars/all/vault.yml`
- `inventory` — dev/prod/all.yml, hosts.yml, host_vars
- `<nome-da-role>` — `headscale`, `sftpgo`, `minio`, `postgres`, `nginx_vhost`,
  `mediamtx`, `aerodrome_edge`, `ssh_hardening`, etc
- `playbook` — quando é mudança em `playbooks/*.yml` que cruza roles
- `ci` — `.github/workflows/`, hooks
- `claude` — `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.cursor/`
- `security` — `docs/SECURITY.md`
- `docs` — `docs/*.md`, README, role READMEs

## Workflow

1. **Analisar mudanças** — `git status` + `git diff` (e `git diff --cached` se
   já tem coisa staged) pra entender o que mudou.
2. **Agrupar por contexto** — arquivos da mesma role/módulo formam um grupo.
3. **Propor grupos e mensagens** — apresentar pro usuário com mensagens sugeridas.
4. **Aguardar confirmação** — só commitar após aprovação explícita.
5. **Executar commits** — `git add <arquivos>` + `git commit` via HEREDOC.

## Regras de agrupamento

- Arquivos da mesma role (`roles/<nome>/`) → mesmo commit.
- README da role + tasks/defaults da role → mesmo commit.
- Mudanças no `inventory/` que **complementam** uma role → mesmo commit.
- Mudanças em `vault.yml` (secrets) → commit separado quando possível.
- `docs/*.md` standalone → commit separado (`docs(...)`).
- `.claude/`, `.cursor/`, `AGENTS.md`, `CLAUDE.md` → commit separado
  (`chore(claude)` ou `docs(claude)`).
- `playbooks/*.yml` novos → commit junto da role principal que invocam.

## Regra de ouro: `git add` seletivo

- **Nunca** `git add .` / `git add -A`. Só os arquivos do grupo, por path explícito.
- **Nunca** stagear `~/.ansible-vault/aerobi-prod`, `.mcp.json`,
  `.claude/settings.local.json`, chaves SSH ou qualquer arquivo sensível.

## Co-author

Sempre incluir trailing line:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

## Closes #N

Se a branch resolve uma issue, **adicionar `Closes #N` no corpo** do commit
(ou pelo menos no PR). Auto-fecha a issue ao mergear (sem force-push, que
quebra o auto-close).

## Checklist antes de commitar

- [ ] Mensagem segue `tipo(escopo): descrição` em PT-BR (≤ 72 chars no título).
- [ ] Tipo do commit bate com tipo do branch atual.
- [ ] Arquivos agrupados fazem sentido juntos; sem mudanças não relacionadas.
- [ ] `git add` seletivo; **nada sensível** staged (vault master, `.mcp.json`,
      `settings.local.json`, chaves).
- [ ] Trailing `Co-Authored-By` presente.
- [ ] `Closes #N` se aplicável.

## Pre-commit (verificações úteis)

```bash
# Vault decripta?
ansible localhost -m debug -a "var=<secret_alterado>" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local

# Playbooks com sintaxe OK?
for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check; done

# Inventory parseia?
ansible-inventory -i inventory/prod --list > /dev/null && echo OK
```
