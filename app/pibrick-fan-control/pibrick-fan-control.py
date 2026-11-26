#!/usr/bin/python3
"""Control the piBrick PWM fan from CPU temperature."""

import logging
import math
import os
from pathlib import Path
import signal
import time


def fan_pwm(temperature, start, full, minimum, maximum):
    if temperature < start:
        return 0
    if temperature >= full:
        return maximum
    return round(minimum + (maximum - minimum) * (temperature - start) / (full - start))


class FanController:
    def __init__(self, start, full, minimum, maximum, stop, smoothing,
                 jump, ramp_up, ramp_down, stop_delay):
        values = (start, full, minimum, maximum, stop, smoothing, jump,
                  ramp_up, ramp_down, stop_delay)
        if not (all(math.isfinite(v) for v in values)
                and 0 < stop < start < full and 0 < minimum <= maximum <= 255
                and min(smoothing, jump, ramp_up, ramp_down) > 0
                and stop_delay >= 0):
            raise ValueError("Invalid fan curve or response configuration")
        self.start, self.full = start, full
        self.minimum, self.maximum = minimum, maximum
        self.stop, self.smoothing, self.jump = stop, smoothing, jump
        self.ramp_up, self.ramp_down = ramp_up, ramp_down
        self.stop_delay = stop_delay
        self.filtered = None
        self.active = False
        self.below_since = None
        self.output = 0.0
        self.last_time = None

    def update(self, temperature, now):
        if not math.isfinite(temperature) or not 0 <= temperature <= 150:
            raise ValueError("Invalid CPU temperature")
        dt = 1.0 if self.last_time is None else max(0.0, now - self.last_time)
        self.last_time = now
        if self.filtered is None or abs(temperature - self.filtered) >= self.jump:
            self.filtered = temperature
        else:
            self.filtered += (1 - math.exp(-dt / self.smoothing)) * (temperature - self.filtered)

        if temperature >= self.full:
            self.active = True
            self.below_since = None
            self.output = float(self.maximum)
            return self.maximum
        if not self.active and self.filtered >= self.start:
            self.active = True
        if self.active and max(temperature, self.filtered) < self.stop:
            if self.below_since is None:
                self.below_since = now
            if now - self.below_since >= self.stop_delay:
                self.active = False
        else:
            self.below_since = None

        if not self.active:
            self.output = 0.0
            return 0
        target = max(self.minimum, fan_pwm(self.filtered, self.start, self.full,
                                           self.minimum, self.maximum))
        # Start at the known working minimum, never linger in the stall range.
        self.output = max(float(self.minimum), self.output)
        change = target - self.output
        self.output += max(-self.ramp_down * dt, min(self.ramp_up * dt, change))
        return round(self.output)


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    start = float(os.environ.get("FAN_START_TEMP", "45"))
    full = float(os.environ.get("FAN_FULL_TEMP", "50"))
    minimum = int(os.environ.get("FAN_MIN_PWM", "150"))
    maximum = int(os.environ.get("FAN_MAX_PWM", "255"))
    controller = FanController(
        start, full, minimum, maximum,
        float(os.environ.get("FAN_STOP_TEMP", "43")),
        float(os.environ.get("FAN_SMOOTH_SECONDS", "5")),
        float(os.environ.get("FAN_TEMP_JUMP", "5")),
        float(os.environ.get("FAN_RAMP_UP", "30")),
        float(os.environ.get("FAN_RAMP_DOWN", "3")),
        float(os.environ.get("FAN_STOP_DELAY", "10")))

    hwmon = next(p for p in Path("/sys/class/hwmon").glob("hwmon*")
                 if (p / "name").read_text().strip() == "pwmfan")
    thermal = next(p for p in Path("/sys/class/thermal").glob("thermal_zone*")
                   if (p / "type").read_text().strip() == "cpu-thermal")
    pwm = hwmon / "pwm1"
    running = True

    def stop(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    logging.info("Fan curve: start %g C, stop below %g C for %g s; PWM %d-%d, full at %g C; "
                 "smoothing %g s, jump %g C, ramp up/down %g/%g PWM per second",
                 start, controller.stop, controller.stop_delay, minimum, maximum, full,
                 controller.smoothing, controller.jump, controller.ramp_up, controller.ramp_down)
    previous = None
    try:
        (hwmon / "pwm1_enable").write_text("1\n")
        while running:
            temperature = int((thermal / "temp").read_text()) / 1000
            value = controller.update(temperature, time.monotonic())
            # Reassert the curve if the kernel thermal governor changes PWM.
            pwm.write_text(f"{value}\n")
            if value != previous:
                logging.info("CPU %.2f C (smoothed %.2f C): PWM %d",
                             temperature, controller.filtered, value)
                previous = value
            time.sleep(1)
    finally:
        # Leave cooling available if the service stops or a sensor read fails.
        pwm.write_text("255\n")


if __name__ == "__main__":
    main()
