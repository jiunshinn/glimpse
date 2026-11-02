<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Glimpse icon">
</p>

<h1 align="center">Glimpse</h1>

<p align="center">
  A fast, modern viewer for images, videos and documents on macOS.<br>
  Open one file, then browse the whole folder with the arrow keys.
</p>

---

## Why

Finder's Quick Look and Preview make it hard to look through a folder of photos, videos and documents:

- You open one file and cannot go to the next one with the arrow keys.
- You must select all the files first, and then open them together.

Glimpse fixes this. Double-click a file (or choose **Open With ▸ Glimpse**), and every image, video and document in that folder is ready. Press **→** for the next one.

## Features

### Viewer

- **Browse a folder with the keyboard**: ← → / Space, Home / End, and a two-finger swipe on the trackpad.
- **Filmstrip and grid**: a thumbnail strip at the bottom, and a grid of the whole folder (press **G**). Pinch the grid to show more or fewer columns, as in Photos.
- **Fast**: images decode in the background. The next and previous images load before you need them. A thumbnail shows at once while the full image loads.
- **Zoom and pan**: pinch, ⌥-scroll or the mouse wheel zooms at the pointer. Double-click switches between "fit" and a close-up. Drag to pan. 100% means one image pixel on one screen pixel.
- **Drag out**: drag the image, a filmstrip thumbnail or a grid cell to Finder, Mail, a browser or any other app. When you zoom in, a drag pans, so use ⌘-drag. You can also drag the file icon next to the window title. A drop in Finder copies the file and does not move it.
- **Modern UI**: Liquid Glass on macOS 26 (translucent materials on macOS 14–15), a blurred ambient background from the current image, and full screen with controls that hide.
- **Videos**: MOV, MP4, M4V and other files that macOS can play show in the same folder sequence, with the system player controls. Seek, step by frame, change the speed and the volume from the keyboard, loop, and use picture in picture. A long video starts again where you stopped it. Thumbnails show the duration.
- **Documents**: PDF, Word (DOCX, DOC), Excel (XLSX, XLS, CSV), PowerPoint (PPTX, PPT), Pages, Numbers, Keynote, RTF and OpenDocument files show in the same folder sequence. PDFs open with PDFKit: the whole page fits, and you can scroll, zoom, rotate, select text and unlock a protected file. Other documents show with Quick Look, so you do not need Office or iWork. Spreadsheets keep their sheet tabs.
- **Info panel**: dimensions, color profile, camera, lens, exposure, date taken and GPS location (press **I**). For videos: duration, frame rate, codec, HDR, bit rate and audio. For documents: pages, page size, title, author and the app that made the file.
- **Clean up a folder**: ⌘⌫ moves the file to the Trash and shows the next one. ⌘Z puts it back.
- **Live folder**: new, removed and renamed files show up at once.
- **Sort**: by name, date modified, date created or size, ascending or descending. Pinned files come first in every sort order (see **Pins** under [Workspace](#workspace)).
- **Formats**:
  - Images: everything that macOS can read, including JPEG, PNG, HEIC/HEIF, AVIF, WebP, GIF (animated), TIFF, BMP, PSD, ICNS and camera RAW. EXIF orientation is applied.
  - Videos: everything that macOS can play, including MOV, MP4, M4V, 3GP, AVI and MPEG.
  - Documents: PDF, DOCX, DOC, XLSX, XLS, CSV, PPTX, PPT, Pages, Numbers, Keynote, RTF and OpenDocument.
- **Native and small**: Swift, AppKit and SwiftUI. No Electron, no dependencies.

### Workspace

A workspace is a list of folders that you add. The sidebar shows them, and all windows and tabs share them. The files stay where they are.

- **Sidebar** (⌃⌘S): four sections with file counts.
  - **Favorites**: **Starred** (the starred files of all folders) and the folders that you pin. To pin a folder, press **⇧P**, or drop the folder on Favorites. See **Pins** below.
  - **Folders**: the folders of the workspace. Add a folder with **Add Folder…** (⇧⌘O), with the **+** row, or drop a folder on the sidebar. Drag a folder to change the order. Glimpse keeps a bookmark to each folder, so a moved or renamed folder still opens. A folder that Glimpse cannot read shows a warning symbol.
  - **Tags**: Keep, Edit, Client, Print and Reject, then the other Finder tags of the files in the workspace. A tag shows all the files with that tag, from all folders.
  - **Boards**: your boards, and **New Board**.
  - At the bottom: the **Reopen at Launch** switch.
  - Click a row to open it in the current tab. If a tab shows it already, Glimpse goes to that tab. ⌘-click opens it in a new tab.
- **Live folders**: Glimpse watches every workspace folder. When a file arrives, the count changes. The folder row, the grid cell and the filmstrip cell show a green mark until you view the file.
- **Tabs**: one window, many tabs. These are the standard macOS tabs: ⌘T, the **+** button of the tab bar, and ⌃Tab and ⌃⇧Tab. Drag a tab out of the tab bar to make a new window. Each tab shows a folder, a list of files, a smart list (Starred or a tag) or a board. Each tab keeps its own file, view (viewer or grid) and filter. The tab bar shows the name of the folder. A new tab starts with Quick Search.
- **Quick Search** (⌘K): finds files, folders, tags, boards and commands in all workspace folders, the current tab and the recent files. The letters of the query must come in order, but they do not have to be side by side (for example, `dji2` finds `DJI_0022.JPG`). A preview with the details of the result shows on the right. See [Quick Search](#quick-search) for the filters and the commands.
- **File type filter**: the **File Types** toolbar button and **View ▸ File Types** show only images, videos or documents. The toolbar menu also shows each format with its count (for example HEIC, DNG, MP4 and PDF), so you can show only some formats. The filmstrip, the grid and the arrow keys obey the filter. The toolbar button is filled while a filter is on, and the window subtitle shows the filter. If the filter hides all files, the window shows a **Show All Types** button. A tab that opens a different folder starts with no filter.
- **Tags**: **1** to **5** add or remove the tags Keep, Edit, Client, Print and Reject. Glimpse writes Finder tags with their colors, so Finder and Spotlight show the same tags. When Glimpse becomes active, it reads the tags again, so changes from Finder show too.
- **Stars**: **S** stars a file or removes the star. Starred files show in **Favorites ▸ Starred**.
- **Pins**:
  - **P** pins the current file to the top of its folder, or unpins it. A pinned file comes first in the viewer, the filmstrip, the grid and the arrow-key order, in every sort order. If you pin more than one file, the pinned files keep the sort order among themselves. An unpinned file goes back to its sorted place.
  - **⇧P** pins the folder of the current tab to **Favorites** in the sidebar, or unpins it. In a list of files (for example Starred), it uses the folder of the current file. If the workspace does not have the folder, Glimpse adds it. You can also drop a folder on Favorites, or right-click a folder in the sidebar.
  - You can also use the **Workspace** menu, Quick Search, or the context menu of a grid cell or a filmstrip thumbnail.
- **Marks**: the grid shows a pin, a star and color dots for the tags. The filmstrip shows the pin. The window subtitle shows them for the current file, for example `3 of 10 · Pinned · ★ · Keep, Print`.
- **Boards**: a free canvas for files from different folders, and for notes. A board keeps references to the files, not copies. See [Boards](#boards).
- **Reopen at launch**: Glimpse saves the tabs of each window, and the current file, the view and the filter of each tab. At the next launch, the same tabs open. Turn this off with the switch at the bottom of the sidebar or with **Workspace ▸ Reopen Tabs at Launch**.
- **Storage**: the workspace (folders, pins, stars, boards and saved tabs) is in `~/Library/Application Support/Glimpse/Workspace.json`. Tags are in the files, as Finder tags.

### Quick Search

Press **⌘K**, or click the magnifying glass in the toolbar. Without a query, Quick Search shows the recent files, the folders and some commands.

| Key | Action |
| --- | --- |
| ↑ ↓ | Choose a result |
| ↵ or click | Open the result. A folder that a tab shows already opens in that tab |
| ⌘↵ or ⌘-click | Open the result in a new tab |
| ⌥↵ or ⌥-click | Put the file on the board |
| Esc or a click outside | Close Quick Search |

Filters (you can use more than one, with or without other words):

| Filter | Finds |
| --- | --- |
| `type:image`, `type:video`, `type:doc` | One kind of file (`type:images`, `type:videos` and `type:documents` work too) |
| `type:raw` | Camera RAW files (DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2) |
| `type:heic`, `type:jpeg`, `type:pdf`… | One format |
| `tag:keep` | Files with a tag. The start of the tag name is enough (`tag:ke`) |
| `in:drone` | Files in folders with this text in the name |
| `is:starred` | Starred files |
| `is:pinned` | Pinned files |
| `is:new` | Files that arrived while Glimpse was open and that you did not view yet |

Commands:

| Command | What it does |
| --- | --- |
| Add “*folder*” to Workspace | Adds the folder of the current tab (shows only when the workspace does not have it) |
| Add Folder to Workspace… | Opens a panel to choose folders (⇧⌘O) |
| New Tab | Opens a new tab (⌘T) |
| New Board | Makes an empty board and opens it in a new tab |
| Show Only Images / Videos / Documents | Filters the current tab |
| Show All File Types | Removes the filter |
| Open Starred Files | Shows Favorites ▸ Starred |
| Turn On / Turn Off Reopen at Launch | Changes the Reopen at Launch setting |
| Show or Hide the Sidebar | Same as ⌃⌘S |
| Show the Grid or the Viewer | Same as G |
| Pin “*file*” to the Top / Unpin “*file*” from the Top | Same as P |
| Pin “*folder*” to Favorites / Unpin “*folder*” from Favorites | Same as ⇧P |

In a new tab, ↵ opens the result in that tab. In **Add Files to Board** mode, Quick Search shows only files, and ↵ puts the file on the board.

### Boards

- Make a board with **New Board** in the sidebar, in the Workspace menu or in Quick Search.
- Put files on a board:
  - Press **B** (or **Workspace ▸ Add to Board**) in the viewer or the grid. The file goes to the board that a tab showed last. If there is no board, Glimpse makes one.
  - On the board, click **Add Files** in the toolbar. Quick Search opens, and ↵ puts the file on the board.
  - Press **⌥↵** on a file in Quick Search.
  - Drop files from Finder on the board. They go where you drop them.
- Drag an item to move it. Click an item to select it, then drag the circle at its corner to resize it. The selected item comes to the front.
- Double-click a file to open it in the viewer. A tab that shows its folder already opens it.
- **Add Note** in the toolbar puts a note on the board. Type in the note. Drag the bar at the top of the note to move it.
- **Arrange** puts all items in rows that fit the width of the window.
- **⌫** removes the selected item. **Esc** clears the selection. The file stays in its folder.
- A file that was moved or deleted shows "Glimpse can’t find this file".
- Right-click a board in the sidebar to rename or delete it. Deleting a board does not change the files.

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
| `make run OPEN=~/Pictures` | Builds a debug app and opens a folder or a file |
| `make icon` | Draws the app icon again (`Resources/AppIcon.icns`) |
| `make clean` | Removes build files |

The app is signed ad hoc. If macOS blocks a copy that you downloaded, right-click the app and choose **Open**.

## Make Glimpse the default viewer

Choose **Glimpse ▸ Make Default Image Viewer…**. Or, in Finder: select an image, press ⌘I, choose Glimpse under **Open with**, and click **Change All…**.

The menu command changes only the common image types. To open a video or a document type in Glimpse, do the Finder steps with a file of that type.

## Keyboard shortcuts

Press **?** in the app to see this list.

| Key | Action |
| --- | --- |
| ← → / Space | Previous / next file (⇧Space: previous) |
| ↑ ↓ | Previous / next file; in the grid, move by a row |
| Home / End | First / last file |
| Page Up / Page Down | Move by 10 files (in the grid: by 4 rows) |
| G | Grid of the whole folder |
| Return / Space | Open the selected file (grid) |
| + / − | Zoom in / out (in the grid: larger / smaller tiles) |
| Z or double-click | Fit ↔ close-up |
| ⌘0 / ⌘9 | Actual size / zoom to fit |
| R / ⇧R | Rotate right / left (view only, the file does not change) |
| ⌘L / ⌘R | Rotate left / right |
| F or ⌃⌘F | Full screen (the sidebar hides in full screen) |
| I | Info panel |
| T | Thumbnail filmstrip |
| Esc | Close a panel, leave the grid, or exit full screen |
| ⌘⌫ | Move to Trash (⌘Z: undo, ⇧⌘Z: redo) |
| ⌘C / ⌥⌘C | Copy the image (a video or a document: the file) / copy the file path |
| ⇧⌘R | Show in Finder |
| ⌘O | Open files or folders |
| ? or ⌘/ | Keyboard shortcuts |

Workspace and tabs:

| Key | Action |
| --- | --- |
| ⌘K | Quick Search |
| ⇧⌘O | Add a folder to the workspace |
| ⌃⌘S | Show or hide the sidebar |
| S | Star or unstar the file |
| P | Pin the file to the top of its folder, or unpin it |
| ⇧P | Pin the folder to Favorites, or unpin it |
| 1 – 5 | Add or remove a tag: 1 Keep, 2 Edit, 3 Client, 4 Print, 5 Reject |
| B | Put the file on the board |
| ⌘T | New tab |
| ⌘W | Close the tab |
| ⇧⌘W | Close the window and all its tabs |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |

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

On a board:

| Key | Action |
| --- | --- |
| ⌫ | Remove the selected item from the board |
| Esc | Clear the selection (then: exit full screen) |
| F | Full screen |

In Quick Search, see [Quick Search](#quick-search).

Single-key shortcuts use the key position, so they also work with a non-Latin input source (for example, Korean). While you type in a text field (Quick Search, a note, a PDF password), the keys go to the field.

## Mouse and trackpad

| Action | Result |
| --- | --- |
| Two-finger swipe left / right | Next / previous file (when the image fits) |
| Pinch, ⌥-scroll or the mouse wheel | Zoom at the pointer |
| Double-click the image | Fit ↔ close-up |
| Drag the image (zoomed in) | Pan |
| Drag the image (fit) / ⌘-drag the image (zoomed in) | Drag the file to another app |
| Drag a filmstrip thumbnail or a grid cell | Drag the file to another app or a board |
| Drag the icon next to the window title | Drag the file to another app |
| Drag the space around the image (fit) | Move the window |
| Pointer near the left or right edge | Previous / next buttons |
| Click a filmstrip thumbnail | Show that file |
| Click / double-click a grid cell | Select / open the file |
| Pinch the grid | Larger / smaller tiles; the file under the pointer stays in place |
| Drop files or a folder on the viewer | Open them in this tab |
| Click a sidebar row | Open it in this tab, or go to the tab that shows it |
| ⌘-click a sidebar row | Open it in a new tab |
| Drop a folder on the sidebar | Add it to the workspace |
| Drop a folder on Favorites | Pin it (Glimpse adds it to the workspace if necessary) |
| Right-click a grid cell or a filmstrip thumbnail | Pin, star, Show in Finder, pin the folder |
| Drag a folder row | Change the order of the folders |
| Drop files on a board | Put them on the board at that place |
| Drag a board item / its corner | Move / resize the item |
| Double-click a file on a board | Open it in the viewer |

## Menus

**Glimpse**

| Command | Key | What it does |
| --- | --- | --- |
| About Glimpse | | Shows the version |
| Make Default Image Viewer… | | Opens JPEG, PNG, HEIC, GIF, WebP, TIFF, BMP and AVIF files with Glimpse |
| Services | | The macOS services |
| Hide Glimpse / Hide Others / Show All | ⌘H / ⌥⌘H | Hides or shows apps |
| Quit Glimpse | ⌘Q | Quits. With Reopen at Launch on, the tabs open again next time |

**File**

| Command | Key | What it does |
| --- | --- | --- |
| New Tab | ⌘T | Opens a new tab with Quick Search |
| Open… | ⌘O | Opens files or folders |
| Close Tab | ⌘W | Closes the tab |
| Close Window | ⇧⌘W | Closes the window and all its tabs |
| Show in Finder | ⇧⌘R | Shows the current file in Finder |
| Move to Trash | ⌘⌫ | Moves the current file to the Trash and shows the next file |

**Edit**

| Command | Key | What it does |
| --- | --- | --- |
| Undo / Redo | ⌘Z / ⇧⌘Z | Puts back a file from the Trash, or moves it to the Trash again |
| Copy | ⌘C | Copies the image (a video or a document: the file) |
| Copy File Path | ⌥⌘C | Copies the path of the file |
| Copy Frame | ⇧⌘C | Copies the current frame of a video |

**View**

| Command | Key | What it does |
| --- | --- | --- |
| Show Sidebar / Hide Sidebar | ⌃⌘S | Shows or hides the workspace sidebar |
| Grid | G | Grid of the whole folder |
| Thumbnails | T | The filmstrip |
| Info | I | The info panel |
| Ambient Background | | The blurred background from the current image |
| Zoom In / Zoom Out | ⌘= / ⌘− | Zooms the image or the PDF |
| Actual Size / Zoom to Fit | ⌘0 / ⌘9 | 100%, or the whole image |
| Rotate Left / Rotate Right | ⌘L / ⌘R | Rotates the view (the file does not change) |
| Sort By ▸ Name, Date Modified, Date Created, Size, Ascending, Descending | | Changes the order of the files |
| File Types ▸ All Types, Images Only, Videos Only, Documents Only | | Filters the current tab |
| Enter Full Screen | ⌃⌘F | Full screen |

**Workspace**

| Command | Key | What it does |
| --- | --- | --- |
| Quick Search… | ⌘K | Opens or closes Quick Search |
| Add Folder to Workspace… | ⇧⌘O | Adds folders to the sidebar |
| Add “*folder*” to Workspace | | Adds the folder of the current tab |
| Pin “*folder*” to Favorites / Unpin “*folder*” from Favorites | ⇧P | Pins the folder of the current tab to Favorites, or unpins it |
| Pin to Top / Unpin from Top | P | Pins the current file to the top of its folder, or unpins it |
| Star / Remove Star | S | Stars the current file, or removes the star |
| Tags ▸ Keep, Edit, Client, Print, Reject | 1 – 5 | Adds or removes a Finder tag. A check mark shows the tags of the file |
| Add to Board | B | Puts the current file on the board |
| New Board | | Makes a board and opens it in a new tab |
| Add Files to Board… | | Opens Quick Search to put files on the board (board tab) |
| Add Note | | Puts a note on the board (board tab) |
| Arrange Board | | Puts the items in rows (board tab) |
| Reopen Tabs at Launch | | Turns Reopen at Launch on or off |

**Playback** (while a video shows)

| Command | Key |
| --- | --- |
| Play/Pause | Space |
| Loop | ⌥⌘L |
| Jump Back / Forward 5 Seconds | ⇧← / ⇧→ |
| Jump Back / Forward 10 Seconds | J / L |
| Previous Frame / Next Frame | , / . |
| Slower / Faster / Normal Speed | [ / ] / \ |
| Volume Up / Volume Down | = / − |
| Mute | M |

**Go**

| Command | Key |
| --- | --- |
| Next Image / Previous Image | → / ← |
| First Image / Last Image | ⌘↑ / ⌘↓ |

**Window**: Minimize (⌘M), Zoom, Bring All to Front, and the list of open windows and tabs.

**Help**: Keyboard Shortcuts (⌘/).

## Toolbar

In the viewer and the grid:

| Button | What it does |
| --- | --- |
| Sidebar | Shows or hides the sidebar |
| Rotate | Rotates the image or the PDF to the right |
| Move to Trash | Moves the current file to the Trash |
| Share | Shares the current file |
| Sort | The Sort By menu |
| File Types | The filter menu: all types, images, videos, documents, and each format with its count |
| Grid | The grid of the folder |
| Info | The info panel |
| Quick Search | Opens Quick Search (⌘K) |

On a board:

| Button | What it does |
| --- | --- |
| Sidebar | Shows or hides the sidebar |
| Add Files | Opens Quick Search to put files on the board |
| Add Note | Puts a note on the board |
| Arrange | Puts the items in rows |
| Quick Search | Opens Quick Search (⌘K) |

## Context menus

| Where | Commands |
| --- | --- |
| A folder in the sidebar | Open in New Tab, Show in Finder, Pin to Favorites / Unpin from Favorites, Remove from Workspace |
| A file in the grid or the filmstrip | Pin to Top / Unpin from Top, Star / Remove Star, Show in Finder, Pin “*folder*” to Favorites / Unpin “*folder*” from Favorites |
| Starred or a tag in the sidebar | Open in New Tab |
| A board in the sidebar | Open in New Tab, Rename…, Delete Board… |
| A file on a board | Open, Show in Finder, Remove from Board |
| A note on a board | Remove from Board |

"Remove from Workspace" and "Delete Board…" do not change the files on the disk.

## How it works

```
Sources/Glimpse
├── App/        App delegate, menus, window controller (toolbar, keyboard)
├── Model/      Folder scanning and sorting, folder watcher, ViewerModel (@Observable), video playback,
│               workspace (folders, stars, Finder tags, boards, saved tabs), Quick Search
├── Imaging/    ImageIO, AVFoundation and Quick Look decoding, background pipeline with caches, metadata, pasteboard
├── Canvas/     Zoomable NSScrollView; the image is a layer, so the GPU scales it
└── Views/      SwiftUI: sidebar, board, Quick Search, filmstrip, grid, info panel, document stage, empty state, overlays
```

- One tab shows one folder. Opening one file scans its folder. Opening several files shows only those files. Each tab is a window in a macOS tab group, with its own viewer model.
- The workspace (`Workspace`) is shared by all tabs. It scans each workspace folder in the background, watches it with a file system event source, and reads the Finder tags (the `com.apple.metadata:_kMDItemUserTags` attribute) of its files. Starred files and tag lists are smart lists: Glimpse collects their files from the workspace folders and updates them when the folders, the stars or the tags change.
- Pins are paths in the workspace file. `FolderScanner` sorts the files by the sort key, then moves the pinned files to the start. When a pin changes, every tab sorts its files again and keeps the current file.
- The sidebar is the sidebar item of an `NSSplitViewController`, so it gets the floating Liquid Glass sidebar on macOS 26. Quick Search and boards are SwiftUI. Board items use larger previews (1200 pixels) from a separate cache.
- Videos play with AVKit's `AVPlayerView`. One `AVPlayer` serves a window, so the volume and the speed stay the same from video to video. Video thumbnails come from `AVAssetImageGenerator` through the same thumbnail cache as images.
- PDFs show in PDFKit's `PDFView`. Other documents show in Quick Look's `QLPreviewView`, which uses the previews that macOS includes. Document thumbnails come from `QLThumbnailGenerator`. Plain text files are not part of the sequence, because a text file next to photos is usually a note.
- `ImagePipeline` decodes on `OperationQueue`s. Full images are cached (up to 1/8 of the memory). Thumbnails are cached separately, and a thumbnail request stops when its cell scrolls away.
- The app is not sandboxed, because a sandboxed app cannot read the other files in the folder of the file that you opened. macOS can ask once for access to folders such as Desktop or Downloads.

## Roadmap

- Slideshow
- HDR display for photos with a gain map
- Sort by date taken
- Rename files
- Your own tag names and colors for the keys 1 to 5
- More than one workspace
- Compare two images side by side

## Development

Debug builds (`make debug`, `make run`) read these environment variables:

| Variable | What it does |
| --- | --- |
| `GLIMPSE_WORKSPACE=/path/to/file.json` | Uses another workspace file, so test runs do not change your workspace |
| `GLIMPSE_DEBUG="wait,grid,info"` | Runs commands after launch, for screenshots. `wait` adds 1 second. Other commands: `next`, `info`, `grid`, `shortcuts`, `zoom`, `rotate`, `play`, `forward`, `faster`, `volume`, `loop`, `search`, `query:text` (`_` for a space), `newtab`, `starred`, `folder:N`, `filter:image` / `filter:video` / `filter:document`, `board`, `arrange`, `note`, `sidebar`, `key:name` (a key in the window, for example `key:s` or `key:down`), `appkey:c` (a key through the menus), `log` |

## Contributing

Issues and pull requests are welcome. Please keep the app fast and free of dependencies.

## License

[MIT](LICENSE)
