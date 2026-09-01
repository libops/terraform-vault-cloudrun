#!/usr/bin/env python3

import unittest

from vault_image_contract import require_dependency


class RequireDependencyTest(unittest.TestCase):
    def test_accepts_exact_binary_dependency(self) -> None:
        require_dependency(
            "/usr/local/bin/vault: go1.26.6\n"
            "\tdep\tgolang.org/x/crypto\tv0.55.0\th1:checksum\n",
            "golang.org/x/crypto",
            "v0.55.0",
        )

    def test_rejects_vulnerable_binary_dependency(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "v0.54.0"):
            require_dependency(
                "\tdep\tgolang.org/x/crypto\tv0.54.0\th1:checksum\n",
                "golang.org/x/crypto",
                "v0.55.0",
            )

    def test_rejects_missing_binary_dependency(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "None"):
            require_dependency("malformed build metadata\n", "golang.org/x/crypto", "v0.55.0")


if __name__ == "__main__":
    unittest.main()
