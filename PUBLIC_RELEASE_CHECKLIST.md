# Public Release Checklist

Use this checklist before setting the repository visibility to public.

## 1) Confirm working tree and ignored artifacts

```bash
git status --short
git check-ignore -v .build/manifest.db dist/mControl.dmg .DS_Store .env
```

Expected:
- source/docs/scripts are visible to Git
- build/artifact/secret files are ignored

## 2) Remove personal author metadata from history

Current history includes a local hostname-style author email.
If you have a single commit, rewrite it with a public-safe identity:

```bash
git config user.name "YOUR_PUBLIC_NAME"
git config user.email "your-public-email@example.com"
git commit --amend --reset-author --no-edit
```

If you have multiple commits, rewrite all commit authors:

```bash
git rebase -r --root --exec 'git commit --amend --reset-author --no-edit'
```

Then verify:

```bash
git log --format='%h %an <%ae>' --max-count=20
```

## 3) Scan repository content for secret patterns

```bash
rg -n --hidden --glob '!.git/**' --glob '!.build/**' --glob '!dist/**' \
  '(BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENAI_API_KEY|aws_secret_access_key|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-|sk-[A-Za-z0-9]{20,}|api[_-]?key\s*[:=]|password\s*[:=]|token\s*[:=])'
```

Expected:
- no matches, or only known safe placeholders

## 4) Scan for personal absolute paths

```bash
rg -n --hidden --glob '!.git/**' --glob '!.build/**' --glob '!dist/**' \
  '(/Users/|com~apple~CloudDocs|[A-Za-z0-9._-]+@[^[:space:]]+)'
```

Expected:
- no personal local paths
- emails only where intentionally public

## 5) Final publish check

```bash
git ls-tree -r --name-only HEAD
```

Review tracked files and confirm no:
- `.env*`
- key/cert/provision files
- build outputs (`.build/`, `dist/`, `.dmg`, `.app`)
