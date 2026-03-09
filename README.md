# Model Repository (Git LFS + Selective Download)

This repository is for distributing large model files through GitHub.
Model files are stored under `models/` and tracked by Git LFS.

## Layout

- `models/`
- `models/manifest.json`
- `scripts/register_model.ps1`
- `scripts/download_model.ps1`

## One-Time Setup

Run once in repository root:

```powershell
git lfs install
```

All files in `models/` are tracked by LFS via `.gitattributes`.

## Create GitHub Repository (No `gh` Required)

Use a GitHub personal access token (PAT) with repo permissions:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\create_github_repo.ps1 -RepoName YOUR_REPO -Visibility public -Token YOUR_GITHUB_TOKEN
```

Optional:

- `-Owner your-org-or-username`
- `-Description "your text"`
- `-Visibility private`

## Add a Model from Local Path

Register a model folder or single file from local disk:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\register_model.ps1 -Name MODEL_NAME -Source "D:\path\to\model"
```

Optional flags:

- `-Description "short note"`
- `-Overwrite` (replace existing model with same name)
- `-ChunkSizeMB 1900` (for >2GB files; defaults to 1900)

When a source file is larger than GitHub LFS single-object limit, the script automatically splits it into `.partNNNN` files and writes `_split_manifest.json`.

Then commit and push:

```powershell
git add .
git commit -m "Add model: MODEL_NAME"
git push
```

## Download Only One Model

Users can download just one model by command:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download_model.ps1 -Repo OWNER/REPO -Model MODEL_NAME -Output .\downloads
```

Private repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download_model.ps1 -Repo OWNER/REPO -Model MODEL_NAME -Token YOUR_GITHUB_TOKEN -Output .\downloads
```

What this script does:

1. `git clone --depth 1 --filter=blob:none --sparse`
2. sparse checkout to `models/MODEL_NAME`
3. `git lfs pull` only for that model path
4. auto-assemble chunked `.partNNNN` files back to original model file (if `_split_manifest.json` exists)

Optional flags:

- `-SkipAssemble` (download chunks only, do not merge)
- `-KeepChunks` (after merge, keep `.partNNNN` files)

## Notes

- GitHub has strict limits for file size and LFS bandwidth/storage.
- For very large models, split into parts if needed.
- `models/manifest.json` is auto-updated by `register_model.ps1`.
