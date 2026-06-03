# Infra Review

Revisa o diff da branch atual com foco em **infraestrutura e segurança**, antes do PR.

## O que faz

Invoca o agente dedicado **`infra-reviewer`** (`.claude/agents/infra-reviewer.md`)
contra o diff `main...HEAD`. O agente aplica o checklist de
[`docs/SECURITY.md`](../../docs/SECURITY.md) + os gotchas do `AGENTS.md` e devolve
findings classificados:

- 🔴 **Crítico** — bloqueia merge (secret em texto claro, bind Docker em `0.0.0.0`,
  exposição tailnet via `-p`, hardening enfraquecido, Headscale/edge expostos,
  arquivo sensível versionado).
- 🟡 **Aviso** — idempotência, falta de `no_log`, fail-fast ausente, tailnet-only sem
  extra_record do Headscale, convenção.
- 🔵 **Sugestão** — melhoria opcional.

## Workflow

1. Confirmar que está numa feature branch (não em `main`) e que há diff vs `main`.
2. Despachar o agente `infra-reviewer` (via Agent tool, `subagent_type=infra-reviewer`).
3. Apresentar o relatório ao usuário **sem aplicar correções** — o agente só reporta.
4. Para 🔴: corrigir antes de seguir pro `/pr`. Para 🟡/🔵: decidir com o usuário.

## Quando usar

- Sempre antes de `/pr`, principalmente se o diff toca `roles/`, `inventory/`,
  `vault.yml`, `nginx_vhost`, `firewall`, `ssh_hardening`, `headscale`, os proxies
  tailnet (`*_tailnet_proxy`) ou containers Docker.
- Para varredura de segurança do repo **inteiro** (não só do diff), use
  `/security-audit`.

## Notas

- O agente **não** edita arquivos, não aprova merge, não roda apply. Revisão pura.
- Se o diff estiver vazio ou a branch errada, o agente avisa e para.
- Diff >500 linhas: o agente prioriza `roles/`/`inventory/`/`playbooks/` e sinaliza
  revisão parcial.
