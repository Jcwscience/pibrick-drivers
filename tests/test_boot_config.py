"""Regression checks for firmware-safe piBrick boot configuration."""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMBINED = (
    "dtoverlay=pibrick,battery_capacity=5000,"
    "battery_nominal_voltage_uv=3700000,"
    "battery_max_voltage_uv=4200000,charge_current_ma=2000\n"
)
SEPARATE = "\n".join(
    ["dtoverlay=pibrick"]
    + ["dtparam=" + parameter for parameter in COMBINED.strip().split(",")[1:]]
) + "\n"


def run_function(script, function, config):
    source = (ROOT / "scripts" / script).read_text()
    body = re.search(r"^" + function + r"\(\)\n\{.*?^\}", source, re.M | re.S)
    subprocess.run(
        ["bash", "-euc", "info() { :; }\ndie() { exit 1; }\n"
         + body.group() + '\n' + function + ' "$1"', "test", str(config)],
        check=True,
    )


class BootConfigTests(unittest.TestCase):
    def test_long_entry_is_split_without_losing_settings(self):
        self.assertGreater(len(COMBINED.strip()), 98)
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.txt"
            config.write_text("[all]\n" + COMBINED)
            run_function("install.sh", "install_config", config)
            self.assertEqual(config.read_text(), "[all]\n" + SEPARATE)
            self.assertTrue(all(len(line) <= 80 for line in config.read_text().splitlines()))
            run_function("install.sh", "install_config", config)
            self.assertEqual(config.read_text(), "[all]\n" + SEPARATE)

    def test_missing_entry_is_added_once(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.txt"
            config.write_text("[all]\ndtoverlay=pibrick-other\n")
            for _ in range(2):
                run_function("install.sh", "install_config", config)
            self.assertEqual(config.read_text().count("\ndtoverlay=pibrick\n"), 1)

    def test_uninstall_removes_owned_parameters_only(self):
        other = "dtoverlay=pibrick-other\ndtparam=battery_capacity=1234\n"
        for entry in [COMBINED, SEPARATE]:
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / "config.txt"
                config.write_text("[all]\n" + entry + other)
                run_function("uninstall.sh", "remove_config", config)
                self.assertEqual(config.read_text(), "[all]\n" + other)

    def test_documented_boot_entries_fit_firmware_limit(self):
        for name in ["README.md", "examples/config.txt"]:
            for line in (ROOT / name).read_text().splitlines():
                entry = line.lstrip("# \t")
                if entry.startswith(("dtoverlay=pibrick", "dtparam=battery_", "dtparam=charge_current_ma")):
                    self.assertLessEqual(len(entry), 80, (name, entry))


if __name__ == "__main__":
    unittest.main()
