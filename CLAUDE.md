# CLAUDE.md — aerobi-ansible

@AGENTS.md

O contexto canônico (produto, stack, alvos SSH, regras estritas, segurança, gitflow,
gotchas, vault, MCPs, tooling, coesão com projeto irmão) vive em
[`AGENTS.md`](AGENTS.md). Este arquivo só adiciona notas específicas do Claude Code.

## Notas Claude-específicas

- **Plan mode**: acionar antes de mudanças estruturais grandes (role nova complexa,
  refactor amplo de inventário, rotação de master do vault, adição de serviço). Skip
  pra edits triviais (typo, ajuste de var).
- **Agent Explore (`subagent_type=Explore`)**: pra pesquisas amplas no codebase
  (3+ queries) — protege o contexto principal. Pra grep/find pontual, use Bash direto.
- **Agent `isolation: worktree`**: precisa que a session tenha iniciado **dentro** do
  repo. Confirmar com `git rev-parse --show-toplevel`.
- **Tools deferidos (MCPs, WebFetch, etc.)**: usar `ToolSearch` com `select:<nome>`
  quando precisar de algo não carregado por padrão (ex: `mcp__github__*`,
  `mcp__hostinger-aerobi-mcp__*`).
- **Comandos pesados** (`ansible-playbook` apply, Molecule, build): rodar com
  `run_in_background: true` se passar de ~1 min.

## Revisão antes de PR

Antes de abrir PR, invocar o agente **`infra-reviewer`** (via `/infra-review`)
contra o diff. Pra varredura de segurança standalone do repo inteiro, usar
`/security-audit` (ou pedir em linguagem natural — dispara a skill `security-audit`).
Ambos se apoiam em [`docs/SECURITY.md`](docs/SECURITY.md).

## Slash commands

Detalhados em `.claude/commands/`. Fluxo típico: `/commit` → `/infra-review` →
`/pr` → `/merge`.
