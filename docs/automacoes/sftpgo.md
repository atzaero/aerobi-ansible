# SFTP Go — automações

Servidor SFTP em Go com web admin. Provisionado por `roles/sftpgo` + `roles/sftpgo_tailnet_proxy`, exposto via tailnet em `100.64.0.1:2022` e web admin em `sftp.aerobi.com.br` (tailnet-only).

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `sftpgo` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **backup do volume sftpgo_data (uploads + SQLite + host keys) e users declarativos via Ansible (hoje manuais via UI).**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#53](https://github.com/atzaero/aerobi-ansible/issues/53) | feat(sftpgo): provisionar users SFTP via Ansible (declarativo) |
| 🔴 Alta | [#52](https://github.com/atzaero/aerobi-ansible/issues/52) | feat(sftpgo): backup do volume sftpgo_data no MinIO |
| 🟡 Média | [#57](https://github.com/atzaero/aerobi-ansible/issues/57) | feat(sftpgo): monitor canário Uptime Kuma (login SFTP + upload/download) |
| 🟡 Média | [#56](https://github.com/atzaero/aerobi-ansible/issues/56) | feat(sftpgo): retention policy para uploads antigos > 90 dias |
| 🟡 Média | [#55](https://github.com/atzaero/aerobi-ansible/issues/55) | feat(sftpgo): quotas padrão por user (10GB) + alerta de uso > 80% |
| 🟡 Média | [#54](https://github.com/atzaero/aerobi-ansible/issues/54) | feat(sftpgo): audit log de uploads/downloads → notificação push |
| 🟡 Média | [#37](https://github.com/atzaero/aerobi-ansible/issues/37) | feat(vaultwarden): script de onboarding automatizado de novo membro (VW + Headscale + SFTPGo) |
| 🟢 Baixa | [#58](https://github.com/atzaero/aerobi-ansible/issues/58) | feat(sftpgo): hook de upload completo → notificação aerobi-api |

## Ver todas no GitHub

[Issues abertas com label `sftpgo` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Asftpgo+label%3Aautomation)

## Reuso em outros projetos

As automações de SFTP Go também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `sftpgo` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, sftpgo, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
