---
name: security-audit
description: >-
  Acionar quando o usuário pedir uma revisão/auditoria de segurança ou infra do
  aerobi-ansible em linguagem natural — "audita a segurança", "revisa a infra",
  "tem secret vazando?", "checa o hardening", "isso é seguro pra subir em prod?".
  Conduz a varredura de segurança guiada por docs/SECURITY.md e reporta findings
  🔴/🟡/🔵. Não corrige automaticamente.
---

# Security Audit — aerobi-ansible

Acionar quando o usuário quiser avaliar a postura de segurança do repo/infra, seja
sobre o diff atual ou o repo inteiro.

## Procedimento

- **Diff da branch** → seguir [`.claude/commands/infra-review.md`](../../commands/infra-review.md)
  (despacha o agente `infra-reviewer`).
- **Repo inteiro / pré-prod** → seguir [`.claude/commands/security-audit.md`](../../commands/security-audit.md).

Ambos se apoiam em [`docs/SECURITY.md`](../../../docs/SECURITY.md) — leia antes.

## Lembretes rápidos

- Repo: `atzaero/aerobi-ansible` (GitHub). Alvo: VPS **pública** `187.127.6.20`
  (tailnet `100.64.0.1`), domínios em `aerobi.com.br`, **control plane Headscale
  self-hosted** + edge Raspberry Pi/MediaMTX.
- Criticidade máxima (🔴): secret em texto claro fora do vault, bind Docker em
  `0.0.0.0`, exposição tailnet via `-p` (em vez de socat sidecar), hardening
  (SSH/UFW/Fail2Ban) enfraquecido, Headscale/edge expostos, arquivo sensível
  versionado.
- Vault é **per-value** — secret real só como bloco `!vault` no `vault.yml`; default
  de role é sempre `changeme`. Master em `~/.ansible-vault/aerobi-prod`.
- vhost tailnet-only exige extra_record do Headscale (`100.64.0.1`) + reaplicar
  `setup_headscale.yml`, senão 403.
- **Não** aplicar correções automaticamente — reportar e deixar o usuário priorizar.
- Findings que viram trabalho → issue com label `security` (e/ou `automation`).
- **Não** rodar `ansible-playbook` apply nem `gh pr merge` durante a auditoria.
