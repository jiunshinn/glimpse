<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Glimpse icon">
</p>

<h1 align="center">Glimpse</h1>

<p align="center">
  A fast, modern image viewer for macOS.<br>
  Open one image, then browse the whole folder with the arrow keys.
</p>

---

## Why

Finder's Quick Look and Preview make it hard to look through a folder of images:

- You open one image and cannot go to the next one with the arrow keys.
- You must select all the images first, and then open them together.

Glimpse fixes this. Double-click an image (or choose **Open With ▸ Glimpse**), and every image in that folder is ready. Press **→** for the next one.

## Features

- **Browse a folder with the keyboard**: ← → / Space, Home / End, and a two-finger swipe on the trackpad.
- **Filmstrip and grid**: a thumbnail strip at the bottom, and a grid of the whole folder (press **G**).
- **Fast**: images decode in the background. The next and previous images load before you need them. A thumbnail shows at once while the full image loads.
- **Zoom and pan**: pinch, ⌥-scroll or the mouse wheel zooms at the pointer. Double-click switches between "fit" and a close-up. Drag to pan. 100% means one image pixel on one screen pixel.
- **Modern UI**: Liquid Glass on macOS 26 (translucent materials on macOS 14–15), a blurred ambient background from the current image, and full screen with controls that hide.
- **Videos**: MOV, MP4, M4V and other files that macOS can play show in the same folder sequence, with the system player controls. Seek, step by frame, change the speed and the volume from the keyboard, loop, and use picture in picture. A long video starts again where you stopped it. Thumbnails show the duration.
- **Documents**: PDF, Word (DOCX, DOC), Excel (XLSX, XLS, CSV), PowerPoint (PPTX, PPT), Pages, Numbers, Keynote, RTF and OpenDocument files show in the same folder sequence. PDFs open with PDFKit: the whole page fits, and you can scroll, zoom, rotate, select text and unlock a protected file. Other documents show with Quick Look, so you do not need Office or iWork. Spreadsheets keep their sheet tabs.
- **Info panel**: dimensions, color profile, camera, lens, exposure, date taken and GPS location (press **I**). For videos: duration, frame rate, codec, HDR, bit rate and audio. For documents: pages, page size, title, author and the app that made the file.
- **Clean up a folder**: ⌘⌫ moves the image to the Trash and shows the next one. ⌘Z puts it back.
- **Live folder**: new, removed and renamed files show up at once.
- **Formats**: everything that macOS can read, including JPEG, PNG, HEIC/HEIF, AVIF, WebP, GIF (animated), TIFF, BMP, PSD, ICNS and camera RAW. EXIF orientation is applied.
- **Native and small**: Swift, AppKit and SwiftUI. No Electron, no dependencies.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (Xcode 26 to build the Liquid Glass UI)

## Build and install

```sh
git clone https://github.com/jiunshinn/glimpse.git
cd glimpse
make install      # builds a release app and copies it to /Applications
```

Other commands:

| Command | What it does |
| --- | --- |
| `make app` | Builds `build/Glimpse.app` (universal: Apple silicon and Intel) |
| `make run OPEN=~/Pictures` | Builds a debug app and opens a folder or an image |
| `make icon` | Draws the app icon again (`Resources/AppIcon.icns`) |
| `make clean` | Removes build files |

The app is signed ad hoc. If macOS blocks a copy that you downloaded, right-click the app and choose **Open**.

## Make Glimpse the default viewer

Choose **Glimpse ▸ Make Default Image Viewer…**. Or, in Finder: select an image, press ⌘I, choose Glimpse under **Open with**, and click **Change All…**.

## Keyboard shortcuts

Press **?** in the app to see this list.

| Key | Action |
| --- | --- |
| ← → / Space | Previous / next image (⇧Space: previous) |
| ↑ ↓ | Previous / next image; in the grid, move by a row |
| Home / End | First / last image |
| G | Grid of the whole folder |
| Return | Open the selected image (grid) |
| + / − | Zoom in / out (in the grid: larger / smaller tiles) |
| Z or double-click | Fit ↔ close-up |
| ⌘0 / ⌘9 | Actual size / zoom to fit |
| R / ⇧R | Rotate right / left (view only, the file does not change) |
| F | Full screen |
| I | Info panel |
| T | Thumbnail filmstrip |
| Esc | Close a panel, leave the grid, or exit full screen |
| ⌘⌫ | Move to Trash (⌘Z: undo) |
| ⌘C / ⌥⌘C | Copy image / copy file path |
| ⇧⌘R | Show in Finder |

While a video shows, ← → still go to the previous or next file. These keys control the video:

| Key | Action |
| --- | --- |
| Space or K | Play / pause |
| ⇧← / ⇧→ | Back / forward 5 seconds |
| J / L | Back / forward 10 seconds |
| , / . | Previous / next frame |
| [ / ] / \ | Slower / faster / normal speed |
| + / − | Volume up / down |
| M | Mute |
| ⌥⌘L | Loop |
| ⇧⌘C | Copy the current frame |

While a document shows, ← → also go to the previous or next file. These keys control the document:

| Key | Action |
| --- | --- |
| ↑ ↓ / Space | Scroll (⇧Space: scroll back) |
| Page Up / Page Down | Scroll by a page |
| Home / End | Start / end of the document |
| + / − | Zoom in / out (PDF) |
| Z | Whole page ↔ page width (PDF) |
| ⌘0 / ⌘9 | Actual size / whole page (PDF) |
| R / ⇧R | Rotate right / left (PDF, view only) |
| ⌘C | Copy the selected text (in a PDF without selected text: the file) |

Single-key shortcuts use the key position, so they also work with a non-Latin input source (for example, Korean).

## How it works

```
Sources/Glimpse
├── App/        App delegate, menus, window controller (toolbar, keyboard)
├── Model/      Folder scanning and sorting, folder watcher, ViewerModel (@Observable), video playback
├── Imaging/    ImageIO, AVFoundation and Quick Look decoding, background pipeline with caches, metadata, pasteboard
├── Canvas/     Zoomable NSScrollView; the image is a layer, so the GPU scales it
└── Views/      SwiftUI: filmstrip, grid, info panel, document stage, empty state, overlays
```

- One window shows one folder. Opening one file scans its folder. Opening several files shows only those files.
- Videos play with AVKit's `AVPlayerView`. One `AVPlayer` serves a window, so the volume and the speed stay the same from video to video. Video thumbnails come from `AVAssetImageGenerator` through the same thumbnail cache as images.
- PDFs show in PDFKit's `PDFView`. Other documents show in Quick Look's `QLPreviewView`, which uses the previews that macOS includes. Document thumbnails come from `QLThumbnailGenerator`. Plain text files are not part of the sequence, because a text file next to photos is usually a note.
- `ImagePipeline` decodes on `OperationQueue`s. Full images are cached (up to 1/8 of the memory). Thumbnails are cached separately, and a thumbnail request stops when its cell scrolls away.
- The app is not sandboxed, because a sandboxed app cannot read the other files in the folder of the file that you opened. macOS can ask once for access to folders such as Desktop or Downloads.

## Roadmap

- Slideshow
- HDR display for photos with a gain map
- Sort by date taken
- Rename and tag files
- Compare two images side by side

## Contributing

Issues and pull requests are welcome. Please keep the app fast and free of dependencies.

## License

[MIT](LICENSE)
