# Pull Request Review Instructions

Project: headless Magento 2 / Adobe Commerce backend. No storefront theme (no Luma, no Hyva).
Clients use GraphQL and REST APIs; the admin panel is the only server-rendered UI.

Read target versions from `composer.json` (`magento/product-community-edition`) and the
`PHP_VERSION` repository variable. Do not assume older versions.

## PHP

- **Basic errors:** syntax errors, undefined variables/classes, unreachable code, logic errors.
- **Compatibility:** deprecated or removed PHP features; Magento deprecated APIs (`@deprecated`).
- **Coding standard:** Magento2 coding standard (PSR-12 based). Constructor property promotion and
  `declare(strict_types=1);` in new files.
- **Magento practice:** dependency injection only (no `ObjectManager::getInstance()` outside
  factories/tests); service contracts (`Api/` interfaces) over models; plugins over preferences;
  declarative schema (`db_schema.xml` + whitelist) and data/schema patches, no install scripts.
- **Performance:** N+1 queries, loading collections in loops, missing indexes in `db_schema.xml`,
  heavy work in observers/plugins on hot paths, missing caching.

## GraphQL

- Resolvers check authorization: customer context via `ContextInterface`
  (`getExtensionAttributes()->getIsCustomer()`), throw `GraphQlAuthorizationException` otherwise.
- No N+1 in resolvers: use batch resolvers (`BatchResolverInterface`,
  `BatchServiceContractResolverInterface`) or deferred loading for lists.
- Queries that return cacheable data declare `@cache(cacheIdentity: ...)`; mutations never cached.
- Validate and sanitize all `args`; throw `GraphQlInputException` with safe messages.
- No sensitive data (password hashes, tokens, internal ids of other customers) in types.
- Schema changes in `etc/schema.graphqls` are backward compatible or flagged as breaking.

## REST (webapi.xml)

- Every route has a correct ACL `resource`; `anonymous` only for intentionally public reads.
- `self` resource only for customer-owned data, with `%customer_id%` force parameter where needed.
- Mutating routes (`POST`, `PUT`, `DELETE`) never anonymous.

## Security

- **Dangerous functions:** `eval`, `base64_decode` on input, `system`, `shell_exec`, `exec`,
  `passthru`, `assert`, `unserialize` on input, `preg_replace` with `/e`.
- **Obfuscation:** encoded strings (base64, rot13, gzuncompress), dynamic function calls,
  variable variables, minified blobs.
- **Suspicious I/O:** unexpected file or network operations, hardcoded external endpoints.
- **Security bypass:** code that disables authentication, authorization, CSRF/form keys in admin,
  logging, or weakens input validation.
- **Secrets:** hardcoded credentials, keys, tokens; `app/etc/env.php` must never be committed.

## Admin JavaScript

- Flag `eval`, `Function` constructor, string `setTimeout`/`setInterval`, dynamic script loading,
  unexpected network calls or data sent to external domains.

## Workflows (`.github/`)

- Actions pinned by full commit SHA; least-privilege `permissions`; no `${{ }}` of secrets or
  untrusted input inside `run:` (use `env:`); no checkout of PR code in `pull_request_target`.

---

**If in doubt, request clarification.**
