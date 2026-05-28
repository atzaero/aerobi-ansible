# Role: forgejo_runner

Sobe o [Forgejo Actions Runner](https://forgejo.org/docs/latest/admin/actions/) — o motor de CI que executa os workflows do Forgejo (`.forgejo/workflows` e `.github/workflows`). Complementa a role [`forgejo`](../forgejo/README.md). Decisão arquitetural: [`docs/research/forgejo.md`](../../docs/research/forgejo.md) (issue #100).

## Como funciona

- Container `code.forgejo.org/forgejo/runner` registra-se na instância (`git.aerobi.com.br`) e fica em polling por jobs.
- Cada job roda como um **container no Docker do HOST** (socket montado). A imagem do job vem das labels (`catthehacker/ubuntu:act-22.04` para `ubuntu-latest`).
- Cada job + seus service containers rodam numa **rede isolada** criada pelo runner (NÃO a warpgate). Isso evita que um service de teste (ex: `postgres`) colida por nome com o postgres de **produção** na warpgate. Os steps recebem o **docker.sock** → fazem `docker build`, sobem service containers de teste e (no futuro) `docker compose up` para deploy — e os containers deployados entram na warpgate via o próprio `compose` (`networks.external`), sem o job precisar estar nela.

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
| `forgejo_runner_capacity` | `2` | jobs simultâneos (validado: 14Gi RAM livres). Subir mais só monitorando CPU/RAM (sem swap) |
| `forgejo_runner_job_memory` | `4g` | limite de RAM por job — confina OOM ao container (VPS sem swap) |
| `forgejo_runner_toolcache_dir` | `/home/deploy/forgejo-runner/toolcache` | toolcache persistente (Node do `setup-node` reusado entre runs) |
| `forgejo_runner_labels` | `ubuntu-latest:.../act-22.04,...` | mapeia `runs-on` → imagem de job |
| `forgejo_runner_instance_url` | `https://git.aerobi.com.br` | URL pública (cache/artifact corretos) |

### Performance

- **Toolcache persistente**: a imagem de job (`catthehacker/ubuntu:act-22.04`) traz Node 24 no PATH mas com `/opt/hostedtoolcache` **vazio**; os apps pedem Node 22 (`.nvmrc`), então o `setup-node` baixava o Node 22 a cada run (~5 min). Montando um diretório do host em `/opt/hostedtoolcache`, o download vira custo único — runs seguintes reusam.
- **Capacity 2**: dois jobs em paralelo (ex: `aerobi` e `aerobi-api` não ficam mais em fila). Cada job limitado a `forgejo_runner_job_memory`.
- CI self-hosted é mais lento que a frota do GitHub na **primeira** run (imagem/Node/npm/build frios). As seguintes aquecem os caches (toolcache, cache npm via cache server embutido, cache do Next).

## Como aplicar

```bash
ansible-playbook -i inventory/prod playbooks/setup_forgejo_runner.yml
```

Verificar: Site Admin → Actions → Runners (ou `GET /api/v1/admin/actions/runners`) mostra `vps-runner` online com as labels.

## Não coberto (follow-up — nos repos dos apps)

Migrar `ci.yml`/`release.yml` de `aerobi`/`aerobi-api` para o Forgejo Actions: registry GHCR → `git.aerobi.com.br`, plugin Forgejo do `semantic-release`, deploy local (em vez de SSH) e re-criação dos poucos secrets de deploy que sobrarem.
