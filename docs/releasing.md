# Releasing RepoPrompt CE

RepoPrompt CE has two release lanes:

- Contributors can build an ad-hoc release-candidate archive with no secrets.
- Maintainers can publish a Developer ID signed, notarized, stapled GitHub
  Release with a signed Sparkle appcast through the protected `release`
  environment.

## Contributor release candidate

Run:

```bash
make dev-release-preflight
make dev-release-artifact
```

The artifact is written under `dist/`. It exercises release-mode compilation,
app bundling, legal-file packaging, and archive creation. It is intentionally
ad-hoc signed and is not suitable for distribution.

The direct fallback commands are `make release-preflight` and
`make release-artifact`. The GitHub **Release Candidate** workflow runs the same
path on `main` and on manual dispatch, then uploads the archive as a workflow
artifact.

## Maintainer setup

Create a protected GitHub Actions environment named `release`. Require
maintainer approval before jobs can access its secrets. If the repository's
current GitHub plan or visibility does not expose required reviewers for
environments, resolve that limitation or enforce an equivalent maintainer
approval gate before treating the publishing workflow as protected.

Add these environment secrets:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as PKCS#12. |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used for the PKCS#12 export. |
| `CI_KEYCHAIN_PASSWORD` | Random password for the ephemeral CI keychain. |
| `REPOPROMPT_CE_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `com.pvncher.repoprompt.ce`. |
| `NOTARYTOOL_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key accepted by `notarytool`. |
| `NOTARYTOOL_KEY_ID` | App Store Connect API key ID. |
| `NOTARYTOOL_ISSUER_ID` | App Store Connect API issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key for the CE update channel. |

The optional `SIGN_IDENTITY` environment variable defaults to:

```text
Developer ID Application: Eric Provencher (648A27MST5)
```

The provisioning profile must authorize:

```text
648A27MST5.com.pvncher.repoprompt.ce
```

The release script validates that identifier before signing.

App Store Connect organization API access must be enabled before generating the
notarization `.p8` key. If **Users and Access → Integrations → App Store Connect
API** shows **Request Access**, complete that approval step before creating the
three `NOTARYTOOL_*` secrets. A team key with the least-privilege `Developer`
role is sufficient for the documented `notarytool` flow. After storing the
secrets, remove the one-time `.p8` download from the local machine.

## Publish

1. Update `version.env` and commit the release state.
2. Create and push a tag pointing at that commit.
3. Run the **Publish Release** workflow with the existing tag.
4. Review the draft GitHub Release before publishing it.

The workflow imports the Developer ID certificate into an ephemeral keychain,
embeds the CE provisioning profile, signs with hardened runtime entitlements,
notarizes and staples the app and DMG, creates a signed Sparkle appcast, and
uploads ZIP, DMG, appcast, and checksum assets to GitHub Releases.

The appcast URL committed in the app is:

```text
https://github.com/repoprompt/repoprompt-ce/releases/latest/download/appcast.xml
```
