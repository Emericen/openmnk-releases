#!/usr/bin/env python3
# OpenMNK intake digitizer. One pass over a folder of client documents:
#   - native office files (.xlsx/.docx/.csv) are cataloged, not OCR'd — read those with code
#   - PDFs with a real text layer are extracted directly (instant, exact)
#   - scanned PDFs and images are rendered and OCR'd (rapidocr, per-region confidence)
# Output lands in <folder>/_digitized/:
#   inventory.csv           one row per document: method, pages, words, confidence, STATUS
#   <name>.txt              extracted text, per-page headers with per-page confidence
#   pages/<name>-pN.png     page renders for every scanned page (for visual double-reads)
#   run.log                 mirror of all progress output (poll this for detached runs)
# STATUS meanings:
#   NATIVE          read the original with openpyxl/python-docx — do not use OCR text
#   OK              text usable for search; still re-verify any number that matters
#   LOW_CONFIDENCE  usable for locating content; re-read numbers from the page render
#   UNREADABLE      OCR got nothing — look at the render yourself; if you can't read it
#                   either, put the document on the client request list. Never guess.
# Safe to re-run: already-digitized documents (same mtime/size, via _digitized/cache.json)
# are skipped, so a timed-out or interrupted run RESUMES where it stopped. One corrupt
# document never kills the run — it gets an ERROR row and processing continues.
# For large intakes, start detached and poll the log until its last line is
# "DIGITIZE-DONE", e.g. on Windows:
#   Start-Process -WindowStyle Hidden cmd -ArgumentList '/c','digitize "<folder>"'
# Usage: python digitize.py <folder> [--dpi 300]
import argparse
import csv
import json
import os
import re
import sys
import time

