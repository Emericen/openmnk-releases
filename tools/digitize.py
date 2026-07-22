#!/usr/bin/env python3
# OpenMNK intake digitizer. Reads a folder of client documents and writes a machine-readable
# twin BESIDE it — the intake folder itself is never touched:
#   <folder>_ocr/       mirrors the intake's directory structure
#     <doc>.json         one per document, beside its page renders — pages carry either
#                        OCR regions ({text, conf, bbox}, page width/height) or pdf text
#     <doc>-pN.png       render of every OCR'd page (visual verification, bbox crops)
#     inventory.csv      one row per document: file, method, pages, words, mean confidence
#     run.log            mirror of progress output; final line is "DIGITIZE-DONE"
# Methods: native (.xlsx/.docx/.csv — read the original with code, no OCR), pdf-text
# (embedded text layer, exact), ocr (rendered + recognized; judge by conf and words).
# Safe to re-run: unchanged documents (mtime+size, via cache.json) are skipped, so an
# interrupted run resumes. A corrupt document gets an ERROR row and the run continues.
# Usage: python digitize.py <folder> [--dpi 300]
import argparse
import csv
import json
import os
import sys
import time

import numpy as np
import pypdfium2 as pdfium
from PIL import Image
from pypdf import PdfReader
from rapidocr_onnxruntime import RapidOCR

NATIVE_EXT = {".xlsx", ".xlsm", ".docx", ".csv", ".tsv"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp"}
TEXT_LAYER_MIN_CHARS = 40  # avg chars/page below this -> treat PDF as scanned


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--dpi", type=int, default=300)
    args = ap.parse_args()
    root = os.path.abspath(args.folder)
    if not os.path.isdir(root):
        sys.exit(f"not a folder: {root}")
    out = root.rstrip(os.sep) + "_ocr"
    os.makedirs(out, exist_ok=True)
    log_f = open(os.path.join(out, "run.log"), "a", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log_f.write(msg + "\n")
        log_f.flush()

    cache_path = os.path.join(out, "cache.json")
    try:
        with open(cache_path, encoding="utf-8") as f:
            cache = json.load(f)
    except Exception:
        cache = {}
    start_ts = time.time()
    say(f"=== digitize start: {root} -> {out} ===")

    ocr = RapidOCR()

    def ocr_page(img):
        img = img.convert("RGB")
        result, _ = ocr(np.array(img))
        results = []
        for b, t, c in result or []:
            conf = round(float(c), 3)
            bbox = [[int(x), int(y)] for x, y in b]
            results.append({"text": t, "conf": conf, "bbox": bbox})
        return results

    def digest(path, base, ext):
        """Returns (method, pages) — each page carries 'regions' (ocr) or 'text' (pdf-text)."""
        if ext == ".pdf":
            reader = PdfReader(path)
            embedded = [(p.extract_text() or "") for p in reader.pages]
            avg_chars = sum(len(t) for t in embedded) / max(1, len(embedded))
            if avg_chars >= TEXT_LAYER_MIN_CHARS:
                pages = []
                for i, text in enumerate(embedded):
                    pages.append({"page": i + 1, "text": text})
                return "pdf-text", pages
            doc = pdfium.PdfDocument(path)
            imgs = []
            for i in range(len(doc)):
                img = doc[i].render(scale=args.dpi / 72).to_pil()
                imgs.append(img)
            doc.close()
        else:
            imgs = [Image.open(path).convert("RGB")]
        pages = []
        for i, img in enumerate(imgs):
            img.save(f"{base}-p{i + 1}.png")
            page = {
                "page": i + 1,
                "width": img.width,
                "height": img.height,
                "regions": ocr_page(img),
            }
            pages.append(page)
        return "ocr", pages

    docs = []
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            if not fn.startswith("."):
                docs.append(os.path.join(dirpath, fn))

    rows = []
    processed = 0
    skipped = 0
    for path in docs:
        rel = os.path.relpath(path, root)
        base = os.path.join(out, rel.rsplit(".", 1)[0])
        ext = os.path.splitext(path)[1].lower()
        st = os.stat(path)
        key = f"{st.st_mtime_ns}:{st.st_size}"

        cached = cache.get(rel)
        unchanged = cached is not None and cached.get("key") == key
        output_present = os.path.exists(base + ".json")
        if unchanged and (cached["row"][1] != "ocr" or output_present):
            rows.append(cached["row"])
            skipped += 1
            continue
        processed += 1
        say(f"  [{processed + skipped}/{len(docs)}] {rel} ...")

        if ext in NATIVE_EXT:
            row = [rel, "native", 0, 0, ""]
        elif ext == ".pdf" or ext in IMAGE_EXT:
            os.makedirs(os.path.dirname(base) or out, exist_ok=True)
            try:
                method, pages = digest(path, base, ext)
            except Exception as e:
                say(f"    ERROR: {e}")
                rows.append([rel, "error", 0, 0, f"ERROR: {e}"])
                continue
            with open(base + ".json", "w", encoding="utf-8") as f:
                json.dump({"file": rel, "method": method, "pages": pages}, f, indent=1)
            words = 0
            confs = []
            for page in pages:
                words += len(page.get("text", "").split())
                for region in page.get("regions", []):
                    words += len(region["text"].split())
                    confs.append(region["conf"])
            if confs:
                mean_conf = round(100 * sum(confs) / len(confs))
            else:
                mean_conf = ""
            row = [rel, method, len(pages), words, mean_conf]
        else:
            row = [rel, "skipped", 0, 0, ""]

        rows.append(row)
        cache[rel] = {"key": key, "row": row}
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(cache, f)

    inventory_path = os.path.join(out, "inventory.csv")
    with open(inventory_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["file", "method", "pages", "words", "mean_ocr_confidence"])
        writer.writerows(rows)

    elapsed = time.time() - start_ts
    say(f"{len(rows)} documents ({processed} processed, {skipped} cached) in {elapsed:.0f}s -> {out}")
    say("read inventory.csv for the per-document census")
    say("DIGITIZE-DONE")


if __name__ == "__main__":
    main()
