#!/usr/bin/env python3
"""Строит триграммную модель символов для Switcher.

Скачивает открытые частотные списки слов (OpenSubtitles, CC-BY-SA) и
записывает плотную таблицу log10 условных вероятностей в формате STG2.

Запускается вручную при необходимости пересобрать модель; результат
коммитится в репозиторий, поэтому в рантайме сеть не нужна.

    python3 Tools/build_trigram_model.py
"""
import struct
import sys
import urllib.request
from pathlib import Path

BOUNDARY = "^"
ALPHABETS = {
    "en": BOUNDARY + "abcdefghijklmnopqrstuvwxyz'",
    "ru": BOUNDARY + "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
}
SOURCES = {
    "en": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
    "ru": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt",
}
SMOOTHING_K = 0.5
OUT_DIR = Path(__file__).resolve().parent.parent / "Sources" / "Switcher" / "Resources"


def load_words(lang):
    """Возвращает список (слово, частота) из частотного списка."""
    print(f"  скачиваю {SOURCES[lang]}")
    with urllib.request.urlopen(SOURCES[lang]) as response:
        text = response.read().decode("utf-8")

    alphabet = set(ALPHABETS[lang][1:])
    words = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        word, count = parts[0].lower(), int(parts[1])
        # Слова с посторонними символами (цифры, латиница в русском списке)
        # искажают статистику — отбрасываем.
        if word and all(ch in alphabet for ch in word):
            words.append((word, count))
    print(f"  принято слов: {len(words)}")
    return words


def build(lang):
    alphabet = ALPHABETS[lang]
    A = len(alphabet)
    index = {ch: i for i, ch in enumerate(alphabet)}

    trigram = [0.0] * (A * A * A)
    bigram = [0.0] * (A * A)

    for word, count in load_words(lang):
        # Паддинг границами: ^^слово^
        padded = BOUNDARY * 2 + word + BOUNDARY
        ids = [index[ch] for ch in padded]
        for i in range(len(ids) - 2):
            a, b, c = ids[i], ids[i + 1], ids[i + 2]
            trigram[a * A * A + b * A + c] += count
            bigram[a * A + b] += count

    import math
    probs = []
    for a in range(A):
        for b in range(A):
            context = bigram[a * A + b]
            denominator = context + SMOOTHING_K * A
            for c in range(A):
                numerator = trigram[a * A * A + b * A + c] + SMOOTHING_K
                probs.append(math.log10(numerator / denominator))

    out = bytearray(b"STG2")
    out += struct.pack("<I", A)
    for ch in alphabet:
        out += struct.pack("<I", ord(ch))
    for p in probs:
        out += struct.pack("<f", p)

    path = OUT_DIR / f"{lang}.trigram"
    path.write_bytes(out)
    print(f"  записано {path} ({len(out)} байт, A={A})")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for lang in ("en", "ru"):
        print(f"[{lang}]")
        build(lang)
    return 0


if __name__ == "__main__":
    sys.exit(main())
