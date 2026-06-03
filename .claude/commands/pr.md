# Pull Request

Cria PR pra mergear branch atual em `main` (repo `atzaero/aerobi-ansible`).

## Pré-requisitos

- Estar em branch `<tipo>/<num-issue>-<slug>` (ver `/commit`).
- Ter pelo menos 1 commit local.
- Issue GitHub correspondente existir.

## Workflow

1. **Verificar estado da branch** — em paralelo:
   - `git status` (sem unstaged?)
   - `git diff main...HEAD` (entender o conjunto completo, não só último commit)
   - `git log main..HEAD --oneline` (lista de commits)
   - `git fetch origin main && git rev-list HEAD..origin/main --count`
     (se 0, branch está atualizada com main; se > 0, rebase antes)

2. **Validar localmente** antes de subir:
   ```bash
   for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check; done
   ansible-inventory -i inventory/prod --list > /dev/null
   ```

3. **Push** — `git push -u origin <branch>`. Se a branch já existir no remoto
   (rebase com origin), `--force-with-lease` é o seguro.

4. **Criar PR** — `gh pr create --base main --repo atzaero/aerobi-ansible` com
   título + body via HEREDOC.

## Template de PR

Título: igual ao primeiro commit (ou resumo de 1 linha do conjunto).

Body:

```markdown
## Summary

- 1-3 bullets do que mudou e **por quê** (não só o quê — o diff já mostra).

## Decisões locked (opcional)

Quando o PR carrega decisões que precisam ser explicadas (trade-offs, padrões
escolhidos), listar aqui em vez de embolar no Summary.

## Validação

```
$ ansible-playbook playbooks/<x>.yml --syntax-check     # OK
$ ansible-inventory -i inventory/prod --list             # parse OK
$ ansible localhost -m debug -a "var=<secret>" ...       # decripta OK
```

## Test plan

- [x] Mudanças passam em syntax-check
- [x] Inventory parseia
- [x] (Se mexeu em vault) decryption validada
- [ ] Após merge: bootstrap fresh aplica mudança corretamente
- [ ] (Se mexeu em role) `ansible-playbook setup_<role>.yml` em VPS dev
- [ ] (Se tailnet-only) extra_records do Headscale aplicado + acesso via tailnet OK

## Fora de escopo (opcional)

- Coisas relacionadas mas que viram issues/PRs separados.

Closes #N

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Regras

- **Base sempre `main`** — não tem `develop` neste repo. Usar
  `--repo atzaero/aerobi-ansible`.
- `Closes #N` no body (não no title) — auto-fecha a issue ao mergear.
- **Sem force-push** após PR aberto — quebra auto-close de `Closes #N`.
- **Sem `--no-verify`** ou skip de hooks — investigar falha em vez de pular.
- Cada PR resolve idealmente uma issue. Se 2+, mencionar todas em `Closes`.

## Comando completo

```bash
gh pr create --base main --repo atzaero/aerobi-ansible \
  --title "tipo(escopo): título curto" \
  --body "$(cat <<'EOF'
## Summary
- ...

## Validação
- ...

## Test plan
- [x] ...

Closes #N

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Após criar

Reportar URL pro usuário. Próximo passo natural é `/merge` quando CI passar.

## Quando NÃO criar PR ainda

- Pre-checks locais falhando — corrigir antes.
- Branch não tem issue correspondente — criar issue primeiro.
- Mudanças sensíveis em `vault.yml` que não decriptam — algo errado, fix antes.
