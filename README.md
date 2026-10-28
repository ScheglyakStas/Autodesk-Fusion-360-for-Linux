# Autodesk Fusion on Linux

Fork of [designgears' installer](https://github.com/designgears/Autodesk-Fusion-360-for-Linux) with more fixes for Fusion on the patched Wine 11.17 build. It was tested on Ubuntu 24.04 (GNOME 46, X11, NVIDIA).

## Install

```
curl -L https://raw.githubusercontent.com/ScheglyakStas/Autodesk-Fusion-360-for-Linux/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --install-fix --default
```

The installer downloads the patched Wine and the `wine_sndbuf_fix.so` shim from [this fork's releases](https://github.com/ScheglyakStas/Autodesk-Fusion-360-for-Linux/releases). An existing `~/fusion-wine-build` from another release, such as designgears' one, is replaced, because it lacks these patches.

To build Wine yourself instead, use `--build wine-fix`. The patches are made for Wine 11.17.

The fixes below are for `--install-fix` only. `--proton=GE-Proton11-Fusion` still uses designgears' Proton build, which has none of them.

## Fixes in this fork

| Problem | Fix |
|---|---|
| Install fails with no error | Downloads are checked |
| Command pop-ups open too small, and "Insert McMaster-Carr Component" doesn't grow when resized | `wine-shape-follows-size.patch` |
| Clicks in other apps bring Fusion to the front, and the lock screen stops responding | `wine-xi2-focus-leak.patch` |
| Cloud uploads stuck at about 90 KB/s | `wine_sndbuf_fix.so` |
| Right-click Marking Menu doesn't appear | `wine_sndbuf_fix.so` |
| CPU time spent on thread yields | `wine_sndbuf_fix.so` |

### Install fails with no error

**Symptom:** The installer finishes, but Fusion is never installed. `FusionClientInstaller.exe` is only a few hundred bytes and its log is empty.

**Cause:** Autodesk's CDN can answer with an "Access Denied" HTML page, for example depending on VPN or region. `curl -L` saved that page as the `.exe`. The installer also reused any cached download younger than 7 days without checking it.

**Fix** (`download_file` in the installer):
- Downloads use `curl -fL --retry 3` into a `.part` file.
- A download is kept only if it is valid: `.exe` and `.dll` files must start with `MZ`, `.msi` files must be OLE compound files, and anything else must not be an HTML page.
- Invalid cached files are downloaded again.
- On failure the installer stops with a hint to check VPN and proxy settings, instead of carrying on with a broken file.
- The prebuilt Wine tarball is also checked against its `.sha256`.

### Command pop-ups too small, McMaster-Carr dialog not resizing

**Symptom:**
- Command dialogs (Extrude, Fillet, ...) open with their bottom cut off and can't be scrolled. Resizing them by hand, or switching to another app and back, fixes it.
- "Insert McMaster-Carr Component" relays out its content when resized, but the visible window keeps its old size, so the bottom part can't be reached.

**Cause:** Both are winex11 bugs in keeping the X11 window *shape* (`XShape` bounding region) in sync with the window size. Fusion's Qt dialogs set a Win32 window region (`SetWindowRgn`) on every resize, and winex11 turns that region into the X shape.
- With client-side graphics, the region is applied only through the window surface's shape mask. Once Fusion's D3D client surface covers the whole dialog, win32u drops the window surface. After that, region updates never reach the X window, and the last mask, sized for the old window, keeps clipping it. This is the McMaster-Carr case.
- When a dialog grows, Wine sends the new shape before it requests the new size. Mutter (GNOME) clips a client's shape to the size it knows at that moment and doesn't recompute it after the resize. The X window has the right size and shape, but GNOME keeps showing the old height. This is the command pop-up case: Fusion grows those dialogs in steps after creating them.

**Fix** (`files/setup/data/wine-shape-follows-size.patch`, in `dlls/winex11.drv/window.c`):
- A window without a window surface (`no_surface`) gets its region applied to the X window directly.
- After the window manager confirms a size change (`ConfigureNotify`), the window's current bounding shape is set again. This makes the window manager re-read the shape at the new size.

### Fusion steals focus, lock screen ignores clicks

**Symptom:**
- While Fusion runs, clicking another app brings Fusion back to the front.
- The lock screen can stop responding to clicks, so the only way out is a hard power-off.

**Cause:** Wine 11.17's winex11 turns on XInput2 raw mouse events on the root window while a Wine window has focus, but its `root_window_users` count leaks: a FocusOut for an already destroyed dialog is dropped, and a FocusOut during a grab never turns them off. Raw clicks made anywhere, including on the lock screen, then go to Fusion, which activates itself. In the GNOME journal this shows up as `Buggy client sent a _NET_ACTIVE_WINDOW message with a timestamp of 0`.

**Fix** (`files/setup/data/wine-xi2-focus-leak.patch`): a backport of upstream Wine commit [6aba44f1](https://gitlab.winehq.org/wine/wine/-/commit/6aba44f1), which is in Wine 11.18.

### `wine_sndbuf_fix.so`: uploads, Marking Menu, thread yields

The launcher preloads this shim (`LD_PRELOAD`) when `~/.autodesk_fusion/lib/wine_sndbuf_fix.so` exists. The source is `files/setup/data/wine_sndbuf_fix.c`. It does three things:

- **Slow cloud uploads (about 90 KB/s per connection).**
  - **Cause:** Wine's `ws2_32` answers `SIO_IDEAL_SEND_BACKLOG_QUERY` with a fixed 64 KB, and the Windows libcurl in Fusion's uploader passes that value to `SO_SNDBUF`. On Linux an explicit `SO_SNDBUF` locks the send buffer at that size, and Wine wakes a blocked writer only about once a second.
  - **Fix:** inside `wineserver`, `SO_SNDBUF` requests on TCP sockets are raised to 4 MB. The kernel still caps this at `net.core.wmem_max`. Measured with a test upload: about 128 KB/s before, 1.2–1.3 MB/s after.
- **Right-click Marking Menu doesn't appear.**
  - **Cause:** designgears' managed-window-classes patch hands Fusion's Qt tool windows to the window manager, and treats layered ones as non-focusable overlays. The Marking Menu is one of them, so GNOME stacks it below the main window.
  - **Fix:** for the window titled "Marking Menu", the shim changes the class name winex11 sees, so it no longer matches `WINE_X11_MANAGED_CLASSES`. It also maps the window override-redirect, so the menu shows as a normal popup.
  - To build the shim without this part, use `-DNO_MARKING_MENU_FIX`.
- **Cheaper `SwitchToThread`.**
  - **Cause:** Wine wraps every `sched_yield()` in two `getrusage(RUSAGE_THREAD)` calls, and Fusion's oneTBB workers yield thousands of times a second.
  - **Fix:** those calls from `ntdll.so` now fail fast, and Wine reports a plain success. This saves a few percent of CPU time but brings no visible speed-up.

Build it by hand with:

```
gcc -O2 -Wall -shared -fPIC -o wine_sndbuf_fix.so files/setup/data/wine_sndbuf_fix.c -ldl
```

## Notes

- If Fusion feels slow when sketching, these two things made a bigger difference than any Wine change:
  - Turning the design history off (direct modelling).
  - Setting the "Qt Rendering Hardware Interface API" preference to D3D11.
- Enabling the `ntsync` kernel module (`sudo modprobe ntsync`) works with this Wine build, but it made no measurable difference.
- Starting Fusion from a VS Code terminal crashes it at startup, because VS Code exports `ELECTRON_RUN_AS_NODE=1`. Start it from the app menu, or with `systemd-run --user ~/.autodesk_fusion/bin/autodesk_fusion_launcher.sh`.
- Running the installer again replaces `~/.autodesk_fusion/bin/autodesk_fusion_launcher.sh` and, if the prebuilt release tag changed, `~/fusion-wine-build`.
- `.github/workflows/prebuilt.yml` builds a release. Run it from the Actions tab with a new tag, then update `PREBUILT_TAG` in the installer.

---

## designgears' changes

[designgears' fork](https://github.com/designgears/Autodesk-Fusion-360-for-Linux) of cryinkfly's [Fusion 360 on Linux](https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux) installer, which this fork builds on.

[![Viewport one frame behind, before and after](files/images/fixes/viewport-one-frame-lag.gif)](https://github.com/designgears/Autodesk-Fusion-360-for-Linux/releases/download/prebuilt-wine-proton-2026.09.12/viewport-one-frame-lag-side-by-side.mp4)

Changes:

- Wine 11.17
- Qt dialogs, flyouts and the Advanced capabilities window are managed by the window manager
- The dim overlay behind dialogs no longer takes focus, clicking it activates the dialog
- Data panel fix for Wine 11.16 and newer
- Fusion's bundled d3dcompiler is used to fix viewport smearing
- Viewport and timeline no longer lag one frame behind
- GE-Proton build with the same patches
- Prebuilt Wine and Proton are downloaded from this repo's releases
- libXdamage is a required dependency

designgears' install commands (without this fork's fixes):

```
curl -L https://raw.githubusercontent.com/designgears/Autodesk-Fusion-360-for-Linux/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --install-fix --default
```

Or with the patched Proton:

```
curl -L https://raw.githubusercontent.com/designgears/Autodesk-Fusion-360-for-Linux/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --proton=GE-Proton11-Fusion --default
```

The installer downloads the prebuilt Wine or Proton from the releases here. If you'd rather build them yourself, use `--build wine-fix` or `--build proton-fix`. You'll need libXdamage, and the installer will install it if it's missing.

Everything below is cryinkfly's original README. Its install commands point at the original repo and won't get you these fixes.

---

# Autodesk Fusion 360 on Linux

<img align="center" src="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-for-Linux/raw/branch/main/files/images/autodesk-fusion-linux-logo.png" width="250px" height="250px">
</br></br>

---

<div id="locale-switch" style="display: flex; align-items: center; justify-content: center;">
  <img src="https://img.shields.io/badge/Please_choose_a_language:-ff6b00?style=for-the-badge">
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-cs_CZ.md"><img src="https://img.shields.io/badge/CZ-36342c?style=for-the-badge"></a>
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-zh_CN.md"><img src="https://img.shields.io/badge/CN-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-de_DE.md"><img src="https://img.shields.io/badge/DE-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README.md"><img src="https://img.shields.io/badge/EN-ff6b00?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-es_ES.md"><img src="https://img.shields.io/badge/ES-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-fr_FR.md"><img src="https://img.shields.io/badge/FR-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-it_IT.md"><img src="https://img.shields.io/badge/IT-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-ja_JP.md"><img src="https://img.shields.io/badge/JP-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-ko_KR.md"><img src="https://img.shields.io/badge/KR-36342c?style=for-the-badge"></a> 
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-ru_RU.md"><img src="https://img.shields.io/badge/RU-36342c?style=for-the-badge"></a>
  <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/README-tr_TR.md"><img src="https://img.shields.io/badge/TR-36342c?style=for-the-badge"></a>
</div>

---

## What is Autodesk Fusion 360?

<a href="https://www.autodesk.com/products/fusion-360/features">Autodesk Fusion 360</a> is a powerful, cloud-based platform that integrates 3D modeling, CAD, CAM, CAE, and PCB design in a single solution. However, for Linux users, accessing this application can be a challenge, as it was primarily designed for Windows and macOS.

This is where Wine comes in. Wine (which stands for "Wine Is Not an Emulator") is a compatibility layer that enables Windows applications to run on Linux, macOS, and BSD systems. Unlike traditional virtual machines or emulators, Wine doesn't simulate Windows. Instead, it translates Windows API calls into POSIX calls in real time, preserving performance and reducing overhead. This means that Windows applications can run smoothly on Linux systems without the typical performance penalties of virtual machines. Imagine running Autodesk Fusion 360 on Linux using Wine!

This would mean no need for dual-booting between Windows and Linux to use Fusion 360. You’d be able to work seamlessly on your projects without switching operating systems. For Linux users, it could be a game-changer—making Fusion 360 fully accessible while staying within the Linux ecosystem.

**Is this a good idea for the future of Autodesk Fusion 360?**

I think it’s a brilliant idea! If Fusion 360 could run on Linux via Wine, it would expand accessibility to a wider audience—especially among open-source advocates and professionals who prefer Linux for their work.

**More information about this project:**

- 🌍 [Official member of Autodesk Group Network](https://codeberg.org/cryinkfly/Autodesk-Fusion-360-for-Linux/releases/tag/v5.1) & [Fusion 360 Insider Program](https://feedback.autodesk.com/key/Fusion360Insider) — I get the latest updates straight from Autodesk!
- 🍷 [Super Application Maintainer](https://appdb.winehq.org/objectManager.php?sClass=application&iId=15617) at WineHQ—dedicated to ensuring Windows apps run smoothly on Linux.

As a fan of both Fusion 360 and Linux, I'm excited to do my part in making this a reality. By making Fusion 360 accessible on Linux, we open up new possibilities for a lot of creators and engineers who prefer Linux as their primary platform.

---


## Screenshots
<img src="https://raw.githubusercontent.com/cryinkfly/Fusion-360---Linux-Wine-Version-/main/files/images/workspaces/Manufacture/%231.1_adapter-plate.png" width="400px" height="250px">
<img src="https://github.com/cryinkfly/Autodesk-Fusion-360-for-Linux/blob/main/files/images/workspaces/Design/MacMASTER-CARR.png?raw=true" width="400px" height="250px">
<img src="https://raw.githubusercontent.com/cryinkfly/Fusion-360---Linux-Wine-Version-/main/files/images/workspaces/Generative%20Design/%231.4_generative_design.png" width="400px" height="250px"></br>
<img src="https://raw.githubusercontent.com/cryinkfly/Fusion-360---Linux-Wine-Version-/main/files/images/workspaces/Simulation/%231_study_displacement.png" width="400px" height="250px">
<img src="https://raw.githubusercontent.com/cryinkfly/Fusion-360---Linux-Wine-Version-/main/files/images/workspaces/Drawing/drawing_oil_case.png" width="400px" height="250px">
<img src="https://raw.githubusercontent.com/cryinkfly/Autodesk-Fusion-360-for-Linux/main/files/images/workspaces/Electronics/%231_air%20quality%20sensor.png" width="400px" height="250px">

---

## What can you do with Autodesk Fusion 360?

<table>
 <thead>
  <tr>
   <th>Features</th>
   <th>Description of the feature</th>
  </tr>
 </thead>
 <tbody>
  <tr>
   <td>3D design and modeling</td>
   <td>Engineer products with a comprehensive set of modeling tools. Ensure your products' form, fit, and function with diverse analysis methods.</td>
  </tr>
  <tr>
   <td>Sketching</td>
   <td>Create and edit sketches with sketch constraints, dimensions, and a powerful suite of sketch tools.</td>
  </tr>
  <tr>
   <td>Direct modeling</td>
   <td>Edit or repair imported geometry from non-native file formats. Make design changes without worrying about time-based features.</td>
  </tr>
  <tr>
   <td>Surface modeling</td>
   <td>Create and edit complex parametric surfaces for repairing, patching, or designing geometry.</td>
  </tr>
  <tr>
   <td>Parametric modeling</td>
   <td>Create history-based features, including extrude, revolve, loft, sweep, etc., that update with design changes.</td>
  </tr>
  <tr>
   <td>Mesh modeling</td>
   <td>Edit and repair imported scans or mesh models, including STL and OBJ files.</td>
  </tr>
  <tr>
   <td>Freeform modeling</td>
   <td>Create complex sub-divisional surfaces with T-splines and edit them with intuitive push-pull gestures.</td>
  </tr>
  <tr>
   <td>Rendering</td>
   <td>Create photo-realistic images of your model, leveraging local or cloud rendering.</td>
  </tr>
  <tr>
   <td>PCB design integration</td>
   <td>Synchronize bi-directional changes from your electronics designs seamlessly with Autodesk EAGLE interoperability.</td>
  </tr>
  <tr>
   <td>Sheet metal</td>
   <td>Design sheet metal part components. Document flat patterns using 2D drawings and DXFs. Manufacture your designs with cutting strategies for water jet, laser, and plasma machines.</td>
  </tr>
  <tr>
   <td>Assemblies</td>
   <td>Assemble designs with a traditional bottom-up, middle-out, or top-down approach, and analyze assembly motion.</td>
  </tr>
 </tbody>
</table>

### Do you want to learn everything about the Autodesk Fusion 360 features?

- Then visit the official <a href="https://www.youtube.com/user/AutodeskFusion360">YouTube channel</a> where you you can watch many hours of free tutorials
- Or visit the <a href="https://www.autodesk.com/products/fusion-360/features">website</a> of Autodesk Fusion 360.

---

## How much does Fusion 360 cost?

<table>
 <thead>
  <tr>
   <th>License</th>
   <th>Description of the license</th>
  </tr>
 </thead>
 <tbody>
  <tr>
   <td>Free Trial</td>
   <td>Autodesk offers a 30-day free trial after registration.</td>
  </tr>
  <tr>
   <td>Personal</td>
   <td><a href="https://www.autodesk.com/products/fusion-360/personal">Autodesk offers</a> a free, feature-limited, 1-year, renewable trial for personal use only</td>
  </tr>
  <tr>
   <td>Education</td>
   <td>Like most CAD packages, Fusion 360 offers an educational license for students, teachers, and educational institutions.</td>
  </tr>
  <tr>
   <td>Start-up</td>
   <td>There are free licenses for start-ups as well as for non-commercial private users. Companies with annual sales of less than USD 100,000 are eligible for the start-up license. But it doesn't include any of the more advanced features like generative design.</td>
  </tr>
  <tr>
   <td>Standard</td>
   <td>There have been two versions of the paid license so far: Standard and Ultimate. However, they have been merged into one version that includes all the features of the Ultimate version. Fees are incurred as part of a subscription.</td>
  </tr>
 </tbody>
</table>

### Do you want to learn everything about the Autodesk Fusion 360 subscription options?

- Then visit the <a href="https://www.autodesk.com/products/fusion-360/overview?term=1-MONTH&tab=subscription">website</a> of Autodesk Fusion 360.
</div>

---

## What is the latest version of Fusion 360?

**Complete the following steps:**

- Visit the <a href="https://www.autodesk.com/products/fusion-360/blog?s=what%27s+new">What's New in Fusion Blog</a> (where product updates for Fusion 360 are chronicled).
- Click on the latest product update (the first item in the list).
- The version number* is documented here.

>[!NOTE]
>How to check which <a href="https://knowledge.autodesk.com/support/fusion-360/troubleshooting/caas/sfdcarticles/sfdcarticles/How-to-check-what-version-of-Fusion-360-is-installed.html">version of Fusion 360</a> is being used on your system?

---

## What are the System requirements for Autodesk Fusion 360?

<table>
   <thead>
    <tr>
     <th colspan="2" rowspan="1"><b>System requirements for Autodesk Fusion 360</b></th>
    </tr>
   </thead>
   <tbody>
    <tr>
     <td><strong>Operating System</strong></td>
     <td>
     <u>Linux distributions</u>
      <ul>
       <li><p>Arch Linux, Manjaro Linux, EndeavourOS, CachyOS, ...</p></li>
       <li><p>Debian 12, Raspberry Pi Desktop, ...</p></li>
       <li><p>Debian 13</p></li>
       <li><p>Debian Testing</p></li>
       <li><p>Fedora 43</p></li>
       <li><p>Fedora Rawhide</p></li>
       <li><p>openSUSE Leap 15.6</p></li>
       <li><p>openSUSE Leap 16.0</p></li>
       <li><p>openSUSE Tumbleweed</p></li>
       <li><p>Red Hat Enterprise Linux 9.x</p></li>
       <li><p>Red Hat Enterprise Linux 10.x</p></li>
       <li><p>Ubuntu 20.04, Linux Mint 20.x, Pop!_OS 20.04, ...</p></li>
       <li><p>Ubuntu 22.04, Pop!_OS 22.04, Zorin OS 17.x, ...</p></li>
       <li><p>Ubuntu 24.04, Pop!_OS 24.04, Zorin OS 18.x, ...</p></li>
       <li><p>Ubuntu 25.04, ...</p></li>
       <li><p>NixOS</p></li>
       <li><p>Solus</p></li>
       <li><p>Void Linux</p></li>
       <li><p>Gentoo Linux</p></li>
      </ul><p><b>Note</b>: These Linux distributions are not officially supported by Autodesk!</p></td>
    </tr>
    <tr>
     <td><strong>CPU Type</strong></td>
     <td>x86-based 64-bit processor (for example, Intel Core i, AMD Ryzen series), 4 cores, 1.7 GHz or greater; 32-bit not supported</td>
    </tr>
    <tr>
     <td><strong>Memory</strong></td>
     <td>4 GB of RAM (integrated graphics recommend 6 GB or more)</td>
    </tr>
    <tr>
     <td><strong>Graphics Card</strong></td>
     <td>DirectX11 (Direct3D 10.1 or greater) = DXVK Mode <br> OpenGL (2.0 or greater) = OpenGL Mode <br> Dedicated GPU with 1 GB or more of VRAM<br> Integrated graphics with 6 GB or more of RAM
      <br><br>
      <p><b>Note 1</b>: There is a <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/wiki/Supported-Graphics-Cards">list of tested graphics cards</a> that will work with Autodesk Fusion 360 on Linux!</p>
      <p><b>Note 2</b>: If you want to use DXVK with an NVIDIA graphics card, you must disable Secure Boot in the BIOS and ensure that the latest graphics drivers are installed. This is because the NVIDIA driver modules can only be loaded when Secure Boot is disabled!</p>
     </td>
    </tr>
    <tr>
     <td><strong>Disk Space</strong></td>
     <td>3 GB of storage</td>
    </tr>
    <tr>
     <td><strong>Display Resolution</strong></td>
     <td>1366 x 768 (1920 x 1080 or greater at 100% scale recommended)</td>
    </tr>
    <tr>
     <td><strong>Pointing Device</strong></td>
     <td>HID-compliant mouse or trackpad, optional Wacom® tablet and 3Dconnexion SpaceMouse®* support
     <br><br>
      <p><b>*Note</b>: That still needs to be checked if it works on Linux!</p
     </td>
    </tr>
    <tr>
     <td><strong>Internet</strong></td>
     <td>2.5 Mbps or faster download; 500 Kbps or faster upload</td>
    </tr>
    <tr>
     <td><strong>Dependencies</strong></td>
     <td>SSL 3.0, TLS 1.2+,&nbsp; p7zip, p7zip-full, p7zip-rar, curl, wget, winbind, cabextract, wine, wine-mono, wine-gecko, winetricks; .NET Framework 4.5 (winetricks) or newer required to submit crash reports</td>
    </tr>
   </tbody>
</table>
 
<table>
   <thead>
    <tr>
     <th colspan="2" rowspan="1"><b>Recommended specs for complex modeling and processing</b></th>
    </tr>
   </thead>
   <tbody>
    <tr>
     <td><strong>CPU Type</strong></td>
     <td>3 GHz or greater, 6 or more cores</td>
    </tr>
    <tr>
     <td><strong>Memory</strong></td>
     <td>8-GB RAM or greater</td>
    </tr>
    <tr>
     <td><strong>Graphics</strong></td>
     <td>Dedicated GPU with 4 GB or more VRAM, DirectX11 (Direct3D 10.1 or greater) = DXVK Mode, OpenGL (2.0 or greater) = OpenGL Mode</td>
    </tr>
   </tbody>
</table>

### What else is there to consider when it comes to the requirements?

- Check the <a href="https://health.autodesk.com/">Health Dashboard</a>!
- You must have installed the <a href="https://github.com/lutris/docs/blob/master/InstallingDrivers.md">latest graphics driver</a>!
- You need the <a href="https://www.winehq.org/">latest version of wine (6.23 and newer)</a> and <a href="https://github.com/Winetricks/winetricks">winetricks</a>! <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/issues/244#issuecomment-1192513720">Installing yad </a> is also recomended to resolve potential instalation issues. 

And would you like to use <a href="https://apps.autodesk.com/FUSION/de/Home/Index">extra functions</a> or languages as like the Czech language later in Autodesk Fusion 360, then you need a <a href="https://apps.autodesk.com/FUSION/en/Detail/Index?id=9151466655844643882">special extension</a> what you must have bought and downloaded before you can install this with my Setup Wizard! 🧩

---

## Getting Started

- Check my <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/wiki/Documentation">GitHub-Documentation</a> & <a href="https://www.youtube.com/watch?v=-BktJspJKgs&list=PLzwMdS5iu_BIsO6RTy7Hy1MbzLMrQE2xe">Videos</a> before you install Autodesk Fusion 360 on your system!
- Check, if your <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/files/extras/network/etc">network settings</a> are correctly configured!
- Check, if your system meets all requirements</a>!
- You need an active Fusion 360 license</a>!

#### Open a terminal and run this command to install Autodesk Fusion with the Wine Z-window fix runtime:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --install-fix --default
```

The installer checks first if the local `fusion-wine-build` runtime is already available. If it is missing, it downloads the pre-built runtime from GitHub releases.

#### Open a terminal and run this command to install Autodesk Fusion with system Wine:
 
```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --install --default
```

#### Open a terminal and run this command to install Autodesk Fusion with all tested extensions:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --install --default --full
```

#### Installation with Steam Proton (experimental)

As an alternative to Wine, you can use [Steam Proton](https://github.com/ValveSoftware/Proton) to run Autodesk Fusion 360. This requires Steam to be installed and a compatible Proton version to be present in `~/.local/share/Steam/compatibilitytools.d/`. You can use [ProtonUp-Qt](https://davidotek.github.io/protonup-qt/) to easily install and manage Proton versions.

Use the `--proton=<version>` flag to specify the Proton version, for example:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --proton=GE-Proton10-32 --default
```

For the Z-window fix with Proton, use this command:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --proton=GE-Proton10-Fusion --default
```

The installer checks first if `GE-Proton10-Fusion` is installed locally in Steam compatibility tools. If it is missing, it downloads the pre-built runtime from GitHub releases.

#### Build the fix runtimes yourself (optional)

If you prefer building locally instead of using pre-built archives:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --build wine-fix
```

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --build proton-fix
```

Note: Pre-built archives are currently hosted on GitHub releases because Codeberg release uploads for this workflow exceed the file size limit.

#### Open a terminal and run this command to uninstall:

```
curl -L https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/raw/branch/main/files/setup/autodesk_fusion_installer_x86-64.sh -o "autodesk_fusion_installer_x86-64.sh" && chmod +x autodesk_fusion_installer_x86-64.sh && ./autodesk_fusion_installer_x86-64.sh --uninstall
```

#### Or you install and use Autodesk Fusion 360 as a Flatpak app: https://usebottles.com/app/#fusion

- If you have White flickering screen in Fusion

   If Fusion is open, click into Fusion and press:
   ```
   Alt + Ctrl + N
   ```
   Or if Fusion is closed, run:
   ```
   ~/.autodesk_fusion/bin/fix-navbar-flicker.sh
   ```
- For the SSO-Login bug use this Workaround: https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/issues/460#issuecomment-2315888332

- Or installing Fusion360 via Distrobox on a Gnome Wayland Desktop: https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/issues/557
- Now, You can <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/issues/44#issuecomment-890552181">use</a> Autodesk Fusion 360 on your Linux system!

### Which script releases are available?

There are some <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/files/builds">script releases</a> available, built from the release targets. It's recommended that if you're new you start with the stable builds. Development builds are available here if you need it, but correspondingly may be less stable. In the <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/src/branch/main/files/builds/dev-branch">development branch</a> you will find, for example, the upcoming versions of my setup wizard, as well as builds that run with the help of Flatpak or Docker/Podman.

---

## Which work areas and functions have I tested?

<table>
<thead>
<tr>
<th></th>
<th>Windows</th>
<th>macOS</th>
<th>Linux</th>
</tr>
</thead>
<tbody>
<tr>
<td>Construction</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<tr>
<td>Animation</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Rendering</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Production</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Simulation</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Generative Design</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Drawing</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Electronics</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Online- & Offline-Mode</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Support all languages</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>3Dconnexion SpaceMouse</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td>Scripts and additional modules</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">✅</td>
</tr>
<tr>
<td><a href="https://www.youtube.com/watch?v=YvBCIKRb_os">Voice Assistant</a>
<td style="text-align: center;">❌</td>
<td style="text-align: center;">❌</td>
<td style="text-align: center;">⚠️</td>
</tr>
<tr>
<td><a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux/issues/218">Sandbox-Mode</a>
<td style="text-align: center;">❌</td>
<td style="text-align: center;">❌</td>
<td style="text-align: center;">✅</td>
</tr>
</tbody>
</table>
</br> 
</div>

---

> [!IMPORTANT]
>With the help of my script, you get a way to install Autodesk Fusion 360 on your Linux system. Certain packages and programs that are required will be set up for you, but it's important to know, that my script only helps you to get the program to run and nothing more! And so, you must to purchase the licenses directly from the manufacturer of the program Autodesk Fusion 360!
> 
>All my scripts are released under the MIT license, see <a href="https://codeberg.org/cryinkfly/Autodesk-Fusion-360-for-Linux/src/branch/main/LICENSE.md">LICENSE.md</a> for full text.

---

## Support this project, share your ideas, and help our community thrive! ♥️ 

If you enjoy my work and want to help me create more tutorials, guides, and open-source projects, you can **support me in multiple ways** — either as a sponsor or as an active helper!  

**Ways to Support:**  
- 💰 **Sponsors:** Contribute financially to help cover hosting costs, development time, and resources  
- 🤝 **Supporters & Collaborators:** Share ideas, provide feedback, contribute tutorials or code, and help the community grow  

**Benefits of Supporting:**  
- 💡 Early access to new tutorials and resources  
- 🔒 Exclusive updates and behind-the-scenes insights  
- 🏅 Recognition on the website or in projects (optional)  
- 🌱 Helping the community thrive and learn together

**Support my work, contribute ideas, and help the community grow!**

[![Become a Sponsor or Supporter](https://img.shields.io/badge/Become%20a%20Sponsor%20or%20Supporter-%23E34C4C?style=for-the-badge&logoColor=white)](https://cryinkfly.com/contribute/)
