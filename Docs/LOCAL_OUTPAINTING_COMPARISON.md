# Local outpainting versus saved Apple Extend

September 27, 2026. Tested only Trip album images. Machine: Apple M3 Max, 48 GiB RAM. No new Apple Extend or paid API requests were made.

## Result

Keep the normal 768-pixel local setting as the practical fallback. The 1024-pixel experiment took substantially longer and did not consistently improve scene continuation. On these four images, saved Apple Extend generally matched the source texture and lighting better. Local Klein is usable on some scenes, but it is not yet a quality-equivalent replacement for Apple Extend.

| Trip scene | Local 768, seconds | Local 1024, seconds | Saved Apple native stage, seconds |
| --- | ---: | ---: | ---: |
| Forest trail | 47.6, including cold startup | 100.1 | 16.4 |
| Misty meadow | 34.0 | 105.5 | 15.9 |
| Family by the trees | 34.4 | 71.6 | 17.3 |
| Forest portrait | 33.5 | 74.9 | 15.6 |

Local timing includes decoding, model inference, compositing and saving. Apple's saved timing covers only its native generation call, so those columns are not a controlled end-to-end speed comparison. This is one seed per condition, not an album-wide benchmark.

## Visual findings

- Forest trail: both local variants add busier, sharper ground and root detail. Apple continues a smoother trail more consistent with the source.
- Misty meadow: the fog is plausible locally, but border grass and distant trees become more detailed; larger resolution does not remove this tendency.
- Family by the trees: the 1024 version produces an implausible continuation of a child's leg into the stump. Both local variants change the texture of the large tree trunks more than Apple.
- Forest portrait: the local bark and moss become more contrasty, especially on the right edge. Color is broadly coherent; the previously reported strong purple border is not obvious in these four new results.
- An additional saved Trip shallow-focus result using this prompt still has an obvious focus boundary between the blurred source background and sharper generated border. The four main sources are recovered from Apple-prepared centers; this extra result uses a different rendering of its source and is not a matched Apple comparison. Do not call the depth-of-field problem solved.

## Reproducibility and preservation

Draw Things FLUX.2 Klein 4B, 8-bit S; `flux_2_klein_4b_i8x.ckpt`; server v26.0910.1; four steps; guidance 1; seed 8612; expansion 20% per edge. Both settings use the `seamless-scene` prompt from `Scripts/compare_drawthings_prompts.py`. It asks to widen the same scene and preserve its camera, lighting, color, texture and focus without emphasizing bokeh.

The original prepared pixels are restored at full resolution except for a narrow feathered seam. All eight new results report maximum interior RGB error 0. A fresh Python process reused the first expansion cache in 1.217 seconds, with `cache_hit: true` and the same output hash. This verifies helper cache reuse across processes, not every application cache scenario.

Each Apple cache's output SHA-256 was checked, and its native job request was matched to album `Trip` and 20% expansion. Sources for the A/B test are the preserved centers of those cached outputs. Apple and local padding differ by up to two pixels because of rounding; previews normalize the display area. No original Photos asset was modified.

The private review and raw evidence are in the ignored `build/local-vs-apple-review/` directory: `index.html`, `samples.json`, `local-results.json`, per-output `expansion.json`, source images, full-resolution outputs and `cache-relaunch-check.json`. Open the loopback review at http://127.0.0.1:8774/index.html while its local server is running.

No production defaults or model files were changed by this comparison. The standalone 1024 research helper relaxes the normal decoder limit only within the ignored review directory. See [paid API research](OUTPAINTING_API_COSTS.md) for the next quality-comparison candidates.
