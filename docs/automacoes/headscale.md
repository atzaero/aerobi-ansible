# Headscale — automações

Control plane VPN self-hosted. Provisionado por `roles/headscale`, exposto em `headscale.aerobi.com.br`. Distribui Magic DNS para clientes da tailnet.

## Backlog de automações

Cada item abaixo é uma issue aberta no aerobi-ansible com label `headscale` + `automation`. Body completo, critério de aceite e referências estão na issue.

Priorize por impacto: **rotação de pre-auth keys (sem isso a VPS reiniciada não reconecta) e backup do DB postgres (perda = reconfigurar todos clientes do zero).**

| Prioridade | Issue | Título |
|---|---|---|
| 🔴 Alta | [#46](https://github.com/atzaero/aerobi-ansible/issues/46) | feat(headscale): rotação automática de pre-auth keys com alerta 7d antes da expiração |
| 🔴 Alta | [#45](https://github.com/atzaero/aerobi-ansible/issues/45) | feat(headscale): incluir DB headscale no backup do postgres → MinIO |
| 🟡 Média | [#88](https://github.com/atzaero/aerobi-ansible/issues/88) | feat(ops): renovação automatizada de pre-auth keys do tailscale via cron |
| 🟡 Média | [#49](https://github.com/atzaero/aerobi-ansible/issues/49) | feat(headscale): monitor canário no Uptime Kuma (API + tailnet alive) |
| 🟡 Média | [#48](https://github.com/atzaero/aerobi-ansible/issues/48) | feat(headscale): validar ACL em CI antes de aplicar (JSON + lógica) |
| 🟡 Média | [#47](https://github.com/atzaero/aerobi-ansible/issues/47) | feat(headscale): cleanup automático de nodes inativos > 90 dias |
| 🟡 Média | [#37](https://github.com/atzaero/aerobi-ansible/issues/37) | feat(vaultwarden): script de onboarding automatizado de novo membro (VW + Headscale + SFTPGo) |
| 🟢 Baixa | [#51](https://github.com/atzaero/aerobi-ansible/issues/51) | feat(headscale): versionar mudanças na ACL com diff visível |
| 🟢 Baixa | [#50](https://github.com/atzaero/aerobi-ansible/issues/50) | feat(headscale): relatório semanal de devices conectados via API |

## Ver todas no GitHub

[Issues abertas com label `headscale` + `automation`](https://github.com/atzaero/aerobi-ansible/issues?q=is%3Aopen+is%3Aissue+label%3Aheadscale+label%3Aautomation)

## Reuso em outros projetos

As automações de Headscale também aplicam ao `elvisea/ansible-vps` (legado). Issues equivalentes lá têm o mesmo label `headscale` (se aplicável).

## Como adicionar uma ideia nova

1. Edite [`scripts/issue-content/automacoes.yml`](../../scripts/issue-content/automacoes.yml) adicionando entrada com `labels: [automation, headscale, priority-X]`.
2. Rode `./scripts/create-automation-issues.py --dry-run` para validar.
3. Rode `./scripts/create-automation-issues.py` para criar.
4. Atualize este documento com a nova entrada na tabela.
