# Release language policy

The default public project language is **English**. Keep the main README, general documentation and GitHub metadata in English. German guides remain available as clearly labelled additional documents.

Starting with the next release after 1.0, **every release announcement must contain both English and German**, in that order. Use [the bilingual template](../.github/RELEASE_TEMPLATE.md). Both sections must describe the same changes, downloads, requirements, validation, limitations and signing status. Do not publish untranslated placeholders.

The app continues to support its six existing interface languages and system-language selection. This publishing policy does not remove translations.

## Release checklist

1. Update version strings and changelog. Keep English and German installation guides aligned.
2. Run `python3 scripts/test.py` and `python3 scripts/build.py`.
3. Confirm the app archive includes both English and German operating instructions.
4. Run `python3 scripts/package.py`; verify the source and complete bundles and SHA-256 checksums.
5. Prepare release notes from the bilingual template and check both language sections.
6. Publish the requested version/tag with the app, source, complete bundle and checksums.
7. Verify the public release, tag target and downloaded files against the local artifacts.

Published version tags and binaries are not rewritten merely to translate a GitHub release description. Documentation can continue on the default branch; the next release packages those changes.
