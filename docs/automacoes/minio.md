# MinIO — automações

Object storage S3-compatible. Provisionado por `roles/minio`, exposto em `s3.aerobi.com.br` (API pública) e `s3-console.aerobi.com.br` (admin tailnet-only).

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `minio` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **bucket policies declarativas (hoje imperativo via UI) e replicação off-site (rclone) para defesa em profundidade.**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#60](https://github.com/atzaero/aerobi-ansible/issues/60) | feat(minio): replicação off-site com rclone (defesa em profundidade) |
| 🔴 Alta | [#59](https://github.com/atzaero/aerobi-ansible/issues/59) | feat(minio): bucket policies declarativas via Ansible (em vez da UI) |
| 🟡 Média | [#65](https://github.com/atzaero/aerobi-ansible/issues/65) | feat(minio): versioning em buckets críticos (uploads, backups) |
| 🟡 Média | [#63](https://github.com/atzaero/aerobi-ansible/issues/63) | feat(minio): alerta de espaço usado > 80% no Uptime Kuma |
| 🟡 Média | [#62](https://github.com/atzaero/aerobi-ansible/issues/62) | feat(minio): audit log via mc admin → push canal |
| 🟡 Média | [#61](https://github.com/atzaero/aerobi-ansible/issues/61) | feat(minio): lifecycle rules para retenção/limpeza de objetos antigos |
| 🟢 Baixa | [#64](https://github.com/atzaero/aerobi-ansible/issues/64) | feat(minio): pre-signed URL helper como serviço HTTP |

## Ver todas no GitHub

[Issues abertas com label `minio` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Aminio+label%3Aautomation)

## Reuso em outros projetos

As automações de MinIO também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `minio` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, minio, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
