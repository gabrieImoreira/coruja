#!/usr/bin/env python3
"""
Converte uma referência em texto corrido (sem timestamp por segmento — o
formato que sai do coconote e de outros serviços de nuvem) para o
reference.json que eval_transcript.py espera.

Sem timestamp por trecho, não dá pra medir "alucinação por minuto de
silêncio" nem DER — o único segmento cobre a gravação inteira, então
"silêncio" = 0 por construção. O que continua válido e é o que importa aqui:
WER, taxa de inserção (é o proxy direto da coluna de "E aí"), CER, recall de
glossário, e fala perdida (medida como cobertura da hipótese sobre a
gravação inteira, não por trecho).

Uso
---
    python3 scripts/reference_from_text.py \\
        --text referencias/2026-08-03-15h06/reference.txt \\
        --duration-s 5206.13 \\
        --out referencias/2026-08-03-15h06/reference.json

Duração: pegue com `afinfo audio.m4a | grep duration` na pasta da sessão.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--text", type=Path, required=True)
    p.add_argument("--duration-s", type=float, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    text = args.text.read_text(encoding="utf-8").strip()
    reference = {
        "duration_s": args.duration_s,
        "segments": [
            {"speaker": None, "start_ms": 0, "end_ms": int(args.duration_s * 1000), "text": text},
        ],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(reference, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {args.out} ({len(text.split())} words, {args.duration_s:.0f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
