# Git history cleanup plan: covid-dataset

**Status:** Prepared, not run. Needs your approval before anything below is run. Nothing has been pushed, force-pushed, or rewritten.

## Why a rewrite is needed

A Gitleaks scan with the repo's `.gitleaks.toml` found the following in 9 historical commits on `main`. No values are reproduced here.

| Type | Files (historical) | Classification |
| --- | --- | --- |
| ADF `encryptedCredential` (storage account key / SQL password material) | `linkedService/ls_ablob_covidreporting_sa.json`, `ls_adls_covidreporting_dl.json`, `ls_sql_covid_db.json` | Factory-bound encrypted credential |
| SQL user name in connection string | `linkedService/ls_sql_covid_db.json` | Sensitive identifier |
| SQL server host and database name | `linkedService/ls_sql_covid_db.json` | Environment identifier |
| Subscription ID, resource group, storage account names | trigger + all generated ARM templates (both `vishal-covid-reporting-adf/` and the older `covid-reporting-vishal-adf/` path) | Environment identifier |
| Factory `principalId` / `tenantId` | `factory/vishal-covid-reporting-adf.json` | Environment identifier |

No plaintext account key, password, SAS token, or credential-bearing connection string was found in any commit.

## Step 0: Rotate first (a history rewrite is not enough on its own)

Rewriting history does not invalidate a credential. Anyone who has already cloned the repo keeps the old objects. Before the repo goes public:

1. **Blob storage account** (the original `ls_ablob_*` account): regenerate **both** access keys, or confirm the account has been deleted.
2. **ADLS Gen2 account** (the original `ls_adls_*` account): regenerate **both** access keys, or confirm it has been deleted.
3. **Azure SQL**: reset the password of the SQL user referenced by the old connection string, or drop that login. Prefer enabling Microsoft Entra-only authentication, or confirm the server has been deleted.
4. Optional: consider disabling shared-key access on both storage accounts once the managed-identity setup works.

## Step 1: Commit the remediation on `main` first

Review and commit the current working-tree changes, then push them (needs your approval). The rewrite below then scrubs everything *before* that commit, and the new commit already contains only placeholders.

## Step 2: Rewrite in a fresh mirror clone, not in your working copy

```bash
pip install git-filter-repo            # or: brew install git-filter-repo
cd ~/tmp && git clone --mirror git@github.com:bubnicbf/covid-dataset.git covid-dataset-rewrite.git
cd covid-dataset-rewrite.git
```

Create `../replacements.txt` **outside** the repository. It uses patterns only, so no real values need to be typed:

```text
regex:"encryptedCredential"\s*:\s*"[^"]*"==>"encryptedCredential": "REMOVED"
regex:(?i)user id=[^;"]+==>user id=<removed>
regex:(?i)data source=[^;"]+==>data source=<sql-server-name>.database.windows.net
regex:(?i)initial catalog=[^;"]+==>initial catalog=<sql-database-name>
regex:/subscriptions/[0-9a-fA-F-]{36}==>/subscriptions/<subscription-id>
regex:resourceGroups/[^/"<]+==>resourceGroups/<resource-group>
regex:storageAccounts/[a-z0-9]{3,24}==>storageAccounts/<blob-storage-account>
regex:AccountName=[a-z0-9]{3,24}==>AccountName=<blob-storage-account>
regex:https://[a-z0-9]{3,24}\.dfs\.core\.windows\.net==>https://<adls-storage-account>.dfs.core.windows.net
regex:https://[a-z0-9]{3,24}\.blob\.core\.windows\.net==>https://<blob-storage-account>.blob.core.windows.net
regex:"(principalId|tenantId)"\s*:\s*"[0-9a-fA-F-]{36}"==>"\1": "00000000-0000-0000-0000-000000000000"
```

```bash
git filter-repo --replace-text ../replacements.txt --replace-message ../replacements.txt
```

## Step 3: Verify before pushing

```bash
gitleaks git . --config <path-to-working-copy>/.gitleaks.toml --redact   # expect: no leaks found
git log --all -p | grep -c encryptedCredential                            # only "REMOVED" values should remain
```

Also grep the rewritten history for the old storage account, SQL server, and resource group names. Type these only into your own terminal, not into files or chat.

## Step 4: Force-push (needs separate approval)

```bash
git remote add origin git@github.com:bubnicbf/covid-dataset.git
git push --force --mirror origin
```

Then:

- **Re-clone** your local working copy. Don't pull into the old clone, because merging would bring the old history back.
- Check that there are no forks and no open PRs referencing old commits. If the repo was ever public or shared, ask GitHub Support to purge cached views of the old commits.
- Enable GitHub **secret scanning** and **push protection**, then make the repo public.

## Simpler alternative: publish fresh history

For a portfolio repo, you can skip rewriting and publish a new repository whose first commit is the cleaned tree:

```bash
git checkout --orphan public-main && git commit -m "Initial public release"
```

Push it to a **new** public repo and keep the original private. This loses commit history but is the simplest way to guarantee nothing old leaks. Rotation in Step 0 is still required.
