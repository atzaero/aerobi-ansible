#!/usr/bin/env python3
"""
create-automation-issues.py

Lê scripts/issue-content/automacoes.yml e cria issues no GitHub via
`gh issue create`. Idempotente: antes de criar, busca por título exato
no repo destino; se já existe (open ou closed), pula.

Uso:
    ./scripts/create-automation-issues.py            # cria todas pendentes
    ./scripts/create-automation-issues.py --dry-run  # só lista o que faria
    ./scripts/create-automation-issues.py --repo atzaero/aerobi-ansible  # filtra

Dependências: yq (pyyaml), gh CLI logado.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("✗ Falta PyYAML. Instale com: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).parent.parent
YAML_PATH = REPO_ROOT / "scripts" / "issue-content" / "automacoes.yml"


def gh_json(*args):
    """Chama gh e retorna JSON parseado."""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def issue_exists(repo, title):
    """True se já existe issue (open ou closed) com título EXATO no repo."""
    # gh issue list aceita --search; usamos isso para reduzir resposta.
    try:
        result = subprocess.run(
            [
                "gh",
                "issue",
                "list",
                "--repo",
                repo,
                "--state",
                "all",
                "--search",
                f'in:title "{title}"',
                "--limit",
                "20",
                "--json",
                "title",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        items = json.loads(result.stdout)
        return any(item["title"] == title for item in items)
    except subprocess.CalledProcessError as e:
        print(f"  ⚠ Erro ao verificar duplicação em {repo}: {e.stderr}", file=sys.stderr)
        return False


def create_issue(repo, title, body, labels, milestone, dry_run=False):
    """Cria uma issue. Retorna URL ou None."""
    if issue_exists(repo, title):
        print(f"  [skip] {title}  (já existe em {repo})")
        return None

    if dry_run:
        print(f"  [dry]  {title}  → {repo} [{','.join(labels)}]")
        return None

    cmd = [
        "gh",
        "issue",
        "create",
        "--repo",
        repo,
        "--title",
        title,
        "--body",
        body,
    ]
    if labels:
        cmd.extend(["--label", ",".join(labels)])
    if milestone:
        cmd.extend(["--milestone", milestone])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        url = result.stdout.strip()
        print(f"  [ok]   {title}")
        print(f"         {url}")
        return url
    except subprocess.CalledProcessError as e:
        print(f"  [fail] {title}", file=sys.stderr)
        print(f"         stderr: {e.stderr}", file=sys.stderr)
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="só listar, não criar")
    parser.add_argument(
        "--repo",
        help="filtrar por repo (ex: atzaero/aerobi-ansible)",
    )
    parser.add_argument(
        "--service",
        help="filtrar por serviço/grupo (ex: vaultwarden, headscale)",
    )
    args = parser.parse_args()

    if not YAML_PATH.exists():
        print(f"✗ {YAML_PATH} não existe.", file=sys.stderr)
        sys.exit(1)

    with open(YAML_PATH) as f:
        data = yaml.safe_load(f)

    issues = data.get("issues", [])
    if not issues:
        print("✗ Arquivo YAML sem issues.", file=sys.stderr)
        sys.exit(1)

    # Agrupa por repo para output organizado.
    by_repo = {}
    for issue in issues:
        if args.repo and issue["repo"] != args.repo:
            continue
        if args.service and args.service not in issue.get("labels", []):
            continue
        by_repo.setdefault(issue["repo"], []).append(issue)

    total = sum(len(v) for v in by_repo.values())
    print(f"→ Total a processar: {total} issues em {len(by_repo)} repos")
    print()

    created, skipped, failed = 0, 0, 0

    for repo, repo_issues in by_repo.items():
        print(f"=== {repo} ({len(repo_issues)} issues) ===")
        for issue in repo_issues:
            result = create_issue(
                repo=repo,
                title=issue["title"],
                body=issue["body"],
                labels=issue.get("labels", []),
                milestone=issue.get("milestone"),
                dry_run=args.dry_run,
            )
            if result is None and not args.dry_run:
                # Verifica se foi skip (já existe) ou fail (erro)
                if issue_exists(repo, issue["title"]):
                    skipped += 1
                else:
                    failed += 1
            elif args.dry_run:
                skipped += 1  # contabiliza no dry-run
            else:
                created += 1
        print()

    print(f"✓ Resumo: criadas={created}, puladas (já existiam)={skipped}, falhas={failed}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
