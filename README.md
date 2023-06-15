# Personal mpv Configuration for Windows

<p align="center"><img width=100% src="https://github.com/Zabooby/mpv-config/assets/78969986/e1acacc3-e861-42dd-9a68-465bb73feab0" alt="mpv screenshot"></p>
<p align="center"><img width=100% src="https://github.com/Zabooby/mpv-config/assets/78969986/9f514484-6011-473f-a225-7e8569bdbcd8" alt="mpv screenshot"></p>

## Overview
Just my personal config files for use in [mpv,](https://mpv.io/) a free, open-source, & cross-platform media player, with a focus on quality and a practical yet comfortable viewing experience. Contains tuned profiles (for up/downscaling, live action & anime), custom key bindings, a GUI, as well as multiple scripts, shaders & filters serving different functions. Suitable for both high and low-end computers (with some tweaks).

## Scripts and Shaders
- [uosc](https://github.com/darsain/uosc) - Adds a minimalist but highly customizable gui.
- [thumbfast](https://github.com/po5/thumbfast) - High-performance on-the-fly thumbnailer.
- [memo](https://github.com/po5/memo) - Saves watch history, and displays it in a nice menu, integrated with uosc. 
- [sview](https://github.com/he2a/mpv-scripts/blob/main/scripts/sview.lua) - Show shaders currently running, triggered on shader activation or by toggle button.
- [autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua) - Automatically load playlist entries before and after the currently playing file, by scanning the directory.
- [autodeint](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autodeint.lua) - Automatically insert the appropriate deinterlacing filter based on a short section of the current video, triggered by toggle button. 
- [webtorrent-mpv-hook](https://github.com/mrxdst/webtorrent-mpv-hook) - Adds a hook that allows mpv to stream torrents. It provides an osd overlay to show info/progress.
    - **This script needs some extra setup, follow the simple installation steps [here](https://github.com/mrxdst/webtorrent-mpv-hook#install)**.
    - **Point to the same location in the File Structure section below when installing the webtorrent.js file.**
- - - 
- [nlmeans ](https://github.com/AN3223/dotfiles/tree/master/.config/mpv/shaders) - Highly configurable and featureful denoiser.
- [NVIDIA Image Sharpening](https://gist.github.com/agyild/7e8951915b2bf24526a9343d951db214) - An adaptive-directional sharpening algorithm shaders.
- [FidelityFX CAS](https://gist.github.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6) - Sharpening shader that provides an even level of sharpness across the frame. 
- [FSRCNNX-TensorFlow](https://github.com/igv/FSRCNN-TensorFlow) - Very resource intensive upscaler that uses a neural network to upscale accurately.
- [Anime4k](https://github.com/bloc97/Anime4K) - Shaders designed to scale and enhance anime. Includes shaders for line sharpening, artefact removal, denoising, upscaling, and more.
- [AMD FidelityFX Super Resolution](https://gist.github.com/agyild/82219c545228d70c5604f865ce0b0ce5) - A spatial upscaler which provides consistent upscaling quality regardless of whether the frame is in movement.
- [mpv-prescalers](https://github.com/bjin/mpv-prescalers) - RAVU (Rapid and Accurate Video Upscaling) is a set of prescalers with an overall performance consumption design slightly higher than the built-in ewa scaler, while providing much better results. 
- [SSimDownscaler, SSimSuperRes, KrigBilateral, Adaptive Sharpen](https://gist.github.com/igv) 
    - Adaptive Sharpen: Another sharpening shader.
    - SSimDownscaler: Perceptually based downscaler.
    - KrigBilateral: Chroma scaler that uses luma information for high quality upscaling.
    - SSimSuperRes: Make corrections to the image upscaled by mpv built-in scaler (removes ringing artifacts and restores original  sharpness).
   
## Installation (on Windows)

(For Linux and macOS users, once mpv is installed, copying the contents of my `portable_config` into the [relevant](https://mpv.io/manual/master/#files) folders should be sufficient.)

* Download the latest 64bit (or 64bit-v3 for newer CPUs) mpv Windows build by shinchiro [here](https://mpv.io/installation/) or directly from [here](https://sourceforge.net/projects/mpv-player-windows/files/) and extract its contents into a folder of your choice (mine is called mpv). This is now your mpv folder and can be placed wherever you want. 
* Run `mpv-install.bat`, which is located in the `installer` folder (see below), with administrator privileges by right-clicking and selecting run as administrator, after it's done, you'll get a prompt to open Control Panel and set mpv as the default player.
* Download and extract the `portable_config` folder from this repo to the mpv folder you just made. 
* Change file paths, in [mpv.conf](https://github.com/Zabooby/mpv-config/blob/main/portable_config/mpv.conf) and 2 other files in the [script-opts](https://github.com/Zabooby/mpv-config/tree/main/portable_config/script-opts) folder (detailed below), to match where the relevant files/folders exist on your pc. 
* **Adjust any settings in [mpv.conf](https://github.com/Zabooby/mpv-config/blob/main/portable_config/mpv.conf) to fit your system, use the [manual](https://mpv.io/manual/master/) to find out what different options do or open an issue if you need any help.**
* You are good to go. Go watch some videos!

After following the steps above, your mpv folder should have the following structure:

## File Structure (on Windows)

```
mpv
|
├── doc
│   ├── manual.pdf                            
│   └── mpbindings.png                    # Default key bindings if not overridden in input.conf
│
├── installer
│   ├── configure-opengl-hq.bat
│   ├── mpv-icon.ico
│   ├── mpv-install.bat                   # Run with administrator priviledges to install mpv
│   ├── mpv-uninstall.bat                 # Run with administrator priviledges to uninstall mpv
│   └── updater.ps1
│
├── portable_config                       # This is where my config is placed 
│   ├── fonts
│   │   ├── JetBrainsMono-Regular.ttf
|   |   ├── uosc-icons.otf
|   |   └── uosc-textures.ttf
│   │
│   ├── script-opts                       # Contains configuration files for scripts
|   |   ├── memo.conf
|   |   ├── memo-history.log              
│   │   ├── thumbfast.conf                    
│   │   ├── uosc.conf                     # Set desired default directory for uosc menu here
│   │   └── webtorrent.conf               # Specify where to save downloaded videos here
│   │
│   ├── scripts      
│   │   ├── uosc_shared                    
│   │       ├── elements 
|   |           ├── BufferingIndicator.lua
|   |           ├── Button.lua
|   |           ├── Controls.lua
|   |           ├── Curtain.lua
|   |           ├── CycleButton.lua
|   |           ├── Element.lua
|   |           ├── Elements.lua
|   |           ├── Menu.lua
|   |           ├── PauseIndicator.lua
|   |           ├── Speed.lua
|   |           ├── Timeline.lua
|   |           ├── TopBar.lua
|   |           ├── Volume.lua
|   |           └── WindowBorder.lua
|   |       ├── intl
|   |           ├── de.lua
|   |           ├── es.lua
|   |           ├── fr.lua
|   |           ├── ro.lua
|   |           └── zh-hans.lua
|   |       ├── lib
|   |           ├── ass.lua
|   |           ├── intl.lua
|   |           ├── menus.lua
|   |           ├── std.lua
|   |           ├── text.lua
|   |           └── utils.lua
|   |       └── main.lua
│   │
│   │   ├── autodeint.lua                 # Set key binding here, not input.conf (Ctrl+d)
│   │   ├── autoload.lua                    
|   |   ├── memo.lua
|   |   ├── sview.lua
│   │   ├── thumbfast.lua                     
│   │   ├── uosc.lua
│   │   └── webtorrent.js                 # Point here when setting up webtorrent script
│   │
│   ├── shaders                           # Contains external shaders
│   │   ├── A4K_Dark.glsl                         
│   │   ├── A4K_Thin.glsl
│   │   ├── A4K_Upscale_L.glsl
│   │   ├── adasharp.glsl                     
│   │   ├── adasharpA.glsl                # Adjusted for anime
│   │   ├── CAS.glsl
│   │   ├── F8.glsl
│   │   ├── F8_LA.glsl
│   │   ├── FSR.glsl
│   │   ├── krigbl.glsl
│   │   ├── nlmeans_hq_m.glsl                 
│   │   ├── nlmeans_hqx.glsl
│   │   ├── NVSharpen.glsl
│   │   ├── ravu_L_r4.hook
│   │   ├── ravu_Z_r3.hook
│   │   ├── ssimds.glsl
│   │   └── ssimsr.glsl
│   │
|   ├── watch_later                       # Video timestamps saved here (created automatically)
|   ├── fonts.conf                        # Delete duplicate when installing in steps above 
│   ├── input.conf                        # Tweak uosc right click menu here
│   ├── mpv.conf                          # General anime profile here 
|   └── profiles.conf                     # Up/downscale and more anime profiles here
|   
├── d3dcompiler_43.dll
├── mpv.com
├── mpv.exe                               # The mpv executable file
└── updater.bat                           # Run with administrator priviledges to update mpv
```

## Key Bindings
Custom key bindings can be added/edited in the [input.conf](https://github.com/Zabooby/mpv-config/blob/main/portable_config/input.conf) file. Refer to the [manual](https://mpv.io/manual/master/) and [uosc](https://github.com/tomasklaen/uosc#commands) commands for making any changes. Default key bindings can be seen from the [input.conf](https://github.com/Zabooby/mpv-config/blob/main/portable_config/input.conf) file but most of the player functions can be used through the menu accessed by `Right Click` and the buttons above the timeline as seen in the image above.

## Useful Links

* [mpv wiki](https://github.com/mpv-player/mpv/wiki) - Official wiki with links to user scripts, FAQ's and much more.
* [Mathematical evaluation of various scalers](https://artoriuz.github.io/blog/mpv_upscaling.html) - My config uses the best scalers/settings from this analysis.
* [To-do's](https://github.com/users/Zabooby/projects/1) - Just a list of things I plan to test, implement or improve in my config, (click on items for more information). 
* [mpv manual](https://mpv.io/manual/master/) - Lists all the settings and configuration options available including video/audio filters, scripting, and countless other customizations. 

Huge shoutout to [@he2a](https://github.com/he2a) for their [config,](https://github.com/he2a/mpv-config) lots of my setup is inspired by it.
