"""Fast metadata reads, with isolated and bounded DDC operations on demand."""
import argparse
import json
import subprocess
import sys

sys.dont_write_bytecode = True
from display_runtime import hypr, operation_lock

FIELDS = ('name', 'description', 'model', 'width', 'height', 'scale', 'transform',
     'x', 'y', 'focused', 'disabled', 'mirrorOf')


def read_state(name=''):
  monitors = json.loads(hypr('monitors', 'all', '-j'))
  monitors.sort(key=lambda m: (m.get('description', m['name']), m['name']))
  active = [m for m in monitors if not m.get('disabled')]
  selected = next((m for m in active if m['name'] == name), None)
  if selected is None:
    selected = next((m for m in active if m.get('focused')), active[0] if active else None)
  return dict(selected=selected['name'] if selected else '', displays=[
    dict({k: m.get(k) for k in FIELDS}, enabled=not m.get('disabled', False)) for m in monitors])


def brightness(name, identity, value=None):
  with operation_lock():
    monitors = json.loads(hypr('monitors', '-j'))
    if not any(m['name'] == name and m.get('description') == identity
         and not m.get('disabled') for m in monitors):
      raise ValueError('Display connection changed; select the display again')
    command = ['timeout', '--kill-after=1s', '8s', 'omarchy-brightness-display',
         '--no-osd', '--monitor', name]
    if value is not None:
      if type(value) is not int or not 1 <= value <= 100:
        raise ValueError('Brightness must be between 1 and 100')
      result = subprocess.run(command + [f'{value}%'], capture_output=True, text=True, timeout=10)
      if result.returncode:
        raise ValueError('Display did not accept the brightness change')
      # The helper echoes the requested value, not the actual backlight.
      # Read back to expose firmware clamping and failed/ignored writes.
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    try:
      percent = int(result.stdout.strip()) if result.returncode == 0 else None
    except ValueError:
      percent = None
    if percent is not None and not 0 <= percent <= 100:
      percent = None
    if value is not None and percent is None:
      raise ValueError('Brightness was sent, but the display could not confirm its value')
    return dict(name=name, description=identity, brightness=percent)


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('monitor', nargs='?', default='')
  parser.add_argument('--brightness')
  parser.add_argument('--identity', default='')
  parser.add_argument('--value', type=int)
  args = parser.parse_args()
  if args.value is not None and not args.brightness:
    parser.error('--value requires --brightness')
  result = brightness(args.brightness, args.identity, args.value) if args.brightness else read_state(args.monitor)
  print(json.dumps(result))


if __name__ == '__main__':
  try:
    main()
  except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
