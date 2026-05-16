# Automações por serviço

Cada arquivo nesta pasta lista o **backlog de automações operacionais** para um serviço da stack, com link para as issues correspondentes no GitHub.

Diferente do `docs/ROLES.md` (que documenta *o que cada role faz*), esta pasta foca em **operações em cima do serviço já provisionado**: cron jobs, scripts auxiliares, integrações entre serviços, hooks de provisionamento, observabilidade extra.

A fonte da verdade das ideias é [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) (89 issues, versionadas e idempotentes via [`scripts/create-automation-issues.py`](../../scripts/create-automation-issues.py)).

## Padrão de cada arquivo

```markdown
# <Serviço>

(1 parágrafo: o que faz, link para a role)

## Backlog de automações
(Tabela: Prioridade × Issue × Título)

## Ver todas no GitHub
(Filtro com label do serviço + label automation)

## Como adicionar uma ideia nova
(Edit YAML → dry-run → create → update doc)
```

## Índice

| Serviço | Doc | Issues abertas | Filtro GitHub |
|---|---|---|---|
| Vaultwarden | [`vaultwarden.md`](vaultwarden.md) | 12 | [label:vaultwarden+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avaultwarden+label%3Aautomation) |
| Headscale | [`headscale.md`](headscale.md) | 9 | [label:headscale+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Aheadscale+label%3Aautomation) |
| SFTP Go | [`sftpgo.md`](sftpgo.md) | 8 | [label:sftpgo+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Asftpgo+label%3Aautomation) |
| MinIO | [`minio.md`](minio.md) | 7 | [label:minio+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Aminio+label%3Aautomation) |
| PostgreSQL | [`postgres.md`](postgres.md) | 8 | [label:postgres+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Apostgres+label%3Aautomation) |
| Uptime Kuma | [`uptime-kuma.md`](uptime-kuma.md) | 15 | [label:uptime-kuma+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Auptime-kuma+label%3Aautomation) |
| Valkey | [`valkey.md`](valkey.md) | 6 | [label:valkey+automation](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avalkey+label%3Aautomation) |

> "Issues abertas" inclui issues com múltiplos labels de serviço (ex: monitor Postgres no Uptime Kuma aparece em ambos). Total único: **59 issues no aerobi-ansible**.

## Repo irmão

O projeto legado [`elvisea/ansible-vps`](https://github.com/elvisea/ansible-vps) tem subset adaptado: **30 issues** focando em serviços que ele tem (Postgres, MinIO, Vaultwarden, Nginx, Fail2Ban, transversal). Filtro: [is:open+label:automation](https://github.com/elvisea/ansible-vps/issues?q=is%3Aopen+is%3Aissue+label%3Aautomation).

## Convenções

- **Prioridade**: 🔴 Alta (corta dor recorrente ou previne incidente) / 🟡 Média (melhora ergonomia) / 🟢 Baixa (nice-to-have).
- **Esforço** (na issue): Alto > 2 dias, Médio 4h–2d, Baixo < 4h.
- Cada issue segue o template `.github/ISSUE_TEMPLATE/automation.md` com seções Contexto → Escopo → Solução proposta → Critério de aceite → Esforço/Impacto → Referências.

## Princípios

1. **Idempotência sempre**: scripts rodam várias vezes sem dano.
2. **Falhar ruidosamente**: erro em cron envia alerta (e-mail/Telegram/Uptime Kuma push).
3. **Nunca logar secrets em plaintext**: usar pipes diretos; nada em `~/.bash_history`, `~/.zsh_history`, `journalctl`.
4. **Source-of-truth claro**: para cada credencial, declarar onde mora a verdade (vault.yml ou Vaultwarden). Sync é unidirecional na direção declarada.
5. **Reversível**: toda automação deve ter rollback documentado. Se o cron quebrou produção, como volta?

## Workflow para implementar uma issue

1. Escolha uma issue (preferência por 🔴 Alta + Baixo esforço).
2. Crie branch `feat/<tipo>-<descrição-kebab>` referenciando a issue: `feat/vaultwarden-backup-cron-#28`.
3. Implemente seguindo o que está na issue (Escopo + Solução proposta).
4. Atualize o doc do serviço com link para a PR.
5. Fecha a issue ao fazer merge (PR description com `Closes #<num>`).

## Como adicionar uma ideia nova ao backlog

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) com entrada nova:
   ```yaml
   - repo: atzaero/aerobi-ansible
     title: "feat(<serviço>): <descrição>"
     labels: [automation, <serviço>, priority-{high|medium|low}]
     milestone: "Automações backlog"
     body: |
       ## Contexto
       ...
   ```
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar a issue (idempotente — pula as existentes).
4. Atualize a tabela no doc do serviço com a entrada nova.
