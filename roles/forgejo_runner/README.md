# Role: forgejo_runner

Sobe o [Forgejo Actions Runner](https://forgejo.org/docs/latest/admin/actions/) — o motor de CI que executa os workflows do Forgejo (`.forgejo/workflows` e `.github/workflows`). Complementa a role [`forgejo`](../forgejo/README.md). Decisão arquitetural: [`docs/research/forgejo.md`](../../docs/research/forgejo.md) (issue #100).

## Como funciona

- Container `code.forgejo.org/forgejo/runner` registra-se na instância (`git.aerobi.com.br`) e fica em polling por jobs.
- Cada job roda como um **container no Docker do HOST** (socket montado). A imagem do job vem das labels (`catthehacker/ubuntu:act-22.04` para `ubuntu-latest`).
- Os job containers entram na rede **warpgate** e recebem o **docker.sock** — então os steps fazem `docker build`, sobem service containers (ex: postgres de teste) e fazem **deploy direto** (`docker compose up`) sem SSH.

## Por que docker.sock do host (e não DinD)

Escolha consciente (issue #100): o runner também faz o **deploy**, que precisa alcançar os containers de produção na warpgate — DinD ficaria isolado e exigiria SSH. Como **controlamos todo o código** (sem PRs de terceiros não-confiáveis), o acesso ao socket do host é aceitável e simplifica build+test+deploy num só lugar. O container roda como **root** porque a imagem (uid 1000) não acessa o socket; isso não amplia o risco (o sock já é root-equivalente).

## Registro sem secret no vault

O token de registro é **efêmero**: gerado em apply-time via `docker exec forgejo forgejo actions generate-runner-token`, e **só** quando o runner ainda não se registrou (sem `.runner` no `data_dir`). O runner persiste a própria credencial no `.runner` → idempotente, sem secret novo no vault.

## Pré-requisitos

| Item | Por quê |
|---|---|
| `forgejo` rodando, Actions habilitado | Instância para registrar + buscar jobs |
| `docker` + `docker_network` | Container + rede warpgate |

## Variáveis principais

Defaults em `defaults/main.yml`:

| Var | Default | Nota |
|---|---|---|
| `forgejo_runner_version` | `12.10.2` | pin verificado com `docker manifest inspect` |
| `forgejo_runner_capacity` | `1` | jobs simultâneos — subir quando houver folga na VPS |
| `forgejo_runner_labels` | `ubuntu-latest:.../act-22.04,...` | mapeia `runs-on` → imagem de job |
| `forgejo_runner_instance_url` | `https://git.aerobi.com.br` | URL pública (cache/artifact corretos) |

## Como aplicar

```bash
ansible-playbook -i inventory/prod playbooks/setup_forgejo_runner.yml
```

Verificar: Site Admin → Actions → Runners (ou `GET /api/v1/admin/actions/runners`) mostra `vps-runner` online com as labels.

## Não coberto (follow-up — nos repos dos apps)

Migrar `ci.yml`/`release.yml` de `aerobi`/`aerobi-api` para o Forgejo Actions: registry GHCR → `git.aerobi.com.br`, plugin Forgejo do `semantic-release`, deploy local (em vez de SSH) e re-criação dos poucos secrets de deploy que sobrarem.
