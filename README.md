# MetaFileExtract for KOReader

A simple plugin to automatically extract metadata from filenames and sync synopses using external `.meta` files. Keep your library organized without needing external database software.

## Features
* **Auto-Parsing:** Automatically detects Title, Author, Series, and Volume Index from your file names.
* **Metadata Sync:** Uses simple `.meta` files for book or series descriptions.
* **Clean Interface:** Uses `.meta` files, which are automatically ignored by KOReader's file manager to prevent clutter.

## Installation
1. Download the plugin folder.
https://github.com/RafaelMeirim/metafileextract.koplugin/releases/download/v1.0.0/metafileextract.koplugin.zip
2. Connect your e-reader to your computer.
3. Place the folder into `koreader/plugins/`.
4. Restart KOReader.

## How to use
1. Open the File Manager in KOReader.
2. Navigate to the folder containing your books.
3. Tap the **Menu icon** (top right) and select **"Extract metadata from filenames"**.

## Filename Pattern
The plugin uses the pattern: `Title - Author - Keyword(s) - Series Name #Index.ext`

### Examples

**Series (Manga/Books):**
* `Shangri-la Frontier - Katarina - Adventure - Shangri-la Frontier #1.cbz`
* `Death Note - Tsugumi Ohba - Thriller - Death Note #1.cbz`
* `One Punch-Man - ONE & Yusuke Murata - Action - One Punch-Man #1.cbz`
* `Harry Potter - J.K. Rowling - Fantasy - Harry Potter #1.epub`

**Standalone Books:**
* `The Midnight Library - Matt Haig - Fiction.epub`
* `Rich Dad Poor Dad - Robert Kiyosaki & Sharon Lechter - Personal Finance.epub`
* `The Little Prince - Antoine de Saint-Exupéry - Childrens Literature.epub`
* `Project Hail Mary - Andy Weir - Sci-Fi.epub`

> **Note on Authors and Keywords:** You can list multiple authors or keywords by separating them with `&` or `,`. 
> *Example:* `Title - Author A & Author B - Sci-Fi, Space Opera - Series Name #1.epub`

## Using Descriptions (Synopses)
1. Create a text file with your description.
2. Rename it to match your **Book Title** or **Series Name** and change the extension to `.meta`.
   - *Example:* `The Midnight Library.meta` or `Death Note.meta`.
3. Place this file in the same folder as your books.
4. Run the plugin. It will prioritize the specific book file, then look for the series file.

## Bonus: Batch Renaming Tool (Windows)
If you have a large library and want to standardize your filenames automatically, use the provided script in the `tools/` folder.

### How to use:
1. Copy `tools/rename.bat` to your book library folder on Windows.
2. Make sure your files are named with a number (e.g., `1.cbz`, `2.cbz`...).
3. Double-click `rename.bat` and follow the prompts:
   - **Series/Book Title:** The main name.
   - **Author:** The author's name.
   - **Keyword:** Categories (e.g., `Manga` or `Sci-Fi`).
   - **Series Name:** The name of the series (if applicable).
   - **Include number:** Choose 'y' to keep the original numbering.

The script will automatically rename your files to match the: `Title - Author - Keyword - Series Name #Number.ext` pattern.

> **Warning:** Always keep a backup of your files before running bulk renaming scripts.

## Troubleshooting
If a book doesn't show a description, check your `koreader.log` file on the device. Ensure the `.meta` filename matches the title extracted by the plugin exactly (including spaces).
