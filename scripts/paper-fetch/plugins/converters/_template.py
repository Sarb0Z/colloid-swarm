"""Template for a converter plugin: copy this file, drop the leading underscore, fill it in.

A converter turns a saved file into text. The runner writes the text to
`fulltext.md` in the paper's folder, where the project's quote checker reads it.

Rules:
- `ACCEPTS` lists the file kinds this converter reads: "pdf", "xml" or "html".
  When two converters accept one kind, the first by name runs.
- Run an outside program through `run`, which returns its standard output. Do not
  import `subprocess`.
- `paper` is the manifest row: `paper.doi`, `paper.key` and `paper.row`, the whole
  row. Use it to check that the file is the paper the manifest names.
- Raise `NoText` when the file has no text layer (a scan). The paper ends
  `needs-text` and its file stays.
- Raise `WrongPaper("reason")` when the file is not that paper. The paper ends
  `failed` and the runner removes the copy it saved. An inbox file is never removed.
- Any other error leaves the paper `fetched` with the file in place; the next run
  converts it again without downloading it.
- Return the text unchanged. The runner adds nothing to it.
"""

from pathlib import Path

from paperfetch.model import NoText, Paper, Runner, WrongPaper

NAME = "example-pdf"
ACCEPTS = ("pdf",)


def convert(paper: Paper, path: Path, run: Runner) -> str:
    # text = run(["pdftotext", "-layout", str(path), "-"])
    # if not text.strip():
    #     raise NoText(f"{path.name} has no text layer")
    # if paper.doi.lower() not in text.lower():
    #     raise WrongPaper(f"the DOI {paper.doi} is not in {path.name}")
    # return text
    raise NotImplementedError