NATIVE_EXT = {".xlsx", ".xlsm", ".docx", ".csv", ".tsv"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp"}
LOW_CONF = 75.0
UNREADABLE_CONF = 40.0
UNREADABLE_WORDS = 5
TEXT_LAYER_MIN_CHARS = 40  # avg chars/page below this → treat PDF as scanned

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--dpi", type=int, default=300)
    args = ap.parse_args()
    root = os.path.abspath(args.folder)
    if not os.path.isdir(root):
        sys.exit(f"not a folder: {root}")
    out = os.path.join(root, "_digitized")
    pages_dir = os.path.join(out, "pages")
    os.makedirs(pages_dir, exist_ok=True)
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
    say(f"=== digitize start: {root} ===")

    import pypdfium2 as pdfium
    from pypdf import PdfReader
    from rapidocr_onnxruntime import RapidOCR
    ocr = RapidOCR()

    # Two money amounts glued into one OCR region ("310.0020,682.17"): ".NN" immediately
    # followed by a digit is never one number — split them.
    MONEY_GLUE = re.compile(r"(\.\d{2})(?=\d)")

    def reconstruct(result):
        """Rebuild visual rows from OCR regions so label/amount adjacency is TRUE.
        Groups regions by vertical overlap, sorts left-to-right, renders column gaps
        as spacing, and flags rows containing a low-confidence region."""
        regions = []
        for box, text, conf in result:
            xs = [pt[0] for pt in box]
            ys = [pt[1] for pt in box]
            regions.append({"x0": min(xs), "x1": max(xs), "y0": min(ys), "y1": max(ys),
                            "cy": sum(ys) / 4, "text": MONEY_GLUE.sub(r"\1 ", text),
                            "conf": float(conf)})
        regions.sort(key=lambda r: r["cy"])
        rows = []
        for r in regions:
            for row in rows:
                overlap = min(r["y1"], row["y1"]) - max(r["y0"], row["y0"])
                if overlap > 0.5 * min(r["y1"] - r["y0"], row["y1"] - row["y0"]):
                    row["items"].append(r)
                    row["y0"] = min(row["y0"], r["y0"])
                    row["y1"] = max(row["y1"], r["y1"])
                    break
            else:
                rows.append({"y0": r["y0"], "y1": r["y1"], "items": [r]})
        rows.sort(key=lambda row: (row["y0"] + row["y1"]) / 2)
        lines = []
        for row in rows:
            items = sorted(row["items"], key=lambda r: r["x0"])
            widths = [(r["x1"] - r["x0"]) / max(1, len(r["text"])) for r in items]
            cw = max(1, sum(widths) / len(widths))
            line = items[0]["text"]
            for prev, cur in zip(items, items[1:]):
                gap = cur["x0"] - prev["x1"]
                line += " " * max(1, min(12, round(gap / cw))) + cur["text"]
            low = min(r["conf"] for r in items)
            if low < 0.93:
                line += f"    [conf {low:.2f}]"
            lines.append(line)
        return "\n".join(lines)

    def ocr_image(pil_img):
        import numpy as np
        result, _ = ocr(np.array(pil_img.convert("RGB")))
        if not result:
            return "", 0.0, 0
        text = reconstruct(result)
        confs = [float(c) for _, _, c in result]
        words = sum(len(t.split()) for _, t, _ in result)
        return text, 100.0 * sum(confs) / len(confs), words

    def digest(path, rel, stem, ext):
        """Returns (method, page_texts) where page_texts = [(text, conf|None, words)]."""
        if ext == ".pdf":
            reader = PdfReader(path)
            embedded = [(p.extract_text() or "") for p in reader.pages]
            avg_chars = sum(len(t) for t in embedded) / max(1, len(embedded))
            if avg_chars >= TEXT_LAYER_MIN_CHARS:
                return "pdf-text", [(t, None, len(t.split())) for t in embedded]
            doc = pdfium.PdfDocument(path)
            pages = []
            for i in range(len(doc)):
                img = doc[i].render(scale=args.dpi / 72).to_pil()
                img.save(os.path.join(pages_dir, f"{stem}-p{i + 1}.png"))
                pages.append(ocr_image(img))
            doc.close()
            return "ocr", pages
        if ext in IMAGE_EXT:
            from PIL import Image
            img = Image.open(path)
            img.convert("RGB").save(os.path.join(pages_dir, f"{stem}-p1.png"))
            return "ocr", [ocr_image(img)]
        return "skipped", []

    docs = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "_digitized"]
        for fn in sorted(filenames):
            if not fn.startswith("."):
                docs.append(os.path.join(dirpath, fn))

    rows = []
    processed = 0
    skipped = 0
    for path in docs:
        rel = os.path.relpath(path, root)
        stem = rel.replace(os.sep, "__").rsplit(".", 1)[0]
        ext = os.path.splitext(path)[1].lower()
        st = os.stat(path)
        key = f"{st.st_mtime_ns}:{st.st_size}"
        cached = cache.get(rel)
        txt_ok = os.path.exists(os.path.join(out, stem + ".txt"))
        if cached and cached.get("key") == key and (cached["row"][1] != "ocr" or txt_ok):
            rows.append(cached["row"])
            skipped += 1
            continue
        processed += 1
        say(f"  [{processed + skipped}/{len(docs)}] {rel} ...")

        if ext in NATIVE_EXT:
            row = [rel, "native", 0, 0, "", "NATIVE"]
        else:
            try:
                method, page_texts = digest(path, rel, stem, ext)
            except Exception as e:
                say(f"    ERROR: {e}")
                rows.append([rel, "error", 0, 0, "", f"ERROR: {e}"])
                continue
            if method == "skipped":
                row = [rel, "skipped", 0, 0, "", "SKIPPED (unknown type)"]
            else:
                total_words = sum(w for _, _, w in page_texts)
                confs = [c for _, c, _ in page_texts if c is not None]
                mean_conf = sum(confs) / len(confs) if confs else None
                with open(os.path.join(out, stem + ".txt"), "w", encoding="utf-8") as f:
                    for i, (text, conf, _) in enumerate(page_texts, 1):
                        tag = f" ocr-confidence={conf:.0f}" if conf is not None else " embedded-text"
                        f.write(f"===== {rel} page {i}{tag} =====\n{text}\n\n")
                if method == "pdf-text":
                    status = "OK"
                elif total_words < UNREADABLE_WORDS or (mean_conf or 0) < UNREADABLE_CONF:
                    status = "UNREADABLE"
                elif mean_conf < LOW_CONF:
                    status = "LOW_CONFIDENCE"
                else:
                    status = "OK"
                row = [rel, method, len(page_texts), total_words,
                       f"{mean_conf:.0f}" if mean_conf is not None else "", status]
        rows.append(row)
        cache[rel] = {"key": key, "row": row}
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(cache, f)

    with open(os.path.join(out, "inventory.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "method", "pages", "words", "mean_ocr_confidence", "status"])
        w.writerows(rows)

    say(f"\n{'file':44} {'method':9} {'pages':>5} {'words':>6} {'conf':>5}  status")
    for r in rows:
        say(f"{r[0][:44]:44} {r[1]:9} {r[2]:>5} {r[3]:>6} {r[4]:>5}  {r[5]}")
    flagged = [r for r in rows if r[5] not in ("OK", "NATIVE")]
    say(f"\n{len(rows)} documents ({processed} processed, {skipped} cached) "
        f"in {time.time() - start_ts:.0f}s -> {out}")
    if flagged:
        say(f"ATTENTION ({len(flagged)}): " + "; ".join(f"{r[0]} [{r[5]}]" for r in flagged))
        say("For LOW_CONFIDENCE/UNREADABLE: read the render in _digitized/pages/ yourself.")
    say("DIGITIZE-DONE")

if __name__ == "__main__":
    main()
