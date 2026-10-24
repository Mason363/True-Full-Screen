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

<p align="center"><img src="docs/menu.png" width="218" alt="Menu"></p>

- **True Full Screen** turns it on or off.
- **Apps** lists open apps. Uncheck one to keep its bar.

Apps pick up changes the next time they open.

## Notes

- 0% CPU, ~13 MB. It flips one macOS setting.
- Unchecking a sandboxed app (Safari, Preview…) needs Full Disk Access.
- Quitting keeps it on. Switch it off before deleting the app.
- Tested on macOS 27.

## Build

```sh
./build.sh
```
