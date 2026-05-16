# Uptime Kuma — automações

Status + monitoring + Domain Name Expiry. Provisionado por `roles/uptime_kuma`, exposto em `status.aerobi.com.br` (tailnet-only).

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `uptime-kuma` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **provisionamento declarativo dos monitors via Ansible (hoje só na UI; perda do volume = reconfigurar todos) e push monitors para cron jobs críticos (alerta se backup não rodar).**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#74](https://github.com/atzaero/aerobi-ansible/issues/74) | feat(uptime-kuma): backup do volume uptime_kuma_data → MinIO |
| 🔴 Alta | [#73](https://github.com/atzaero/aerobi-ansible/issues/73) | feat(uptime-kuma): provisionar monitors via Ansible (import/export JSON) |
| 🟡 Média | [#81](https://github.com/atzaero/aerobi-ansible/issues/81) | feat(valkey): monitor de memória > 80% maxmemory |
| 🟡 Média | [#77](https://github.com/atzaero/aerobi-ansible/issues/77) | feat(uptime-kuma): status page pública em status-public.aerobi.com.br |
| 🟡 Média | [#76](https://github.com/atzaero/aerobi-ansible/issues/76) | feat(uptime-kuma): integração centralizada Discord/Telegram para alertas |
| 🟡 Média | [#75](https://github.com/atzaero/aerobi-ansible/issues/75) | feat(uptime-kuma): push monitors para cron jobs críticos (backup, etc) |
| 🟡 Média | [#71](https://github.com/atzaero/aerobi-ansible/issues/71) | feat(postgres): monitor de conexões/locks via pg_stat_activity |
| 🟡 Média | [#69](https://github.com/atzaero/aerobi-ansible/issues/69) | feat(postgres): monitor de slow queries → alerta |
| 🟡 Média | [#63](https://github.com/atzaero/aerobi-ansible/issues/63) | feat(minio): alerta de espaço usado > 80% no Uptime Kuma |
| 🟡 Média | [#57](https://github.com/atzaero/aerobi-ansible/issues/57) | feat(sftpgo): monitor canário Uptime Kuma (login SFTP + upload/download) |
| 🟡 Média | [#49](https://github.com/atzaero/aerobi-ansible/issues/49) | feat(headscale): monitor canário no Uptime Kuma (API + tailnet alive) |
| 🟡 Média | [#36](https://github.com/atzaero/aerobi-ansible/issues/36) | feat(vaultwarden): monitor canário no Uptime Kuma validando DB healthy |
| 🟢 Baixa | [#90](https://github.com/atzaero/aerobi-ansible/issues/90) | feat(ops): healthcheck dashboard automático a partir do Uptime Kuma |
| 🟢 Baixa | [#79](https://github.com/atzaero/aerobi-ansible/issues/79) | feat(uptime-kuma): weekly digest report (uptime + incidentes) |
| 🟢 Baixa | [#78](https://github.com/atzaero/aerobi-ansible/issues/78) | feat(uptime-kuma): monitor de TLS expiry redundante (defesa Certbot) |

## Ver todas no GitHub

[Issues abertas com label `uptime-kuma` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Auptime-kuma+label%3Aautomation)

## Reuso em outros projetos

As automações de Uptime Kuma também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `uptime-kuma` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, uptime-kuma, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
