# MetaFileExtract for KOReader

A powerful plugin to automatically extract metadata from filenames, batch rename files, and sync synopses using external `.meta` files. Keep your library organized without needing external database software.

## Features
* **Auto-Parsing:** Automatically detects Title, Author, Series, and Volume Index from your file names.
* **Batch Rename:** Rename all files in a folder at once with customizable patterns.
* **Sequential Numbering:** Add automatic numbering (e.g., `Title #1 - Author - Series #1`) to your files.
* **Metadata Sync:** Uses simple `.meta` files for book or series descriptions.
* **Clean Interface:** Uses `.meta` files, which are automatically ignored by KOReader's file manager to prevent clutter.

## Installation
1. Download the plugin folder.
   https://github.com/RafaelMeirim/metafileextract.koplugin/releases/download/v1.5.0/metafileextract.koplugin.zip
3. Connect your e-reader to your computer.
4. Place the folder into `koreader/plugins/`.
5. Restart KOReader.

## How to Use

### Single File Rename
1. Press and hold a file in the File Manager.
2. Tap **"Rename for MetaFileExtract"** from the context menu.
3. Edit the metadata fields (Title, Authors, Keywords, Series, Series Number).
4. Tap **"Rename"** to apply changes to both filename and metadata.

### Batch Rename (Multiple Files)
1. Navigate to the folder containing your books.
2. Tap the **Menu icon** (top right) and select **"Rename All Files in Folder"**.
3. Fill in the common fields:
   - **Title:** Main title for all files (required)
   - **Authors:** Author names (required)
   - **Keywords:** Optional tags or categories
   - **Series:** Series name (required)
4. Configure options:
   - **Ordering:** Choose sort order (From filename, Alphabetical, Date modified)
   - **Numbering:** Toggle to include sequential numbers (e.g., `#1`, `#2`) after the title
5. Tap **"Preview"** to see the changes before applying.
6. Tap **"Rename All"** to execute.

### Extract Metadata from Filenames
1. Navigate to the folder containing your books.
2. Tap the **Menu icon** (top right) and select **"Extract Metadata From Filenames"**.
3. The plugin will parse all filenames and save the metadata to KOReader's database.

### Using Descriptions (Synopses)
1. Create a text file with your description.
2. Rename it to match your **Book Title** or **Series Name** and change the extension to `.meta`.
   - *Example:* `The Midnight Library.meta` or `Death Note.meta`.
3. Place this file in the same folder as your books.
4. Run **"Extract Metadata From Filenames"** to sync descriptions to your books.

## Filename Pattern
The plugin uses the pattern: `Title - Author - Keyword(s) - Series Name #Index.ext`

### Examples

**Series (Manga/Books):**
* `Shangri-la Frontier - Katarina - Adventure - Shangri-la Frontier #1.cbz`
* `Death Note - Tsugumi Ohba - Thriller - Death Note #1.cbz`
* `One Punch-Man - ONE & Yusuke Murata - Action - One Punch-Man #1.cbz`
* `Harry Potter - J.K. Rowling - Fantasy - Harry Potter #1.epub`

**With Sequential Numbering (Batch Rename):**
* `Harry Potter #1 - J.K. Rowling - Fantasy - Harry Potter #1.epub`
* `Harry Potter #2 - J.K. Rowling - Fantasy - Harry Potter #2.epub`
* `Harry Potter #3 - J.K. Rowling - Fantasy - Harry Potter #3.epub`

**Standalone Books:**
* `The Midnight Library - Matt Haig - Fiction.epub`
* `Rich Dad Poor Dad - Robert Kiyosaki & Sharon Lechter - Personal Finance.epub`
* `The Little Prince - Antoine de Saint-Exupéry - Childrens Literature.epub`
* `Project Hail Mary - Andy Weir - Sci-Fi.epub`

> **Note on Authors and Keywords:** You can list multiple authors or keywords by separating them with `&` or `,`. 
> *Example:* `Title - Author A & Author B - Sci-Fi, Space Opera - Series Name #1.epub`

## Sorting Order Options

When using Batch Rename, you can choose how files are ordered:

| Order | Description |
|-------|-------------|
| **From filename** | Sorts by numbers found in original filenames |
| **Alphabetical** | Sorts alphabetically by filename |
| **Date modified** | Sorts by file modification date (oldest first) |

## Preview Mode

Before applying batch rename, use **Preview** to see all changes.

The preview shows up to 10 files per page.

## Important Notes

- The plugin only works with supported formats: `.cbz`, `.cbr`, `.cbt`, `.epub`, `.pdf`, `.mobi`, `.azw`, `.azw3`, `.fb2`, `.djvu`, `.zip`
- Metadata is stored in KOReader's `custom_props` and can be viewed in the book's information panel.
- Batch rename saves metadata automatically - no need to run "Extract Metadata" afterward.

> **Warning:** Always keep a backup of your files before running bulk renaming operations.
