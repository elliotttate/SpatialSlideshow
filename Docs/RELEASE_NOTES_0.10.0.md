# Spatial Slideshow 0.10.0

Apple Fast Clean Up borders now match the photograph's color and join it without a visible line, repeats no longer trip over scenes the cache has evicted, and new installations start with real-time 3D playback and edge expansion turned on.

## Changes

- Improve **Apple Fast Clean Up** edge expansion. The model reads the pixels under its mask as a prior, and the previous flat gray fill pulled the generated border toward gray and darkened it. The helper now fills the border with the photo's replicated edge, lets the model repaint a thin band inside the photo, matches the border to the photo in perceptual OKLab, joins the two with a four-band seam blend, and verifies that the full-resolution interior is pixel-exact before saving. See [the seam notes](APPLE_CLEANUP_SEAM.md) for measurements, the rejected per-edge tiling experiment, and limits.
- Skip repeat candidates whose cached 3D scene has since been evicted, instead of reporting a playback issue for each one. Albums larger than the 4 GiB scene cache previously produced a run of "invalid image size or manifest" issues when a repeat landed on an evicted scene. An evicted unseen candidate can no longer hold an album open after preparation ends.
- Change new-installation defaults to **8 seconds, Strong (1.75×) Varied movement, videos included, Real-time 3D rendering on, and Apple Fast Clean Up expansion at 10% per edge with a 5% zoom-out allowance**. Framing, fades, shuffle, photo quality, and output resolution are unchanged. Existing saved preferences are retained.
- Add the `expansion-compositor` synthetic test and the `FillPriorProbe` research probe. The Apple expansion cache identity changed, so earlier Apple expansions and their clips are regenerated when needed; existing files are left in place.

Apple expansion remains much faster than the FLUX engines: about 3 seconds per 12-megapixel photo on an M3 Max after the first model load, including 0.6 seconds of seam compositing. The border is still the model's low-resolution guess, so objects cut by the photo's edge can continue implausibly and large expansions under subjects stay soft.

## Validation

All 22 native synthetic suites and 48 Python tests passed. The real expansion → Apple Reframe → movie → cache pipeline passed twice on Trip exports with the signed bundle, at 20% and 5% per edge. Five Trip expansions, including a 16174-pixel panorama, reported a protected-interior error of 0, and before/after crops at native resolution were reviewed on four photos. The evicted-repeat case is covered by the extended live transport suite.

## Download

Download `SpatialSlideshow-0.10.0-macOS-arm64.zip`, extract it, and open **Spatial Slideshow.app**. Requires **Apple Silicon, macOS 27, and compatible Apple Photos Reframe assets**; Apple expansion also needs the Photos Clean Up assets, which the app requests on first use.

The app and embedded screen saver are Developer ID signed. The release app is notarized by Apple and includes a stapled ticket. It uses private Apple frameworks, so future macOS changes may require an app update. Apple frameworks, model weights, personal media, generated caches, and private diagnostic logs are not included. After updating, choose **Update Screen Saver** if you previously installed the component.
