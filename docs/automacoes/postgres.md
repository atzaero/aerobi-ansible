# PostgreSQL — automações

Banco compartilhado entre apps (aerobi-api, vaultwarden, headscale). Provisionado por `roles/postgres` + `roles/postgres_databases`. Exposto via socat em `100.64.0.1:5432` para clientes admin (DBeaver).

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `postgres` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **backup pg_dump diário em MinIO (RPO 24h hoje) e WAL archiving para PITR (RPO segundos).**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#66](https://github.com/atzaero/aerobi-ansible/issues/66) | feat(postgres): backup pg_dump diário → MinIO com retention 30d |
| 🔴 Alta | [#45](https://github.com/atzaero/aerobi-ansible/issues/45) | feat(headscale): incluir DB headscale no backup do postgres → MinIO |
| 🟡 Média | [#71](https://github.com/atzaero/aerobi-ansible/issues/71) | feat(postgres): monitor de conexões/locks via pg_stat_activity |
| 🟡 Média | [#70](https://github.com/atzaero/aerobi-ansible/issues/70) | feat(postgres): VACUUM ANALYZE schedule (manutenção) |
| 🟡 Média | [#69](https://github.com/atzaero/aerobi-ansible/issues/69) | feat(postgres): monitor de slow queries → alerta |
| 🟡 Média | [#68](https://github.com/atzaero/aerobi-ansible/issues/68) | feat(postgres): habilitar pgAudit para audit log de queries |
| 🟡 Média | [#67](https://github.com/atzaero/aerobi-ansible/issues/67) | feat(postgres): WAL archiving para Point-In-Time-Recovery (PITR) |
| 🟢 Baixa | [#72](https://github.com/atzaero/aerobi-ansible/issues/72) | research(postgres): replicação master/replica para HA (futuro) |

## Ver todas no GitHub

[Issues abertas com label `postgres` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Apostgres+label%3Aautomation)

## Reuso em outros projetos

As automações de PostgreSQL também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `postgres` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, postgres, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
