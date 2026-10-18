# Contributing

Use the local build and test commands in README.md. Keep PDF validation and durable session storage in Rust; native PDF interaction belongs to PDFKit. Preserve positions across layout/tab changes and never save over source PDFs. Do not add a webview renderer or perform per-gesture workspace rebuilds.

Use synthetic fixtures and isolated test sessions. Never commit personal PDFs, session files, performance reports, or screenshots of private documents. Session changes need explicit compatibility handling and migration tests. File handling changes need Rust tests; document movement and viewer changes need native integration tests.

GitHub Actions is disabled. Build and run checks locally before submitting changes.
