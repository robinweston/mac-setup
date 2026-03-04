# Git aliases and using `git@github.com` for Mandai

## Current setup

### SSH host aliases (`~/.ssh/config`)

| Host alias    | HostName  | User | IdentityFile           | Purpose   |
|---------------|-----------|------|------------------------|-----------|
| `personal_git`| github.com| git  | ~/.ssh/personal_git.pub | Personal  |
| `work_git`    | github.com| git  | ~/.ssh/work_git.pub    | Work      |
| `mandai_git`  | github.com| git  | ~/.ssh/mandai_git.pub  | Mandai    |

Each alias maps to `github.com` but uses a different SSH key via `IdentityFile` and `IdentitiesOnly yes`.

### Git config

- **Default** (e.g. outside `~/git/personal/`): `user.email = robin.weston@mandai.com`, signing with the Mandai key.
- **Personal** (`~/git/personal/`): `~/.gitconfig-personal` is included and overrides `user.email` and `signingkey` for personal identity.

Repo identity is determined by:

1. **Which SSH host you use in the remote URL** (e.g. `git@personal_git:...` vs `git@mandai_git:...`).
2. **Which directory the repo is in** (only affects `user.email` and `signingkey` via `includeIf`, not which key is used for SSH).

---

## Can you use `git@github.com` for Mandai and keep `personal_git`?

Yes. The two are independent.

- **`personal_git`**  
  As long as personal repos use remotes like `git@personal_git:user/repo.git`, SSH will use the `personal_git` host block and the personal key. That does not depend on whether Mandai uses `mandai_git` or `git@github.com`.

- **Mandai with `git@github.com`**  
  To use plain `git@github.com` for Mandai repos you need SSH to use the Mandai key for `github.com`. That is done by having a `Host github.com` block that uses the Mandai key (see below). Then:
  - `git@github.com:org/repo.git` → Mandai key.
  - `git@personal_git:user/repo.git` → Personal key.

So you can “change mandai_git back to git@github.com” (use `git@github.com` for Mandai) and **personal_git will still work as planned** as long as personal remotes stay on `personal_git`.

---

## How to switch Mandai to `git@github.com`

1. **In `~/.ssh/config`**
   - Remove the `mandai_git` block (or keep it only if you still want that URL variant).
   - Ensure there is a block that applies when the host is `github.com` and you want the Mandai key:

   ```sshconfig
   Host github.com
     HostName github.com
     User git
     IdentityFile ~/.ssh/mandai_git
     IdentitiesOnly yes
   ```

   Then any clone/push/pull to `git@github.com:...` will use the Mandai key.

2. **In Mandai repos**
   - Update remotes from `git@mandai_git:org/repo.git` to `git@github.com:org/repo.git`:
     - `git remote set-url origin git@github.com:org/repo.git` (per repo), or
     - Re-clone using `git@github.com:org/repo.git`.

3. **Personal repos**
   - Leave remotes as `git@personal_git:user/repo.git`. No change needed; they will continue to use the personal key.

---

## Summary

| Question | Answer |
|----------|--------|
| Can you use `git@github.com` for Mandai? | Yes, by configuring a `Host github.com` block with the Mandai key. |
| Will `personal_git` still work as planned? | Yes, as long as personal remotes use `git@personal_git:...`. |
| Do you have to change personal repos? | No. |
| Do you have to change Mandai repos? | Yes: remote URLs from `git@mandai_git:...` to `git@github.com:...`. |

---

## Optional: fix IdentityFile paths

In SSH, `IdentityFile` must point to the **private** key, not the public one. Your config uses paths ending in `.pub` (e.g. `~/.ssh/personal_git.pub`). If your real private keys are named without `.pub` (e.g. `~/.ssh/personal_git`), update the config to use those paths; otherwise authentication may fail. If your private keys are actually named `*.pub`, you can leave as-is, but the usual convention is private = no extension or different name, public = `.pub`.
