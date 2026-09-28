# Paid outpainting API comparison

Checked September 27, 2026. No paid requests or photo uploads were made for this research. Prices below are USD for one candidate per photo, excluding retries, tax, storage and transfer charges. Quality and latency on Trip photos remain untested.

## Cost estimates

Our local test generates a roughly 0.9 MP canvas at the 768 setting, or 1.6 MP at 1024, then restores the full-resolution original center. The paid equivalents can use the same strategy. A high-resolution saved composite does not mean that its generated borders have that native resolution.

For MP-priced examples below, assume one reference image no larger than 1 MP and output billed as either 1 MP or 2 MP. Google and OpenAI examples use their explicitly listed sizes instead, so these are budget comparisons rather than equal-resolution benchmarks.

| Service / model | Configuration | Per photo | 618 photos | Evidence |
| --- | --- | ---: | ---: | --- |
| BFL FLUX.2 Klein 4B | 1–2 MP output + 1 MP reference | $0.015–0.016 | $9.27–9.89 | [BFL calculator](https://bfl.ai/pricing?category=flux.2) |
| BFL FLUX.2 Klein 9B | 1–2 MP output + 1 MP reference | $0.017–0.019 | $10.51–11.74 | [BFL calculator](https://bfl.ai/pricing?category=flux.2) |
| Stability AI Outpaint | One border-expansion request | $0.040 | $24.72 | [Pricing](https://platform.stability.ai/pricing) |
| BFL FLUX.1 Fill Pro | One masked outpainting request | $0.050 | $30.90 | [Pricing](https://docs.bfl.ai/quick_start/pricing) |
| fal.ai FLUX.1 Pro Fill | 1–2 MP, rounded up | $0.050–0.100 | $30.90–61.80 | [Endpoint pricing](https://fal.ai/models/fal-ai/flux-pro/v1/fill) |
| BFL FLUX.2 Pro | 1–2 MP output + 1 MP reference | $0.045–0.060 | $27.81–37.08 | [BFL calculator](https://bfl.ai/pricing?category=flux.2) |
| OpenAI GPT Image 2.5 Sunburst / Flare | 1536×1024, medium | $0.01029 + inputs | $6.36 + inputs | [Official calculator](https://developers.openai.com/api/docs/guides/image-generation#cost-and-latency) |
| OpenAI GPT Image 2.5 Sunburst / Flare | 1536×1024, high | $0.04116 + inputs | $25.44 + inputs | [Official calculator](https://developers.openai.com/api/docs/guides/image-generation#cost-and-latency) |
| Google Nano Banana 2 Lite | 1K output | $0.0336 + input/thinking | $20.76 + input/thinking | [Pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Google Nano Banana 2 | 2K output | $0.1008 + input/thinking | $62.29 + input/thinking | [Pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Google Nano Banana Pro | 2K output + one reference image | $0.13552 + text/thinking | $83.75 + text/thinking | [Pricing](https://ai.google.dev/gemini-api/docs/pricing) |

Google costs use exact published token counts before rounding: Nano Banana 2 = 1,680 × $60/1M; Pro = 1,120 × $120/1M output plus 560 × $2/1M input. Batch processing halves those token prices, but is for preparing an album ahead of playback. For Pro, that is approximately $41.88 for 618 images before text/thinking.

OpenAI's live calculator returned 343 output tokens at medium and 1,372 at high for GPT Image 2.5, 1536×1024. Both cost $30/1M output tokens. Add $8/1M image-input tokens and $5/1M text-input tokens. Direct Images edits avoid a separate Responses-model charge. Actual edit totals require measuring usage for our prepared input and mask; the table is explicitly not an all-in quote. [Token rates](https://developers.openai.com/api/docs/pricing#image-generation)

## Fit for this app

- **First dedicated outpainting candidate: BFL Fill Pro.** It accepts a padded image and mask or transparent border; all four edges can be generated together. Its direct price is fixed per image, whereas fal bills its Fill endpoint per MP. Keep the original center and the existing cache after generation. [Fill API](https://docs.bfl.ai/flux_1_fill)
- **Lower-cost dedicated alternative: Stability Outpaint.** It exposes border extension directly and costs four credits at $0.01 each. [API](https://platform.stability.ai/docs/api-reference)
- **Premium editing comparison: OpenAI Sunburst at high.** It supports editing with a mask, but the mask is guidance rather than an exact pixel-preservation guarantee. Composite the original center back in and verify alignment. [Editing guide](https://developers.openai.com/api/docs/guides/image-generation#edit-an-image-using-a-mask)
- **BFL Klein / Pro and Google Nano Banana:** general image-editing alternatives. Their usefulness for exact canvas extension needs a visual test; reference-image editing alone does not guarantee fixed geometry. Cloud Klein 4B is the same model family as the local candidate, so paying for it is not evidence of a quality upgrade. [Gemini editing](https://ai.google.dev/gemini-api/docs/image-generation#image-editing-text-and-image-to-image)

Do not start a new integration with Imagen 3 outpainting despite the old $0.04 entry still appearing on Google's pricing page: its capability endpoint is listed as discontinued. Google's suggested older migration target, Gemini 2.5 Flash Image, also shuts down October 2, 2026; use current 3.1 image models when testing Google. [Imagen notice](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/image/edit-outpainting), [current Gemini pricing and deprecation notice](https://ai.google.dev/gemini-api/docs/pricing)

An implementation should cache the successful expanded image by source content, provider/model, prompt, border amount and generation settings. Replaying or regenerating motion from that cached still should cost nothing. A second generated candidate doubles generation cost; it should never be silently requested for each slideshow loop.

Recommended first paid trial: the same four Trip images on BFL Fill Pro and OpenAI Sunburst high. BFL's four outputs would cost $0.20; OpenAI's four outputs approximately $0.165 plus inputs. Compare seam, focus continuity, scene geometry, color, and subject continuation before committing an album.
