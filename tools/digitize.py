#!/usr/bin/env python3
# OpenMNK intake digitizer. One pass over a folder of client documents:
#   - native office files (.xlsx/.docx/.csv) are cataloged, not OCR'd — read those with code
#   - PDFs with a real text layer are extracted directly (instant, exact)
#   - scanned PDFs and images are rendered and OCR'd (rapidocr, per-region confidence)
# Output lands in <folder>/_digitized/:
#   inventory.csv           one row per document: method, pages, words, confidence, STATUS
#   <name>.txt              extracted text, per-page headers with per-page confidence
#   pages/<name>-pN.png     page renders for every scanned page (for visual double-reads)
# STATUS meanings:
#   NATIVE          read the original with openpyxl/python-docx — do not use OCR text
#   OK              text usable for search; still re-verify any number that matters
#   LOW_CONFIDENCE  usable for locating content; re-read numbers from the page render
#   UNREADABLE      OCR got nothing — look at the render yourself; if you can't read it
#                   either, put the document on the client request list. Never guess.
# Usage: python digitize.py <folder> [--dpi 300]
import argparse
import csv
import os
import sys

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

    import pypdfium2 as pdfium
    from pypdf import PdfReader
    from rapidocr_onnxruntime import RapidOCR
    ocr = RapidOCR()

    def ocr_image(pil_img):
        import numpy as np
        result, _ = ocr(np.array(pil_img.convert("RGB")))
        if not result:
            return "", 0.0, 0
        lines = [text for _, text, _ in result]
        confs = [float(c) for _, _, c in result]
        words = sum(len(t.split()) for t in lines)
        return "\n".join(lines), 100.0 * sum(confs) / len(confs), words

    rows = []
    docs = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "_digitized"]
        for fn in sorted(filenames):
            if fn.startswith("."):
                continue
            docs.append(os.path.join(dirpath, fn))

    for path in docs:
        rel = os.path.relpath(path, root)
        stem = rel.replace(os.sep, "__").rsplit(".", 1)[0]
        ext = os.path.splitext(path)[1].lower()
        print(f"  {rel} ...", flush=True)

        if ext in NATIVE_EXT:
            rows.append([rel, "native", 0, 0, "", "NATIVE"])
            continue

        page_texts = []   # (text, conf or None, words)
        method = None

        if ext == ".pdf":
            try:
                reader = PdfReader(path)
                embedded = [(p.extract_text() or "") for p in reader.pages]
            except Exception as e:
                rows.append([rel, "error", 0, 0, "", f"ERROR: {e}"])
                continue
            avg_chars = sum(len(t) for t in embedded) / max(1, len(embedded))
            if avg_chars >= TEXT_LAYER_MIN_CHARS:
                method = "pdf-text"
                page_texts = [(t, None, len(t.split())) for t in embedded]
            else:
                method = "ocr"
                doc = pdfium.PdfDocument(path)
                for i in range(len(doc)):
                    img = doc[i].render(scale=args.dpi / 72).to_pil()
                    img.save(os.path.join(pages_dir, f"{stem}-p{i + 1}.png"))
                    page_texts.append(ocr_image(img))
                doc.close()
        elif ext in IMAGE_EXT:
            method = "ocr"
            from PIL import Image
            img = Image.open(path)
            img.convert("RGB").save(os.path.join(pages_dir, f"{stem}-p1.png"))
            page_texts.append(ocr_image(img))
        else:
            rows.append([rel, "skipped", 0, 0, "", "SKIPPED (unknown type)"])
            continue

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
        rows.append([rel, method, len(page_texts), total_words,
                     f"{mean_conf:.0f}" if mean_conf is not None else "", status])

    with open(os.path.join(out, "inventory.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "method", "pages", "words", "mean_ocr_confidence", "status"])
        w.writerows(rows)

    print(f"\n{'file':44} {'method':9} {'pages':>5} {'words':>6} {'conf':>5}  status")
    for r in rows:
        print(f"{r[0][:44]:44} {r[1]:9} {r[2]:>5} {r[3]:>6} {r[4]:>5}  {r[5]}")
    flagged = [r for r in rows if r[5] not in ("OK", "NATIVE")]
    print(f"\n{len(rows)} documents -> {out}")
    if flagged:
        print(f"ATTENTION ({len(flagged)}): " + "; ".join(f"{r[0]} [{r[5]}]" for r in flagged))
        print("For LOW_CONFIDENCE/UNREADABLE: read the render in _digitized/pages/ yourself.")

if __name__ == "__main__":
    main()
