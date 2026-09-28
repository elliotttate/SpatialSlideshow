# Spatial Slideshow 0.9.0

Photos can now animate directly from their cached 3D scenes, and you can explore a paused photo with the mouse, trackpad, or WASD. This release also adds a native macOS screen saver and full circular camera motion at higher strengths.

## Changes

- Add **Settings → Playback → Real-time 3D rendering**. It targets 60 fps, skips movie encoding for new scenes, and updates camera movement, duration, framing, and zoom without regenerating the scene. Regular clip playback remains the default; turn realtime rendering off for MP4 export.
- While a live scene is paused, drag over the image, scroll with two fingers, or use **W/A/S/D** to move the camera. Releasing the controls holds the viewpoint; resuming smoothly returns to the slideshow path. Changing photos resets the manual offset. Videos and prepared movie fallbacks pause normally.
- Cache Gaussian scenes across launches with a 4 GiB limit. Active scenes and up to six prepared-ahead scenes are protected; older unused scenes may be regenerated when needed. Existing photo, expansion, and video caches are retained.
- Increase motion strength up to **4×**. Above 2×, paths curve into an orbit; from 2.5× they complete a full circle, with higher strength widening the loop. Existing clips at 2× or below remain reusable.
- Add **Settings → Screen Saver** to share a prepared slideshow with the included macOS screen saver. It plays silently while the app is closed, supports live scenes and prepared clips, and inherits framing, fade, and shuffle settings. It does not run inference or download photos while idle.
- Use Metal compositing for screen saver playback and fades, retain frames while media loads, and improve scene/video fallback, paused navigation, and playlist updates.
- Preserve the full fade duration when the next image becomes ready near the end of a clip, holding the outgoing final frame through the transition.
- Simplify feature names in the app and documentation. Local expansion choices keep their existing behavior and requirements; the native Photos Extend backend stays under **Advanced research tools**.
- Include the MIT license and reusable border-detail research sources. The detail-synthesis research is not enabled in playback.

Existing preferences are preserved. To use realtime rendering, enable it and restart playback. After updating the app, choose **Update Screen Saver** if you previously installed the component. macOS may retain an older component until you log out and back in.

## Validation

All 21 native synthetic suites and 48 Python tests passed. Coverage includes camera orbits, GPU rendering and transitions, paused mouse/WASD movement, navigation, frame retention, scene-cache reuse and eviction, screen saver playlists, and model setup/recovery. The signed app's realtime controls were also checked with the Trip album.

## Download

Download `SpatialSlideshow-0.9.0-macOS-arm64.zip`, extract it, and open **Spatial Slideshow.app**. Requires **Apple Silicon, macOS 27, and compatible Apple Photos Reframe assets**.

The app and embedded screen saver are Developer ID signed. The release app is notarized by Apple and includes a stapled ticket. It uses private Apple frameworks, so future macOS changes may require an app update. Apple frameworks, model weights, personal media, generated caches, and private diagnostic logs are not included.
