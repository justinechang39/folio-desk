# Folio Desk design

A reading desk for comparing question papers, solutions, and reference documents. Each tab is a workspace. A narrow document shelf lists everything in the workspace; the right side is reserved for the pages themselves.

Palette: ink #24313c, slate #64717f, desk #edf0f3, paper #ffffff, focus #176b86, selected #e1f1f7. System SF typography keeps controls familiar on macOS; document typography belongs to the PDF. Restrained 12–14px controls, 32px minimum hit targets, and a 40px workspace tab strip leave most of the window for paper. A single blue rule identifies the active pane.

    [ Workspace tabs                                       + ]
    [ Add PDFs     Layout                         Link pages ]
    [ Documents | title + page tools | title + page tools     ]
    [           |                   |                        ]
    [           |      PDF          |        PDF             ]
    [           |                   |                        ]

The visual emphasis is the arrangement of real sheets. No dashboard cards, promotional copy, or decorative gradients. Layout changes preserve documents in the shelf. Each document retains its page, zoom, fit, and rotation when moved. Drag to swap panes; move menus support keyboard users and transfers to other workspaces. Linked page turns are explicit and off by default. Session metadata stays local; original PDFs are never modified.

Review against brief: a fixed symmetric two-pane viewer would limit reuse, so layouts include one, two columns, two rows, three columns, and four panes. Extra documents remain available instead of disappearing when the layout shrinks. A vertical shelf adds navigation without crowding the page controls. Mobile styling is not the target; the native window has an 860px minimum width, with a collapsible shelf for smaller screens.
