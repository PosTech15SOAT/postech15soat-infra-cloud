#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
diagram_dir="$repo_root/doc/diagrams/cloud"
source_file="$diagram_dir/numberone.drawio"

if ! command -v drawio >/dev/null 2>&1; then
  echo "Erro: o comando 'drawio' não foi encontrado no PATH." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Erro: o comando 'python3' não foi encontrado no PATH." >&2
  exit 1
fi

if [[ ! -f "$source_file" ]]; then
  echo "Erro: fonte Draw.io não encontrada: $source_file" >&2
  exit 1
fi

pages="$({
  python3 - "$source_file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

source = sys.argv[1]

try:
    root = ET.parse(source).getroot()
except (ET.ParseError, OSError) as error:
    print(f"Erro ao ler o XML Draw.io: {error}", file=sys.stderr)
    raise SystemExit(1)

seen = set()
pages = list(root.findall("./diagram"))
if not pages:
    print("Erro: nenhum elemento <diagram> foi encontrado no fonte Draw.io.", file=sys.stderr)
    raise SystemExit(1)

for index, diagram in enumerate(pages):
    name = diagram.get("name")
    if not name:
        print(f"Erro: a página no índice {index} não possui atributo name.", file=sys.stderr)
        raise SystemExit(1)

    normalized = name.lower()
    normalized = re.sub(r"\s+", "-", normalized)
    normalized = re.sub(r"[^a-z0-9-]", "", normalized)
    normalized = re.sub(r"-+", "-", normalized).strip("-")

    if not normalized:
        print(
            f"Erro: o nome da página no índice {index!s} não gera um filename válido: {name!r}.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    if normalized in seen:
        print(
            f"Erro: mais de uma página normaliza para {normalized!r}; renomeie uma das abas.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    seen.add(normalized)
    print(f"{index}\t{normalized}")
PY
} )"

if [[ -z "$pages" ]]; then
  echo "Erro: nenhum diagrama foi descoberto para exportação." >&2
  exit 1
fi

count=0
while IFS=$'\t' read -r index page; do
  cli_page_index=$((index + 1))
  output_file="$diagram_dir/numberone-$page.drawio.png"

  printf 'Exportando [%s] %s\n' "$cli_page_index" "$page"
  printf '→ %s\n' "$(basename -- "$output_file")"

  drawio --export --format png --page-index "$cli_page_index" --output "$output_file" "$source_file"
  ((count += 1))
done <<< "$pages"

printf '%s diagrama(s) exportado(s).\n' "$count"
