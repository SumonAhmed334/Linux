# GitLab User Manual

**Internal GitLab Instance:** http://192.168.XX.XXX/

A beginner-friendly guide for anyone using our internal GitLab server for the first time.

---

## Table of Contents

1. [What is GitLab?](#1-what-is-gitlab)
2. [Accessing GitLab](#2-accessing-gitlab)
3. [Logging In & Changing Your Password](#3-logging-in--changing-your-password)
4. [Understanding the Dashboard](#4-understanding-the-dashboard)
5. [Projects](#5-projects)
6. [Groups](#6-groups)
7. [Setting Up SSH Keys (recommended)](#7-setting-up-ssh-keys-recommended)
8. [Cloning a Project to Your Computer](#8-cloning-a-project-to-your-computer)
9. [Basic Git Workflow](#9-basic-git-workflow)
10. [Branches](#10-branches)
11. [Merge Requests](#11-merge-requests)
12. [Issues & Work Items](#12-issues--work-items)
13. [To-Do List & Notifications](#13-to-do-list--notifications)
14. [Snippets](#14-snippets)
15. [Common Terms Explained](#15-common-terms-explained)
16. [Troubleshooting](#16-troubleshooting)
17. [Getting Help](#17-getting-help)

---

## 1. What is GitLab?

GitLab is a platform where teams store, manage, and collaborate on code and projects. Think of it as a central place where:

- Code is stored safely (in **repositories**)
- Changes are tracked over time (**version control**)
- Team members can review each other's work before it goes live (**merge requests**)
- Tasks and bugs are tracked (**issues**)
- Multiple people can work on the same project without overwriting each other's work

You don't need to be a developer to use GitLab — it's also useful for documentation, tracking tasks, and reviewing changes.

---

## 2. Accessing GitLab

Open your web browser and go to:

```
http://192.168.XX.XXX/
```

> **Note:** This is only reachable from within the office/internal network (LAN). It will not open from outside the network or over mobile data unless connected via VPN.

---

## 3. Logging In & Changing Your Password

1. Go to `http://192.168.XX.XXX/`
2. Enter the **username** and **password** provided to you by the administrator
3. Click **Sign in**

### Changing your password (do this on first login)

1. Click your profile picture (top-right corner)
2. Go to **Edit profile** → **Password**
3. Enter your current password, then your new password twice
4. Click **Save password**

**Password tips:**
- Use at least 8 characters, mixing letters, numbers, and symbols
- Never share your password with anyone
- If you forget your password, contact the system administrator to reset it

---

## 4. Understanding the Dashboard

After logging in, you'll land on the **Your work** dashboard. Here's what each menu item means:

| Menu Item | What it's for |
|---|---|
| **Home** | Your personal landing page/overview |
| **Projects** | List of all projects you're a member of |
| **Groups** | Collections of related projects (e.g., by team or department) |
| **Work items** | Tasks, issues, and epics assigned across projects |
| **Merge requests** | Code changes waiting for review/approval |
| **To-Do List** | Notifications and pending actions that need your attention |
| **Milestones** | Deadlines/goals grouping issues and merge requests |
| **Snippets** | Small, shareable pieces of code or text |
| **Activity** | Recent actions across your projects |

---

## 5. Projects

A **Project** in GitLab is a container for a repository (your code/files), issues, wiki, and settings — similar to a folder for an entire piece of work.

### Creating a new project

1. Click the **+** icon (top navigation bar) → **New project/repository**
2. Choose an option:
   - **Create blank project** – start from scratch
   - **Create from template** – use a pre-built structure
   - **Import project** – bring in a project from GitHub, another GitLab, or a file
3. Fill in:
   - **Project name**
   - **Visibility level**:
     - **Private** – only invited members can see it
     - **Internal** – anyone logged into this GitLab instance can see it
     - **Public** – anyone can see it, even without logging in
4. Click **Create project**

### Finding an existing project

- Go to **Projects** in the left sidebar → **View all projects**
- Or use the **search bar** at the top (press `/` to jump straight to it)

### Adding members to a project

1. Open the project
2. Go to **Manage → Members** (left sidebar)
3. Click **Invite members**
4. Enter the username/email and select a **Role** (see roles below)
5. Click **Invite**

**Common roles:**

| Role | Can do |
|---|---|
| Guest | View issues/discussions only |
| Reporter | View code, create issues |
| Developer | Push code, create branches, merge requests |
| Maintainer | Manage project settings, merge to protected branches |
| Owner | Full control, including deleting the project |

---

## 6. Groups

A **Group** organizes multiple related projects together (e.g., all projects for one department or team), and lets you manage permissions for everyone at once instead of project-by-project.

### Creating a group

1. Click **+** → **New group**
2. Enter a group name and visibility level
3. Click **Create group**

You can then create projects *inside* that group, and add members to the group so they automatically get access to every project within it.

---

## 7. Setting Up SSH Keys (recommended)

SSH keys let you connect to GitLab from your computer without typing your password every time you push/pull code.

### Step 1: Generate an SSH key (on your computer)

**Windows (PowerShell) / Mac / Linux terminal:**

```
ssh-keygen -t ed25519 -C "your.email@example.com"
```

Press **Enter** through the prompts (default location is fine). Set a passphrase if you want extra security, or leave blank.

### Step 2: Copy your public key

```
cat ~/.ssh/id_ed25519.pub
```

Copy the entire output (starts with `ssh-ed25519 ...`).

### Step 3: Add it to GitLab

1. Click your profile picture → **Edit profile**
2. Go to **SSH Keys** (left sidebar)
3. Paste your key into the **Key** box
4. Give it a **Title** (e.g., "My Laptop")
5. Click **Add key**

---

## 8. Cloning a Project to Your Computer

"Cloning" means downloading a full copy of a project's repository, including its history, to your computer.

1. Open the project in GitLab
2. Click the blue **Code** button
3. Copy the **SSH** or **HTTP** URL (SSH recommended if you set up keys)
4. On your computer, open a terminal and run:

```
git clone git@192.168.43.172:group-name/project-name.git
```

(or use the HTTP URL if you haven't set up SSH keys — you'll be asked for your username/password)

---

## 9. Basic Git Workflow

Once you've cloned a project, here's the everyday workflow:

```
# See what has changed
git status

# Pull the latest changes from GitLab before you start working
git pull

# After editing files, stage your changes
git add .

# Commit your changes with a message describing what you did
git commit -m "Describe your change here"

# Push your changes up to GitLab
git push
```

**Golden rule:** Always `git pull` before you start working and before you push, to avoid conflicts with others' changes.

---

## 10. Branches

A **branch** is a separate line of work, so you can make changes without affecting the main/stable code (usually called `main` or `master`) until it's reviewed and approved.

### Creating a new branch

```
git checkout -b feature/my-new-feature
```

### Switching between branches

```
git checkout main
git checkout feature/my-new-feature
```

### Pushing a new branch to GitLab

```
git push -u origin feature/my-new-feature
```

---

## 11. Merge Requests

A **Merge Request (MR)** — called a "Pull Request" on some other platforms — is how you propose merging your branch's changes into the main branch, so teammates can review before it's accepted.

### Creating a merge request

1. Push your branch (see above)
2. GitLab will usually show a banner: **"Create merge request"** — click it
   - Or go to **Merge requests** (left sidebar) → **New merge request**
3. Choose the **source branch** (your work) and **target branch** (usually `main`)
4. Add a **title** and **description** explaining your changes
5. Optionally assign a **Reviewer**
6. Click **Create merge request**

### Reviewing a merge request

1. Open the MR
2. Check the **Changes** tab to see exactly what was modified
3. Leave comments by clicking the `+` next to any line
4. If it looks good, click **Approve**
5. Once approved, click **Merge**

---

## 12. Issues & Work Items

**Issues** are used to track tasks, bugs, feature requests, or any to-do item related to a project.

### Creating an issue

1. Open a project → **Plan → Issues** (left sidebar)
2. Click **New issue**
3. Add a **title**, **description**, and optionally:
   - **Assignee** – who's responsible
   - **Labels** – tags like `bug`, `urgent`, `documentation`
   - **Milestone** – deadline/goal it belongs to
   - **Due date**
4. Click **Create issue**

### Closing an issue

Once the task is done, open the issue and click **Close issue** — or reference it in a commit message like `Closes #12` and it will close automatically when merged.

---

## 13. To-Do List & Notifications

GitLab automatically adds items to your **To-Do List** when:
- You're assigned an issue or merge request
- Someone mentions you (`@yourusername`) in a comment
- A merge request needs your review

Check it via **To-Do List** in the left sidebar. Mark items as done once handled by clicking the checkmark.

You'll also receive **email notifications** for these events (sent to the email address on your GitLab account) as long as the mail server is configured on this instance.

---

## 14. Snippets

**Snippets** are small, standalone pieces of code or text you want to save or share quickly, without creating a full project.

1. Click **+** → **New snippet**
2. Add a title, description, and content
3. Choose visibility (Private/Internal/Public)
4. Click **Create snippet**

---

## 15. Common Terms Explained

| Term | Meaning |
|---|---|
| **Repository (repo)** | The storage location for a project's files and history |
| **Commit** | A saved snapshot of changes, with a message describing it |
| **Push** | Sending your local commits up to GitLab |
| **Pull** | Downloading the latest changes from GitLab to your computer |
| **Clone** | Making a full local copy of a repository |
| **Branch** | A separate line of development |
| **Merge** | Combining changes from one branch into another |
| **Fork** | Your own independent copy of someone else's project |
| **Conflict** | When two people change the same part of a file differently, and Git can't decide which to keep automatically |
| **CI/CD Pipeline** | Automated steps (build/test/deploy) that run when code is pushed |

---

## 16. Troubleshooting

**"Permission denied (publickey)" when using Git**
→ Your SSH key isn't set up or wasn't added to GitLab correctly. Revisit [Section 7](#7-setting-up-ssh-keys-recommended).

**Can't reach http://192.168.XXX.XXX/**
→ Confirm you're connected to the internal network/office Wi-Fi. This address is not accessible from outside the LAN.

**"Merge conflict" error when pulling/pushing**
→ Someone else changed the same lines you did. Run `git pull`, resolve the conflicting lines shown in the file (look for `<<<<<<<`, `=======`, `>>>>>>>` markers), then `git add .` and `git commit` to finish.

**Forgot your password**
→ Contact the system administrator to reset it — self-service password reset via email may not be enabled on this internal instance.

**Uploaded file/push fails due to file size**
→ Very large files may be rejected by default settings. Contact the administrator if you need to push large files.

---

## 17. Getting Help

- **In-app help:** Click the **Help (?)** icon at the bottom-left of any GitLab page
- **GitLab official docs:** https://docs.gitlab.com
- **Internal support:** Contact your system administrator for account access, password resets, or project permission issues

---

*Document maintained by the internal Infrastructure/IT team. Last updated for the GitLab instance running at http://192.168.43.172/.*
