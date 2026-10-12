# Headless Magento 2 CI/CD pipeline

SOC 2 friendly GitHub Actions pipeline for **headless** Magento 2 / Adobe Commerce projects:
PR checks, composer automation, release-please pre-release/release, build once, promote the same
artifact from staging to production, signed event-based deployment and post-deploy API checks.

Successor of [magenx/Magento-2-deployment-pipeline](https://github.com/magenx/Magento-2-deployment-pipeline),
stripped of storefront tooling (Luma, Hyva, PageSpeed) and hardened.

Magento code is project specific: copy `.github/` (plus `.editorconfig`, `.gitignore`) into a Magento
project repository and configure the variables and secrets below.

## Release flow

```
feature PR ──► CI (lint, phpcs, composer validate/audit, di:compile, tests) ──► squash merge to main
                                                                                    │
                        release.yml (release-please, prerelease config) ◄───────────┘
                                   │ opens pre-release PR; merge it
                                   ▼
          pre-release tag vX.Y.Z-alpha.N ──► build.yml
                                              ├─ composer install --no-dev, di:compile, classmap
                                              ├─ static deploy: adminhtml + Magento/blank (email CSS)
                                              ├─ eComscan, tar.gz + sha256, build provenance attestation
                                              ├─ assets attached to the pre-release
                                              └─ deploy.yml (staging) ──► S3 + signed webhook
          release.yml opens release PR (status comments: build, deploy, smoke)
                                   │ test staging; merge release PR
                                   ▼
          release tag vX.Y.Z ──► promote.yml
                                   ├─ download pre-release asset, verify sha256 + attestation
                                   ├─ attach the same bytes to the release (no rebuild)
                                   └─ deploy.yml (production, environment approval) ──► S3 + webhook
          deploy server callback ──► post_deploy.yml: GraphQL/REST smoke test, ZAP API scan (staging)
```

## Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | PR to main | composer validate + audit, `php -l`, Magento2 phpcs on changed `app/code`, `setup:di:compile`, PHPStan (if `phpstan.neon(.dist)`), unit tests in `app/code` |
| `composer_require.yml` | PR touching composer files | sync `composer.lock` for added/changed/removed packages, full update on Magento version change, enable new modules in `config.php`, push back, sticky report comment |
| `pr_title_validate.yml` | PR | Conventional Commit title, uppercase subject |
| `labeler.yml` | PR | path labels (graphql, webapi, db schema, composer, ...) |
| `copilot_pr_review.yml` | PR | request Copilot review (opt-in) |
| `release.yml` | push to main | release-please pre-release PR/tag, then release PR |
| `build.yml` | pre-release published | build once, attest, attach artifact, deploy staging |
| `promote.yml` | release published / manual | reuse verified pre-release artifact, deploy production |
| `deploy.yml` | reusable / manual redeploy | verify artifact, upload to S3, signed webhook, status PR comment or issue |
| `post_deploy.yml` | `repository_dispatch: deployment_completed` / manual | GraphQL + REST smoke test, ZAP GraphQL API scan |
| `composer_outdated.yml` | weekly | issue with outdated direct packages |
| `upgrade.yml` | manual | upgrade `magento/product-community-edition`, open PR |

Composite actions in `.github/actions/`: `setup-php-composer`, `magento-build`, `composer-diff`,
`composer-lock-diff`, `security-scan`, `release-pr-comment`.

## Setup

### GitHub App (recommended over PAT)

Releases and pushes made with `GITHUB_TOKEN` do not trigger other workflows, so release-please,
composer push-back and upgrade PRs need another identity. Create a GitHub App installed on the
repository with **Contents**, **Issues**, **Pull requests**: read and write.

- variable `CI_APP_CLIENT_ID`, secret `CI_APP_PRIVATE_KEY`

Fallback without an App: fine-grained PAT (Contents, Issues, Pull requests: read and write, this
repository only) in secret `RELEASE_GITHUB_TOKEN` (used by `release.yml` only).

### Variables

| Variable | Default | Used by |
|---|---|---|
| `PHP_VERSION` | `8.3` | all PHP jobs |
| `PHP_EXTENSIONS` | Magento set | build |
| `PRERELEASE_TYPE` | `alpha` | must match `prerelease-type` in `.github/release/prerelease-config.json` |
| `STATIC_DEPLOY_ARGS` | `-f -n --no-ansi --area adminhtml --area frontend --theme Magento/backend --theme Magento/blank` | build |
| `STATIC_DEPLOY_LOCALES` | `en_US` | build |
| `ECOMSCAN_SHA256` | empty | optional eComscan binary checksum |
| `AWS_ROLE_ARN` | empty | AWS OIDC role; when empty, access keys are used (S3-compatible storage) |
| `AWS_REGION`, `S3_BUCKET`, `S3_ENDPOINT` | | deploy (`S3_ENDPOINT` empty for AWS) |
| `DEPLOY_ISSUE_ASSIGNEE` | empty | production deployment issue assignee |
| `GRAPHQL_URL_STAGING`, `GRAPHQL_URL_PRODUCTION` | | post-deploy checks, e.g. `https://api.example.com/graphql` |
| `GRAPHQL_SMOKE_QUERY` | `{ storeConfig { store_code base_currency_code } }` | post-deploy |
| `STORE_CODE` | `default` | post-deploy `Store` header |
| `REST_SMOKE_PATH` | empty | optional, e.g. `/rest/V1/directory/currency` |
| `ZAP_SCAN_ENABLED` | empty | `true` enables ZAP API scan on staging |
| `COPILOT_REVIEW_ENABLED` | empty | `true` enables Copilot review request |

### Secrets

| Secret | Used by |
|---|---|
| `COMPOSER_AUTH` | `{"http-basic":{"repo.magento.com":{"username":"<public>","password":"<private>"}}}` |
| `CI_APP_PRIVATE_KEY` or `RELEASE_GITHUB_TOKEN` | see GitHub App |
| `ECOMSCAN_KEY` | build security scan (skipped when empty) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | only without `AWS_ROLE_ARN`; scope to `releases/*` of one bucket |
| `DEPLOY_WEBHOOK_URL`, `SIGNATURE_HMAC_KEY` | deploy webhook |
| `DEPLOY_WEBHOOK_SECRET` | optional legacy header, HMAC signature is the real check |
| `COPILOT_TOKEN` | Copilot review request |

Store deploy secrets as **environment secrets** on `staging` / `production` where possible.

### Environments

Create `staging` and `production`. On `production` add required reviewers and restrict to tags
`v*`; this gives an explicit, audited approval before production deploy.

### Deploy webhook contract

`POST DEPLOY_WEBHOOK_URL`, body (compact JSON, signed bytes):

```json
{"environment":"staging","tag_name":"v1.2.0-alpha.1","artifact_name":"release_v1.2.0_abc1234.tar.gz","artifact_digest":"sha256:<hex>","timestamp":"1760000000"}
```

Headers: `X-Signature: sha256=<HMAC-SHA256(body, SIGNATURE_HMAC_KEY)>`, `X-Timestamp`.
The server must verify the signature, reject old timestamps, download
`s3://$S3_BUCKET/releases/<artifact_name>`, check the sha256, deploy, then call back:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPO/dispatches \
  -d '{"event_type":"deployment_completed","client_payload":{"environment":"staging","tag_name":"v1.2.0-alpha.1"}}'
```

The callback token needs only Contents: write on this repository (fine-grained PAT or App).

### Repository settings (SOC 2)

- Squash merge only, default commit message "pull request title"; disable merge commits and rebase.
- Branch protection / ruleset on `main`: require PR, dismiss stale approvals, require status checks
  (`CI`, `PR title validation`), branches up to date, conversation resolution, linear history.
  Allow the GitHub App to bypass so release-please can commit.
- Enable private vulnerability reporting and Dependabot alerts.
- Add `.github/CODEOWNERS` for `.github/` and `app/etc/`.

## Headless notes

- No storefront theme build. `Magento/blank` static files are still deployed because
  transactional email CSS inlining reads them; remove it from `STATIC_DEPLOY_ARGS` only if Magento
  does not send emails.
- Keep `magento/theme-frontend-luma` and sample data out of the project (composer `replace`).
- Do not `replace` the `*-graph-ql` modules the frontend uses.
- PageSpeed checks belong to the frontend (PWA) repository; this pipeline tests the API.

## Changes from Magento-2-deployment-pipeline

Fixed:
- build checked out `main` instead of the release tag and had no `setup-php` step.
- production deploy downloaded from the wrong run id and sent empty artifact url/digest
  (`artifact-url` vs `artifact_url` outputs); now build once, promote verified bytes.
- AWS keys were written to `$GITHUB_ENV`; secrets and payload were interpolated into shell scripts;
  webhook `curl` ignored HTTP errors.
- composer-diff flagged a Magento update on every PR, so `composer update -W` always ran; push-back
  failed with "nothing to commit" on re-runs.
- upgrade PR title `feat!(upgrade):` was invalid and PRs opened by `GITHUB_TOKEN` never ran checks.
- PR title types missed `refactor`, `perf`, `test`, `build`, `revert`.
- bug report template had a duplicate `options` key (severity choices dropped).
- Dependabot did not update action pins inside composite actions.

Removed: Hyva/Luma build, PageSpeed action, HTML ZAP baseline, theme/less/css/phtml labels,
Magento base files and 1.4 MB changelog.

Added: PR CI, build provenance attestation, sha256 verification, OIDC, reusable deploy,
GraphQL/REST smoke test, ZAP GraphQL scan, least-privilege `permissions` everywhere.
