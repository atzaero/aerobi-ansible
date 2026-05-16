# Valkey — automações

Fork OSS do Redis: cache + filas + sessões. Provisionado por `roles/valkey`. Sem vhost público; apps acessam via rede docker `warpgate`.

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `valkey` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **backup snapshot RDB diário e monitor de uso de memória (cheio = evictions agressivas degradando apps).**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#80](https://github.com/atzaero/aerobi-ansible/issues/80) | feat(valkey): backup snapshot RDB diário → MinIO |
| 🟡 Média | [#83](https://github.com/atzaero/aerobi-ansible/issues/83) | feat(valkey): ACL users granulares via Ansible (em vez de default user só) |
| 🟡 Média | [#82](https://github.com/atzaero/aerobi-ansible/issues/82) | feat(valkey): audit via SLOWLOG + KEYSPACE notifications |
| 🟡 Média | [#81](https://github.com/atzaero/aerobi-ansible/issues/81) | feat(valkey): monitor de memória > 80% maxmemory |
| 🟢 Baixa | [#85](https://github.com/atzaero/aerobi-ansible/issues/85) | research(valkey): replicação master/replica para HA |
| 🟢 Baixa | [#84](https://github.com/atzaero/aerobi-ansible/issues/84) | research(valkey): cluster mode quando volume crescer |

## Ver todas no GitHub

[Issues abertas com label `valkey` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Avalkey+label%3Aautomation)

## Reuso em outros projetos

As automações de Valkey também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `valkey` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, valkey, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
