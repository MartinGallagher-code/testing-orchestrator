# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""testing_orchestrator -- run one job on a whole fleet at once, and get the
results back.

The whole tool is `tx.py`: a single self-contained file, because it is
copied to every host and run there as the agent. This package exists so
`pip install` can put `tx` on your PATH.
"""

VERSION = "1.1.0"
