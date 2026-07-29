# Role: docker_events_alerter

Watcher de `docker events` que transforma crash de container em evento no
GlitchTip (errors.aerobi.com.br). Cobre o ponto cego identificado no incidente
[atzaero/aerobi-api#621](https://github.com/atzaero/aerobi-api/issues/621): o
`aerobi-api-staging` morreu por OOM fatal do V8 e o `restart: unless-stopped`
religou o container em 2s — o Uptime Kuma (HTTP) nunca viu downtime e o SDK
in-process não captura OOM (o processo aborta sem lançar erro JS).

## O que alerta

| Evento Docker | Condição | Resultado |
|---|---|---|
| `die` | `exitCode != 0` | Evento `error` no projeto infra |
| `die` | `exitCode == 0` | Ignorado (parada limpa: deploy, `docker stop`) |
| `oom` | sempre | Evento `error` (OOM-kill do cgroup) |

Cada evento leva `container`, `action`, `exit_code` (tags), `image` (extra) e
`fingerprint` por container — crash-loop vira **um issue** no GlitchTip com
contador de ocorrências, não uma enxurrada. Rate-limit local adicional de
`docker_events_alerter_min_interval_seconds` (default 60s) por container.

## Setup (uma vez)

1. Criar o projeto **infra** na org aerobi do GlitchTip (UI → Create Project,
   plataforma "Other") e configurar alert rule de email.
2. Copiar o DSN do projeto e guardar no vault:

   ```bash
   ansible-vault encrypt_string --stdin-name 'vault_docker_events_alerter_dsn' \
     --vault-password-file .vault_pass
   # colar https://KEY@errors.aerobi.com.br/N e Ctrl-D
   ```

3. Aplicar:

   ```bash
   ansible-playbook -i inventory/prod playbooks/setup_docker_events_alerter.yml
   ```

## Smoke test

```bash
# die com exit != 0 → deve aparecer no projeto infra em <1min
docker run --rm --name alerter-smoke-test alpine:3 sh -c 'exit 42'

# OOM-kill do cgroup (mem_limit proposital de 8m)
docker run --rm --name alerter-oom-test -m 8m alpine:3 \
  sh -c 'cat /dev/zero | head -c 32m | tail'

# logs do watcher
journalctl -u docker-events-alerter -n 20
```

## Operação

- Serviço: `systemctl status docker-events-alerter`
- O stream de `docker events` morre junto com o daemon Docker; o systemd
  (`Restart=always`) religa o watcher — restarts do Docker não exigem ação.
- Estado de rate-limit em `/run/docker-events-alerter/` (tmpfs, zera no boot).
- O env file `/etc/docker-events-alerter.env` contém o DSN (secret key) —
  root:root 0600; rotação = trocar no vault e reaplicar o playbook.
