<p align="center">
  <img src="docs/icon.png" width="128" alt="">
</p>

<h1 align="center">True Full Screen</h1>

<p align="center">
  Full screen on a notched MacBook, all the way to the top.<br><br>
  <a href="https://github.com/Mason363/True-Full-Screen/releases/latest/download/True-Full-Screen.zip"><b>Download</b></a>
</p>

![Before and after](docs/before-after.png)

Press the green button as usual. Everything else works like normal full screen: the menu bar and traffic lights slide in on hover, and swipes, Mission Control and ⌘Tab behave as always.

![Menu bar and traffic lights on hover](docs/hover.png)

<p align="center"><img src="docs/menu.png" width="200" alt="Menu"></p>

## How

While on, your screen runs on a notch-free virtual display the same size as the built-in one, mirrored onto it pixel for pixel. Full screen is plain macOS full screen, so it reaches the top edge. Inspired by [MacNotchKiller](https://github.com/DTW7607/MacNotchKiller).

## Notes

- No permissions needed. 0% CPU, ~15 MB.
- While on, the menu bar doesn't skip the notch, and HDR is limited.
- The screen blinks once when it turns on or off.
- Uses a private macOS API. Tested on macOS 27.

## Build

```sh
./build.sh
```
