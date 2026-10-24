<p align="center">
  <img src="docs/icon.png" width="128" alt="">
</p>

<h1 align="center">True Full Screen</h1>

<p align="center">
  Full screen on a notched MacBook, all the way to the top.<br><br>
  <a href="https://github.com/Mason363/True-Full-Screen/releases/latest/download/True-Full-Screen.zip"><b>Download</b></a>
</p>

![Before and after](docs/before-after.png)

Press the green button as usual. The menu bar and traffic lights still slide in on hover.

![Menu bar and traffic lights on hover](docs/hover.png)

<p align="center"><img src="docs/menu.png" width="200" alt="Menu"></p>

- **True Full Screen** turns it on or off.
- **Apps** lists open apps. Uncheck one to give it normal full screen.

## How

The window moves to a notch-free virtual display the size of your screen, goes full screen there, and that display is shown edge to edge. Nothing runs until a window goes full screen. Idea from [MacNotchKiller](https://github.com/DTW7607/MacNotchKiller).

## Notes

- Needs Accessibility and Screen Recording.
- macOS shows its screen-recording dot while an app is in true full screen.
- Its Space lives on the virtual display, so swipes and Mission Control won't reach it. Use ⌘Tab.
- Idle: 0% CPU, ~15 MB.
- Uses a private macOS API. Tested on macOS 27.

## Build

```sh
./build.sh
```
