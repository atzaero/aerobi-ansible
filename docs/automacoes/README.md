# Automações por serviço

Cada arquivo nesta pasta lista o que **já está automatizado**, o que **dá pra automatizar** (backlog priorizado), **scripts úteis** prontos para copiar/colar, e **riscos/gotchas** de cada categoria de automação para o serviço correspondente.

Diferente do `docs/ROLES.md` (que documenta *o que cada role faz*), esta pasta foca em **operações em cima do serviço já provisionado**: cron jobs, scripts auxiliares, integrações entre serviços, hooks de provisionamento, observabilidade extra.

## Padrão de cada arquivo

```markdown
# <Serviço>

(1 parágrafo: o que faz, link para a role)

## O que já está automatizado
(Cron jobs ativos, hooks no playbook, scripts em produção)

## Ideias e backlog
(Tabela: ideia × impacto × esforço × dependências)
(Para cada ideia priorizada, mini-spec de como implementar)

## Scripts úteis
(One-liners e snippets prontos para copiar)

## Riscos e gotchas
(O que pode dar errado se a automação rodar mal)
```

## Índice

| Serviço | Arquivo | Status do doc |
| --- | --- | --- |
| Vaultwarden | [`vaultwarden.md`](vaultwarden.md) | ✅ Inicial |
| Headscale | `headscale.md` | 🚧 Pendente |
| SFTP Go | `sftpgo.md` | 🚧 Pendente |
| MinIO | `minio.md` | 🚧 Pendente |
| PostgreSQL | `postgres.md` | 🚧 Pendente |
| Uptime Kuma | `uptime-kuma.md` | 🚧 Pendente |
| Valkey | `valkey.md` | 🚧 Pendente |

## Convenções

- **Impacto**: quanto reduz fricção/risco operacional. Alto (corta dor recorrente ou previne incidente), Médio (melhora ergonomia), Baixo (nice-to-have).
- **Esforço**: trabalho para implementar **e manter** (não só fazer rodar uma vez). Alto > 2 dias, Médio 4h–2d, Baixo < 4h.
- **Dependências**: outros serviços/scripts que precisam estar prontos.

## Princípios

1. **Idempotência sempre**: scripts rodam várias vezes sem dano.
2. **Falhar ruidosamente**: erro em cron envia alerta (e-mail/Telegram/Uptime Kuma push).
3. **Nunca logar secrets em plaintext**: usar pipes diretos; nada em `~/.bash_history`, `~/.zsh_history`, `journalctl`.
4. **Source-of-truth claro**: para cada credencial, declarar onde mora a verdade (vault.yml ou Vaultwarden). Sync é unidirecional na direção declarada.
5. **Reversível**: toda automação deve ter rollback documentado. Se o cron quebrou produção, como volta?
