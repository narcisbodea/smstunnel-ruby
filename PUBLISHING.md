# Publishing `smstunnel` to RubyGems.org

The gem is pushed by GitHub Actions with **RubyGems Trusted Publishing**: RubyGems.org trusts the workflow
`.github/workflows/release.yml` in the repository `narcisbodea/smstunnel-ruby`, in the GitHub environment `rubygems`.
There is no API key anywhere: not in GitHub secrets, not on a computer. Each run gets a short-lived token from
GitHub (OIDC) that RubyGems.org accepts only from that workflow, and only for this gem. The push also gets a signed
attestation (Sigstore) automatically.

RubyGems.org has no review: a pushed version is public within a minute or two (the workflow waits until it is).

The name `smstunnel` was free on RubyGems.org on 3 November 2026 (`https://rubygems.org/api/v1/gems/smstunnel.json`
answered 404). A pending trusted publisher does **not** reserve it: if someone else pushes a gem called `smstunnel`
first, the pending publisher stops working. So do steps 1 to 3 and the first release close together.

## 1. GitHub: the repository and the `rubygems` environment (once)

1. Create the public repository `narcisbodea/smstunnel-ruby` and push this folder to its `main` branch:

   ```bash
   git remote add origin https://github.com/narcisbodea/smstunnel-ruby.git
   git push -u origin main
   ```

2. Check that the **CI** workflow passes on `main` (the **Actions** tab).
3. In the repository, open **Settings → Environments → New environment**, name it `rubygems`, and save.
4. Recommended, in the same environment:
   - **Required reviewers**: add yourself. Every release then waits for your click on **Review deployments → Approve**.
   - **Deployment branches and tags → Selected branches and tags → Add rule**: tag pattern `v*`.

## 2. RubyGems.org: the account (once)

1. Create an account at <https://rubygems.org/sign_up> and confirm the email address.
2. Turn on multi-factor authentication: **Settings → Multi-factor authentication**, with an authenticator app or a
   security key (Windows Hello works), level **UI and API** (or **UI and gem signin**). Keep the recovery codes.
   The gem says `rubygems_mfa_required`, so its owners need MFA; pushes from the trusted workflow don't ask for a
   code.

## 3. RubyGems.org: the pending trusted publisher (once)

1. Open <https://rubygems.org/profile/oidc/pending_trusted_publishers> (**Settings → Trusted publishers**, pending).
2. Click **Create** and fill in exactly:

   | Field | Value |
   | --- | --- |
   | Gem name | `smstunnel` |
   | Repository owner | `narcisbodea` |
   | Repository name | `smstunnel-ruby` |
   | Workflow filename | `release.yml` |
   | Environment | `rubygems` |

   Leave **Workflow repository owner / name** empty.
3. Click **Create Pending trusted publisher**. After the first successful push it becomes the gem's normal trusted
   publisher and you become the gem's owner; nothing else to set up for later releases.

## 4. Release

1. Make sure the version in `lib/smstunnel/version.rb` and the top entry of `CHANGELOG.md` are right (1.0.0 now).
2. On GitHub: **Releases → Draft a new release → Choose a tag**, type `v1.0.0` (create it on `main`), title `1.0.0`,
   paste the changelog entry, and **Publish release**. The same from a terminal:

   ```bash
   gh release create v1.0.0 --target main --title "1.0.0" --notes-file <(sed -n '/^## \[1.0.0\]/,/^\[1.0.0\]/p' CHANGELOG.md)
   ```

3. The **Release** workflow runs: the client tests, RuboCop, a check that the tag matches the gem version, then
   The workflow exchanges its GitHub OIDC token for a short-lived key (naming the owner account, ID 255565, which RubyGems.org asks of a first push), builds the gem and pushes it (after your approval, if you set reviewers).
4. Check <https://rubygems.org/gems/smstunnel> and try it in a fresh directory:

   ```bash
   gem install smstunnel && ruby -e 'require "smstunnel"; puts SMSTunnel::VERSION'
   ```

## Later versions

1. Change `lib/smstunnel/version.rb` and add a `CHANGELOG.md` entry; commit and push to `main`; wait for CI.
2. Publish a GitHub release tagged `v<version>` (for example `v1.0.1`), as in step 4.

A version can never be pushed twice (RubyGems.org refuses "Repushing of gem versions is not allowed"), so a fix
always needs a new version number. A bad version can be yanked with `gem yank smstunnel -v <version>`, from your own
computer, signed in with MFA.

## If the push is refused

- `No trusted publisher configured` / `invalid`: the owner, repository, workflow file name or environment on
  RubyGems.org differs from the run. They must match exactly (`release.yml`, not the workflow's display name).
- `The release tag ... does not match the gem version`: the tag and `lib/smstunnel/version.rb` differ. Delete the
  release and its tag, fix one of them, and release again.
- The job never starts: approve the deployment, or check the environment's tag rule (`v*`).
- `Name is already taken`: someone pushed `smstunnel` first. Pick a new name (for example `smstunnel-ruby`), change
  `spec.name` in `smstunnel.gemspec`, and add a pending publisher for that name.

## What stays manual

Only the steps above: creating the accounts, turning on MFA, adding the pending publisher, creating the GitHub
repository and publishing a release. Nothing in this repository needs a secret.
