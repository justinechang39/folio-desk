# Contributing

Use the local build and test commands in README.md. Keep native file access in Rust, preserve document positions across layout changes, and never write to source PDFs. Use synthetic fixtures for tests; do not commit personal documents or session data.

Changes to session structure need explicit versioning and migration. Changes to file handling should include Rust validation tests. Changes to document movement should include model tests and a browser interaction test.

No GitHub Actions workflows are enabled. Run checks locally before submitting changes.
