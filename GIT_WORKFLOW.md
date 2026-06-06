# Git Workflow for AI Agents

> Claude / Kimi / any AI: follow this exactly. No extra thinking needed.

---

## Step 1 — Stage Changes

```bash
# Scripts and configs (most common changes):
git add scripts/ configs/ skel/ docs/

# Boot artifacts (after kernel/initramfs rebuild):
git add boot/

# Firmware (after re-extraction):
git add firmware/

# Kernel modules (after kernel rebuild):
git add kernel/

# Root-level files:
git add *.bat *.md .gitignore
```

**Shortcut — stage all tracked + new files:**
```bash
git add scripts/ configs/ skel/ boot/ firmware/ kernel/ *.bat *.md .gitignore
```

---

## Step 2 — Commit with Changelog

```
<type>: <short summary>

CHANGELOG:
- <what changed>
- <what changed>
```

**Types:**
| Type | When |
|------|------|
| `feat` | New script, feature, or boot entry |
| `fix` | Bug fix or broken behavior |
| `kernel` | Kernel or module update |
| `firmware` | Firmware blob update or re-extraction |
| `config` | Boot entries, skel configs, build params |
| `docs` | Markdown / CLAUDE.md / README only |

**Examples:**
```
kernel: update to 6.17.0-sp11, rebuild modules and initramfs
fix: prevent esp-guard from running before /boot is mounted
config: add sp11-efifb boot entry for no-msm fallback
firmware: re-extract ADSP and WiFi blobs from DriverStore
docs: add NVMe migration notes to README
```

**Commit command:**
```bash
git commit -m "type: summary here

CHANGELOG:
- First thing changed
- Second thing changed"
```

---

## Step 3 — Push

```bash
git push origin main
```

---

## Rules
1. Never stage: `build/*.img`, `cache/`, `src/linux-*/`, `scripts/_flash_log*.txt`
2. Changelog bullets = what someone flashing this USB would notice
3. Kernel + initramfs + DTBs = one commit (they go together)

---

## Visibility
Repo is **private** by default.  
To make it public: GitHub → repo → Settings → Danger Zone → Change visibility → Public  
This does NOT rewrite history or affect future pushes.
