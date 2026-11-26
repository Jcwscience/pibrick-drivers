import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "fan_control", Path(__file__).with_name("pibrick-fan-control.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def controller():
    return module.FanController(45, 60, 150, 255, 43, 5, 5, 30, 3, 10)


class ResponseTests(unittest.TestCase):
    def test_lower_edge_does_not_cycle(self):
        fan = controller()
        self.assertEqual(fan.update(45, 0), 150)
        for t in range(1, 120):
            self.assertGreaterEqual(fan.update(44.5 if t % 2 else 45.5, t), 150)

    def test_stop_requires_continuous_cooling(self):
        fan = controller()
        fan.update(45, 0)
        for t in range(1, 11):
            self.assertGreaterEqual(fan.update(39, t), 150)
        # A warm reading resets the stop timer even before the EMA catches up.
        self.assertGreaterEqual(fan.update(44, 11), 150)
        for t in range(12, 22):
            self.assertGreaterEqual(fan.update(39, t), 150)
        self.assertEqual(fan.update(39, 22), 0)

    def test_small_spike_is_smoothed(self):
        fan = controller()
        fan.update(44, 0)
        self.assertEqual(fan.update(46, 1), 0)
        self.assertLess(fan.filtered, 45)

    def test_major_rise_bypasses_smoothing(self):
        fan = controller()
        fan.update(40, 0)
        self.assertGreaterEqual(fan.update(55, 1), 150)
        self.assertEqual(fan.filtered, 55)

    def test_full_speed_is_immediate_and_downward_ramp_is_slow(self):
        fan = controller()
        fan.update(40, 0)
        self.assertEqual(fan.update(60, 1), 255)
        self.assertEqual(fan.update(45, 2), 252)
        self.assertEqual(fan.update(45, 3), 249)

    def test_upward_ramp_and_elapsed_time(self):
        fan = controller()
        self.assertEqual(fan.update(45, 0), 150)
        self.assertEqual(fan.update(59, 1), 180)
        self.assertEqual(fan.update(59, 3), 240)

    def test_invalid_sensor_fails_instead_of_commanding_off(self):
        for value in (float('nan'), float('inf'), -1, 200):
            with self.assertRaises(ValueError):
                controller().update(value, 0)


if __name__ == "__main__":
    unittest.main()
