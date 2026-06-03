# Merge

Merge de PR aprovado em `main` (repo `atzaero/aerobi-ansible`), com cleanup local.

## Pré-requisitos

- PR já aberto via `/pr`.
- CI verde (todos os checks passando).
- PR `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`.

## Workflow

1. **Verificar status** (em paralelo):
   ```bash
   gh pr checks <num> --repo atzaero/aerobi-ansible
   gh pr view <num> --repo atzaero/aerobi-ansible --json mergeable,mergeStateStatus
   ```

2. **Se algum check estiver pendente**: aguardar (não fazer merge cego).
   **Se algum check falhar**: investigar, NÃO mergear, pedir orientação.

3. **Merge + cleanup remoto + sync local** — tudo em um comando:
   ```bash
   gh pr merge <num> --repo atzaero/aerobi-ansible --merge --delete-branch && \
     git checkout main && git pull && \
     git branch -d <branch> 2>/dev/null; \
     git fetch --prune && \
     git log --oneline -3
   ```

4. **Confirmar** — verificar que:
   - Último commit em main é o merge esperado.
   - Branch local foi deletada.
   - `git status` mostra working tree clean.

## Estratégia: `--merge` (não `--squash`)

- Padrão deste repo: **merge commit**, preserva histórico.
- `--squash` perde os commits intermediários (úteis pra debug retroativo).
- Não usar `--rebase` na merge — gera lineage linear mas remove o "PR boundary".

## Apply em prod só DEPOIS do merge

Regra inviolável do projeto: `main` reflete o estado real da VPS. Só rodar
`ansible-playbook` em prod **depois** do merge — nunca antes. Se for tailnet-only,
não esquecer o passo dos `headscale_extra_dns_records` + reaplicar
`setup_headscale.yml` (ver `AGENTS.md` regra 1).

## Quando uma issue não auto-fecha

Causas comuns:

- Force-push no branch após PR aberto → o ref do `Closes #N` perde o vínculo com a
  SHA do merge.
- `Closes #N` ausente do commit/PR body.

Workaround:

```bash
gh issue close <num> --repo atzaero/aerobi-ansible \
  --comment "Resolvido via PR #<pr-num>"
```

## Anti-padrões

❌ Mergear com checks pendentes (sem ver se vão passar).
❌ Mergear PR com falha de CI sem investigar.
❌ Force-merge (`gh pr merge --admin`) — só com motivo claro.
❌ Esquecer de sincronizar `main` local após merge.
❌ Rodar apply em prod antes do merge.

## Próximos passos

Reportar pro usuário:
- URL do merge commit (ou hash).
- Issue auto-fechada (se aplicável).
- Próxima tarefa do plano (se houver), incluindo apply em prod se for o caso.
