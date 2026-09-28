#!/usr/bin/env python3
"""Compare Draw Things prompts on explicitly supplied Trip photos.

Run with the managed Draw Things Python. Writes an isolated review and cache;
does not change the running app, its preferences, or its production photo cache.
"""
import argparse
import html
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
import ExpandPhotoDrawThings as backend

PROMPTS = {
    # Keep the original prompt fixed so this remains reproducible after the
    # production prompt changes.
    "current": "Extend this photograph naturally into the added border. Continue the same scene, lighting, colors, textures and perspective. Match the existing depth of field and optical blur of each adjacent original region: do not sharpen a blurry background or blur a focused foreground. Continue existing subjects only where they cross the edge, without adding or repeating people. Keep the original photograph unchanged. No frame or border.",
    "neutral": "Extend the photograph beyond its edges. Continue the existing scene, objects, surfaces, lighting, colors and perspective. Preserve the original photograph and composition. No frame or border.",
    "local-detail": "Extend the photograph beyond its edges as one continuous image. Match the local texture, level of detail and edge definition at every boundary. Continue each visible surface with the same appearance, lighting, color and perspective as its adjoining original region. Preserve the original composition. Continue existing subjects only where they cross the edge, without adding or repeating people. No frame or border.",
    "seamless-scene": "Expand the canvas to reveal more of the exact same scene, as if it had originally been photographed with a wider field of view. Continue every object and surface across the image boundary, preserving the same camera position, perspective, lighting, color, texture, and focus. The added area should join seamlessly with the original, with no visible boundary or change in photographic style. Keep the original photograph unchanged. Extend subjects only where they cross the edge; do not add or repeat people. No frame or border.",
}


def review(output, records):
    from PIL import Image, ImageCms
    cards = []
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    for row in records:
        directory = output / row["sample"] / row["variant"]
        preview = directory / "preview.jpg"
        if not preview.exists():
            with Image.open(directory / "expanded.png") as image:
                image.thumbnail((1600, 1600))
                image.convert("RGB").save(preview, quality=94, icc_profile=profile)
        source = f'{row["sample"]}/{row["variant"]}'
        cards.append(f'<article><h2>{html.escape(row["sample"])} · {html.escape(row["variant"])}</h2>'
                     f'<a href="{source}/expanded.png"><img src="{source}/preview.jpg"></a>'
                     f'<p>{row["seconds"]:.1f}s including any server wait · source long edge {row["model_long_edge"]}px</p>'
                     f'<details><summary>Exact prompt</summary><p>{html.escape(row["prompt"])}</p></details></article>')
    (output / "index.html").write_text('''<!doctype html><html><meta charset="utf-8"><title>Draw Things focus comparison</title>
<style>body{background:#141516;color:#eee;font:16px system-ui;margin:28px}main{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px}article{background:#222;padding:16px;border-radius:12px}h2{font-size:19px}img{width:100%;height:520px;object-fit:contain}p{line-height:1.5;color:#ccc}a{color:#abe}@media(max-width:1000px){main{grid-template-columns:1fr}img{height:auto}}</style>
<h1>Draw Things focus comparison</h1><p>Trip photos only. Four steps, seed 8612, 20% expansion. Each row compares the same photo. Click an image for full resolution. Original interiors are restored exactly; compare the generated outer edges and their joins. Timings include contention with any running slideshow.</p><main>''' + "".join(cards) + "</main></html>")
    (output / "results.json").write_text(json.dumps(records, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", required=True, type=Path, help='JSON: {"album":"Trip","sources":{"name":"absolute path"}}')
    parser.add_argument("--prepare-helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runtime-config", type=Path, default=backend.default_runtime_config())
    parser.add_argument("--variant", action="append", choices=PROMPTS)
    parser.add_argument("--long-edge", type=int, default=768)
    args = parser.parse_args()
    samples = json.loads(args.sources.read_text())
    if samples.get("album") != "Trip":
        parser.error("Real-media QA is restricted to the Trip album.")
    if not 256 <= args.long_edge <= 1536:
        parser.error("Source long edge must be 256...1536.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "prompts.json").write_text(json.dumps(PROMPTS, indent=2) + "\n")
    records = []
    for sample, source in samples["sources"].items():
        for variant in args.variant or PROMPTS:
            if Path(sample).name != sample:
                parser.error("Sample names must be single directory names.")
            destination = output / sample / variant
            backend.SETTINGS.update(prompt=PROMPTS[variant], model_long_edge=args.long_edge)
            print(f"START {sample} {variant} {args.long_edge}px", flush=True)
            manifest = destination / "expansion.json"
            if not manifest.exists():
                backend.expand(Path(source), destination, 20, args.prepare_helper.resolve(),
                               output / "cache", args.runtime_config, timeout=300)
            result = json.loads(manifest.read_text())
            settings = result["identity"]["settings"]
            if settings["prompt"] != PROMPTS[variant] or settings["model_long_edge"] != args.long_edge:
                raise RuntimeError("Existing result settings differ; choose a new output directory.")
            row = {"sample": sample, "variant": variant, "prompt": PROMPTS[variant],
                   "model_long_edge": args.long_edge, "seconds": result["total_seconds"],
                   "cache_key": result["cache_key"], "original_max_rgb_error": result["preserved_interior_max_rgb_error"]}
            records.append(row)
            review(output, records)
            print(f"DONE {sample} {variant} {row['seconds']:.1f}s", flush=True)


if __name__ == "__main__":
    main()
