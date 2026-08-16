#!/usr/bin/env python3
"""
Benchmark de transcrição para a coruja — stdlib only, sem dependências.

Não ajuste nenhum parâmetro do decoder sem rodar isto antes e depois. As
regressões que importam aqui (alucinação em silêncio, fala perdida) não
aparecem no WER agregado: um transcript que inventa 200 "E aí" e outro que
perde 25 s de fala podem ter WER parecido e utilidade oposta. Por isso as
métricas são separadas.

Uso
---
    # uma sessão
    python3 scripts/eval_transcript.py \\
        --ref referencias/2026-08-01/reference.json \\
        --hyp ~/Recordings/"2026-08-01 21h50"/.transcript.json

    # comparar duas configurações no mesmo conjunto
    python3 scripts/eval_transcript.py --suite referencias/ --hyp-dir baseline/ --label baseline
    python3 scripts/eval_transcript.py --suite referencias/ --hyp-dir com-vad/  --label com-vad

Formato da referência (JSON)
----------------------------
    {
      "duration_s": 612.0,
      "segments": [
        {"speaker": "eu",      "start_ms": 1200,  "end_ms": 4800,  "text": "..."},
        {"speaker": "alisson", "start_ms": 5100,  "end_ms": 9300,  "text": "..."}
      ]
    }

`speaker` é opcional; sem ele o DER é omitido. As regiões NÃO cobertas por
nenhum segmento da referência são tratadas como silêncio — é o que permite
medir alucinação diretamente.

A hipótese aceita o `.transcript.json` da coruja como está.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
import unicodedata
from pathlib import Path

# ---------------------------------------------------------------- normalização

# Pontuação removida, acento MANTIDO. Dobrar acento esconde erro real do
# modelo, e nesse domínio "pólice"/"police" é uma distinção que importa.
_PUNCT = re.compile(r"[^\w\sÀ-ÿ]", re.UNICODE)
_WS = re.compile(r"\s+")

# Alucinações de silêncio observadas em pt-BR. Contadas separadamente para
# você ver se o filtro está funcionando, e nunca usadas para "consertar" o WER.
FILLERS = {
    "e aí", "e ai", "obrigado", "obrigada", "aplausos", "amém", "amem",
    "música", "musica", "tchau", "valeu", "até mais", "ate mais",
    "obrigado por assistir", "inscreva-se no canal", "legendado por",
    "legendas pela comunidade amara.org", "estou aqui para te ajudar",
}


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    text = _PUNCT.sub(" ", text)
    return _WS.sub(" ", text).strip().lower()


def words(text: str) -> list[str]:
    n = normalize(text)
    return n.split() if n else []


# ------------------------------------------------------------------------ WER


#: acima disso a DP O(n*m) exata (linha abaixo) fica lenta demais para rodar
#: "a cada mudança de parâmetro" como o protocolo pede — uma reunião de 87min
#: (~11k palavras) é 130M+ células, minutos de CPU. difflib.SequenceMatcher
#: (Ratcliff/Obershelp, com heurística de autojunk) dá sub/ins/del muito
#: próximos do ótimo em texto real, em segundos.
_EXACT_DP_CELL_LIMIT = 4_000_000


def edit_ops(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
    """(substituições, inserções, deleções) via Levenshtein com backtrace."""
    n, m = len(ref), len(hyp)
    if n == 0:
        return (0, m, 0)
    if m == 0:
        return (0, 0, n)

    if n * m > _EXACT_DP_CELL_LIMIT:
        return _edit_ops_approx(ref, hyp)

    # DP completo: O(n*m) memória. Para 10 min de fala (~1.5k palavras) são
    # ~2M células, ~20 MB — aceitável, e o backtrace precisa da tabela.
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i - 1]
        row, prev = d[i], d[i - 1]
        for j in range(1, m + 1):
            cost = 0 if ri == hyp[j - 1] else 1
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)

    sub = ins = dele = 0
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0:
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            if d[i][j] == d[i - 1][j - 1] + cost:
                if cost:
                    sub += 1
                i, j = i - 1, j - 1
                continue
        if j > 0 and d[i][j] == d[i][j - 1] + 1:
            ins += 1
            j -= 1
            continue
        ins_guard = i > 0 and d[i][j] == d[i - 1][j] + 1
        if ins_guard:
            dele += 1
            i -= 1
            continue
        # defensivo: não deveria acontecer
        break
    return (sub, ins, dele)


def _edit_ops_approx(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
    """Aproximação rápida de (sub, ins, del) para entradas grandes demais para
    a DP exata — ver _EXACT_DP_CELL_LIMIT. Não garante o Levenshtein mínimo,
    mas em texto real (poucos blocos de diferença, muito trecho idêntico)
    fica a poucos % do valor exato — o suficiente para comparar configurações
    entre si, que é o uso real deste script."""
    sub = ins = dele = 0
    matcher = difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        elif tag == "replace":
            sub += min(i2 - i1, j2 - j1)
            ins += max(0, (j2 - j1) - (i2 - i1))
            dele += max(0, (i2 - i1) - (j2 - j1))
        elif tag == "insert":
            ins += j2 - j1
        elif tag == "delete":
            dele += i2 - i1
    return (sub, ins, dele)


def cer(ref: str, hyp: str) -> float:
    a, b = normalize(ref).replace(" ", ""), normalize(hyp).replace(" ", "")
    if not a:
        return 0.0 if not b else 1.0

    # Mesmo limite de células que edit_ops: uma reunião de 87min tem ~50k
    # caracteres de cada lado, 2.5B células na DP exata — inviável em Python
    # puro. difflib dá a mesma aproximação usada ali.
    if len(a) * len(b) > _EXACT_DP_CELL_LIMIT:
        sub, ins, dele = _edit_ops_approx(list(a), list(b))
        return (sub + ins + dele) / len(a)

    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return prev[-1] / len(a)


# ------------------------------------------------------------------ carregamento


# A coruja escreve "me"/"them"; uma referência humana normalmente escreve
# "eu"/o nome da pessoa. Sem canonizar, o DER sai inflado por diferença de
# rótulo e não por erro de atribuição — foi o primeiro falso positivo que este
# script produziu.
SPEAKER_ALIASES = {
    "me": "eu", "mic": "eu", "gabriel": "eu", "gabi": "eu",
    "them": "outro", "system": "outro",
}


def canon_speaker(raw: str | None, extra: dict[str, str]) -> str | None:
    if not raw:
        return None
    key = raw.strip().lower()
    return extra.get(key) or SPEAKER_ALIASES.get(key) or key


def load_segments(path: Path, speaker_map: dict[str, str] | None = None) -> tuple[list[dict], float | None]:
    data = json.loads(path.read_text(encoding="utf-8"))
    segs = data.get("segments", [])
    smap = speaker_map or {}
    out = []
    for s in segs:
        out.append(
            {
                "speaker": canon_speaker(s.get("speaker"), smap),
                "start": float(s["start_ms"]) / 1000.0,
                "end": float(s["end_ms"]) / 1000.0,
                "text": s.get("text", ""),
            }
        )
    out.sort(key=lambda s: s["start"])
    duration = data.get("duration_s")
    return out, (float(duration) if duration is not None else None)


def merge_intervals(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not spans:
        return []
    spans = sorted(spans)
    out = [list(spans[0])]
    for a, b in spans[1:]:
        if a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


# -------------------------------------------------------------------- métricas


def evaluate(
    ref_path: Path, hyp_path: Path, glossary: list[str],
    speaker_map: dict[str, str] | None = None,
) -> dict:
    ref, ref_duration = load_segments(ref_path, speaker_map)
    hyp, _ = load_segments(hyp_path, speaker_map)

    ref_text = " ".join(s["text"] for s in ref)
    hyp_text = " ".join(s["text"] for s in hyp)
    rw, hw = words(ref_text), words(hyp_text)

    sub, ins, dele = edit_ops(rw, hw)
    n_ref = max(1, len(rw))

    # --- alucinação em silêncio -------------------------------------------
    # Palavras da hipótese cujo segmento não sobrepõe NENHUM segmento da
    # referência. É a métrica que expõe "E aí" a cada 2 s, e a que o WER
    # agregado dilui.
    speech = merge_intervals([(s["start"], s["end"]) for s in ref])
    total = ref_duration if ref_duration else (max((s["end"] for s in ref + hyp), default=0.0))
    speech_time = sum(b - a for a, b in speech)
    silence_time = max(0.0, total - speech_time)

    hallucinated_words = 0
    hallucinated_segments = 0
    filler_segments = 0
    for s in hyp:
        overlap = sum(
            max(0.0, min(s["end"], b) - max(s["start"], a)) for a, b in speech
        )
        seg_words = words(s["text"])
        if overlap <= 0.05 * max(1e-6, s["end"] - s["start"]):
            hallucinated_words += len(seg_words)
            hallucinated_segments += 1
        if normalize(s["text"]) in FILLERS:
            filler_segments += 1

    # --- fala perdida ------------------------------------------------------
    # Regiões de fala da referência sem nenhuma sobreposição na hipótese.
    hyp_spans = merge_intervals([(s["start"], s["end"]) for s in hyp])
    missed = 0.0
    for a, b in speech:
        covered = sum(max(0.0, min(b, d) - max(a, c)) for c, d in hyp_spans)
        missed += max(0.0, (b - a) - covered)

    # --- recall de glossário ----------------------------------------------
    ref_norm, hyp_norm = normalize(ref_text), normalize(hyp_text)
    present = [t for t in glossary if t in ref_norm]
    found = [t for t in present if t in hyp_norm]

    # --- DER simplificado --------------------------------------------------
    der = None
    if any(s["speaker"] for s in ref) and any(s["speaker"] for s in hyp):
        matched = wrong = 0.0
        for r in ref:
            if not r["speaker"]:
                continue
            for h in hyp:
                ov = min(r["end"], h["end"]) - max(r["start"], h["start"])
                if ov <= 0:
                    continue
                if h["speaker"] == r["speaker"]:
                    matched += ov
                else:
                    wrong += ov
        if matched + wrong > 0:
            der = wrong / (matched + wrong)

    # --- fragmentação ------------------------------------------------------
    hyp_lens = [len(words(s["text"])) for s in hyp if words(s["text"])]
    ref_lens = [len(words(s["text"])) for s in ref if words(s["text"])]

    return {
        "session": ref_path.parent.name or ref_path.stem,
        "wer": (sub + ins + dele) / n_ref,
        "sub_rate": sub / n_ref,
        "ins_rate": ins / n_ref,
        "del_rate": dele / n_ref,
        "cer": cer(ref_text, hyp_text),
        "ref_words": len(rw),
        "hyp_words": len(hw),
        "silence_s": silence_time,
        "halluc_words": hallucinated_words,
        "halluc_segments": hallucinated_segments,
        "halluc_per_min_silence": (
            hallucinated_words / (silence_time / 60.0) if silence_time > 1 else 0.0
        ),
        "filler_segments": filler_segments,
        "missed_speech_s": missed,
        "missed_speech_pct": (missed / speech_time * 100.0) if speech_time > 0 else 0.0,
        "glossary_present": len(present),
        "glossary_recall": (len(found) / len(present)) if present else None,
        "glossary_missing": sorted(set(present) - set(found)),
        "der": der,
        "mean_seg_words_hyp": (sum(hyp_lens) / len(hyp_lens)) if hyp_lens else 0.0,
        "mean_seg_words_ref": (sum(ref_lens) / len(ref_lens)) if ref_lens else 0.0,
        "hyp_segments": len(hyp),
        "ref_segments": len(ref),
    }


# ---------------------------------------------------------------------- report


def fmt(r: dict) -> str:
    lines = [
        f"── {r['session']}",
        f"   WER              {r['wer']:6.1%}   (sub {r['sub_rate']:.1%} "
        f"ins {r['ins_rate']:.1%} del {r['del_rate']:.1%})",
        f"   CER              {r['cer']:6.1%}",
        f"   palavras         ref {r['ref_words']}  hyp {r['hyp_words']}",
        "",
        f"   ALUCINAÇÃO       {r['halluc_words']} palavras em "
        f"{r['halluc_segments']} segmentos fora de fala",
        f"                    {r['halluc_per_min_silence']:.1f} palavras / min de silêncio"
        f"   ({r['silence_s']:.0f}s de silêncio)   ← meta: 0",
        f"   fillers isolados {r['filler_segments']} segmentos",
        "",
        f"   FALA PERDIDA     {r['missed_speech_s']:.1f}s "
        f"({r['missed_speech_pct']:.1f}% da fala)   ← meta: 0",
    ]
    if r["glossary_recall"] is not None:
        lines.append(
            f"   GLOSSÁRIO        {r['glossary_recall']:.0%} "
            f"({r['glossary_present']} termos na referência)"
        )
        if r["glossary_missing"]:
            lines.append(f"                    faltando: {', '.join(r['glossary_missing'][:8])}")
    if r["der"] is not None:
        lines.append(f"   DER              {r['der']:6.1%}")
    lines += [
        "",
        f"   FRAGMENTAÇÃO     {r['mean_seg_words_hyp']:.1f} palavras/segmento "
        f"(referência {r['mean_seg_words_ref']:.1f})",
        f"                    {r['hyp_segments']} segmentos vs {r['ref_segments']} na referência",
    ]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ref", type=Path, help="reference.json de uma sessão")
    p.add_argument("--hyp", type=Path, help=".transcript.json correspondente")
    p.add_argument("--suite", type=Path, help="pasta com <sessão>/reference.json")
    p.add_argument("--hyp-dir", type=Path, help="pasta com <sessão>/.transcript.json")
    p.add_argument("--label", default="", help="rótulo da configuração, para comparar rodadas")
    p.add_argument("--glossary", type=Path, help="arquivo com um termo por linha")
    p.add_argument("--json", action="store_true", help="saída em JSON")
    p.add_argument(
        "--speaker-map", action="append", default=[], metavar="DE=PARA",
        help="canoniza rótulo de falante, ex: --speaker-map them=alisson (repetível)",
    )
    args = p.parse_args()

    if args.glossary:
        glossary = [
            normalize(line) for line in args.glossary.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    else:
        glossary = [
            normalize(t) for t in [
                "apólice", "endosso", "sinistro", "corretor", "transbordo",
                "enquadramento", "vistoria prévia", "homologação", "agrícola",
                "pecuária", "patrimonial", "Mafre", "Zenvia", "Sicredi", "URA",
                "RPA", "OTP", "widget", "template", "base de conhecimento",
                "disparo de ativos", "canal corretor",
            ]
        ]

    pairs: list[tuple[Path, Path]] = []
    if args.ref and args.hyp:
        pairs.append((args.ref, args.hyp))
    elif args.suite and args.hyp_dir:
        for ref in sorted(args.suite.glob("*/reference.json")):
            hyp = args.hyp_dir / ref.parent.name / ".transcript.json"
            if hyp.exists():
                pairs.append((ref, hyp))
            else:
                print(f"aviso: sem hipótese para {ref.parent.name}", file=sys.stderr)
    else:
        p.error("use --ref/--hyp ou --suite/--hyp-dir")

    if not pairs:
        print("nenhum par referência/hipótese encontrado", file=sys.stderr)
        return 1

    speaker_map = {}
    for item in args.speaker_map:
        if "=" not in item:
            p.error(f"--speaker-map espera DE=PARA, recebeu {item!r}")
        k, v = item.split("=", 1)
        speaker_map[k.strip().lower()] = v.strip().lower()

    results = [evaluate(r, h, glossary, speaker_map) for r, h in pairs]

    if args.json:
        print(json.dumps({"label": args.label, "sessions": results}, ensure_ascii=False, indent=2))
        return 0

    header = f"resultado{' — ' + args.label if args.label else ''}"
    print(header)
    print("=" * len(header))
    for r in results:
        print()
        print(fmt(r))

    if len(results) > 1:
        n = len(results)
        tw = sum(r["ref_words"] for r in results) or 1
        print()
        print("── AGREGADO (WER ponderado por palavras)")
        print(f"   WER              {sum(r['wer'] * r['ref_words'] for r in results) / tw:6.1%}")
        print(f"   ins_rate         {sum(r['ins_rate'] * r['ref_words'] for r in results) / tw:6.1%}")
        print(f"   alucinação/min   {sum(r['halluc_per_min_silence'] for r in results) / n:6.1f}")
        print(f"   fala perdida     {sum(r['missed_speech_pct'] for r in results) / n:6.1f}%")
        recalls = [r["glossary_recall"] for r in results if r["glossary_recall"] is not None]
        if recalls:
            print(f"   glossário        {sum(recalls) / len(recalls):6.0%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
