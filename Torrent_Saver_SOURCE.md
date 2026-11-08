# Torrent Saver — manual rebuild guide

Recreate this shortcut by hand in the **Shortcuts** app (no signed file needed).
Decoded from `Torrent_Saver.shortcut` (v3.0, 08.11.2026). 108 actions total.
One shortcut for iPhone, iPad **and Mac**: it reads the device model once. A Mac gets its own
setup menu (no iSH step) and opens the app directly; iPhone/iPad keep the v2.2 menus unchanged.

- Name the shortcut: **Torrent Saver**
- Settings ▸ turn on **Show in Share Sheet** is *not* required (this build is a launcher/menu).
  In the shortcut's details it is set to appear as an **Action Extension**, on **Apple Watch**,
  and **Show in Search**.

Search each action by the **bold name** in the editor's action picker. Indentation =
nesting; the Shortcuts editor auto-indents when you drop **Menu / Repeat / If** blocks.

---

## A. Setup (top of the shortcut)

1. **Comment** — paste:
   ```
   v3.0 08.11.2026

   One shortcut for iPhone, iPad and Mac. On a Mac there is no iSH: its own setup menu runs the same installer in Terminal (Homebrew), the backend runs in the background via launchd, and "🏴‍☠️ Torrent Saver" just opens the app.

   https://github.com/Dimoniada/claude-apple-gcTorrent

   https://www.donationalerts.com/r/dimoniada
   ```
2. **Text** = `http://127.0.0.1:5001`
3. **Set Variable** `BaseURL` = (the Text from step 2)
4. **Text** = `true`
5. **Text** = `false`
6. **Set Variable** `IsiSHRunning` = (the `false` Text, coerced to **Boolean**)
7. **Set Variable** `GoBack` = (the `false` Text, as **Boolean**)
8. **Text** = `10`
9. **Set Variable** `WaitBridgeTimeoutSec` = (the `10` Text, as **Number**)
10. **Get Device Details** → **Device Model**
11. **Set Variable** `DeviceModel` = (the Device Model from step 10)

> **Mac test used below:** `If DeviceModel contains Mac`. "Contains" rather than "is", so any
> Mac model name matches; iPhone/iPad never contain "Mac".

> **Coercion tip:** to make a variable Boolean/Number, tap the variable token → change its
> type. `IsiSHRunning` & `GoBack` are Booleans; `WaitBridgeTimeoutSec` is a Number.

> **The "Return / back button" idiom used below:** a `Repeat`+`If GoBack is off`+`Menu`
> sandwich. A menu's **⬅️ Return** item sets `GoBack = true`, which makes the `If` skip on the
> next loop pass so the inner menu closes and control falls back to the parent menu. Replicate
> it exactly or your back buttons won't work.

---

## B. Main loop

```
Repeat 1000 times
  Menu  "Torrent Saver Set up"   (3 items, in this order):
        ⚙️ Set up / reinstall
        🏴‍☠️ Torrent Saver
        🚼 Exit
```

### Case  ⚙️ Set up / reinstall
```
  Set Variable  GoBack = false
  Repeat 20 times
    If  GoBack  is off (false)
      If  DeviceModel  contains  Mac
        (MAC SETUP MENU, see the section after this one)
      Otherwise
      Menu  "⚙️ Set up / reinstall:"   (4 items):
            1) Install iSH
            2) Install backend
            🛟 Help
            ⬅️ Return
```
Everything from here to **MAC SETUP MENU** is the iPhone/iPad menu, unchanged from v2.2.
Close it with **End Menu**, then **End If** (the Mac test), then the **End If** / **End Repeat** below.

**Case  1) Install iSH**
```
        Open URLs  itms-apps://apps.apple.com/app/id1436902243
        Exit Shortcut
```

**Case  2) Install backend**
```
        If  IsiSHRunning  is off (false)
            Open App  iSH
            Set Variable  IsiSHRunning = true
        End If
        Text  (name it "install script") =
            cd /root && apk update && apk add ca-certificates wget && wget -qO install.sh https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/install.sh && sh install.sh
        Menu  "2) Install backend:"   (3 items):
              ⤵️ New install
              🔄 Update
              ⬅️ Return
```
   • **Case ⤵️ New install**
   ```
              Copy to Clipboard  (the "install script" Text)
              Show Alert   title: "Base instruction:"
                           message: (see ALERT-1 below)
              Exit Shortcut
   ```
   • **Case 🔄 Update**
   ```
              Wait   WaitBridgeTimeoutSec  seconds        (Delay)
              Get Contents of URL   [BaseURL]/detach   — Method: POST
              Copy to Clipboard  (the "install script" Text)
              Show Alert   title: "Base instruction:"
                           message: (see ALERT-1 below)
              Exit Shortcut
   ```
   • **Case ⬅️ Return** — (leave empty)

**Case  🛟 Help**
```
        Repeat 20 times
          If  GoBack  is off (false)
            Menu  "🛟 Help:"   (3 items):
                  📖 Readme
                  🔗 GitHub
                  ⬅️ Return
```
   • **Case 📖 Readme**
   ```
                Show Alert   title: "Dependencies:"
                             message: (see ALERT-2 below)
                             (turn OFF the Cancel button)
   ```
   • **Case 🔗 GitHub**
   ```
                Open URLs  https://github.com/Dimoniada/claude-apple-gcTorrent
                Exit Shortcut
   ```
   • **Case ⬅️ Return**
   ```
                Set Variable  GoBack = true
   ```
   ```
          End If
        End Repeat
        Set Variable  GoBack = false      ← reset after leaving Help
```

**Case  ⬅️ Return** (of the "⚙️ Set up / reinstall:" menu)
```
        Set Variable  GoBack = true
```
```
      End Menu
      End If          ← closes "If DeviceModel contains Mac"
    End If
  End Repeat
```

### MAC SETUP MENU (the `If DeviceModel contains Mac` branch above)
```
        Text  (name it "install script (Mac)") =
            curl -fsSL -o /tmp/gctorrent-install.sh https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/install.sh && sh /tmp/gctorrent-install.sh
        Menu  "⚙️ Set up / reinstall:"   (4 items):
              1) Install Homebrew
              2) Install / update backend
              🛟 Help
              ⬅️ Return
```
   • **Case 1) Install Homebrew**
   ```
              Text  (name it "Homebrew install") =
                  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
              Copy to Clipboard  (the "Homebrew install" Text)
              Show Alert   title: "Homebrew install:"
                           message: (see ALERT-BREW below)
                           (turn OFF the Cancel button)
              Open App  Terminal
              Exit Shortcut
   ```
   • **Case 2) Install / update backend** (no `/detach`: the installer stops the old backend itself)
   ```
              Copy to Clipboard  (the "install script (Mac)" Text)
              Show Alert   title: "Mac install:"
                           message: (see ALERT-MAC below)
                           (turn OFF the Cancel button)
              Open App  Terminal
              Exit Shortcut
   ```
   • **Case 🛟 Help**: the same block as the iPhone/iPad **🛟 Help** case, except the
     **📖 Readme** alert shows **ALERT-2-MAC** below.
   • **Case ⬅️ Return**: `Set Variable  GoBack = true`

### Case  🏴‍☠️ Torrent Saver
```
  If  DeviceModel  contains  Mac
      Open URLs  [BaseURL]/app          (launchd keeps the Mac backend running)
      Exit Shortcut
  Otherwise
      Open App  iSH
      Wait  WaitBridgeTimeoutSec  seconds
      Open URLs  [BaseURL]/app
      Exit Shortcut
  End If
```

### Case  🚼 Exit
```
  Exit Shortcut
```
```
  End Menu
End Repeat
```

---

## Long strings (copy verbatim)

**ALERT-1** (title `Base instruction:`, shown after New install / Update):
```
In iSH do long-press → Paste, press Return. This will install python3 + rtorrent + scripts in iSH 'root' folder (~60Mb). After installation approve the Location popup → iSH ▸ Location ▸ Allow when using app. In iSH options set Location→Always allow (to keep iSH in the background alive while using downloader), and re-run the shortcut, then you can use "🏴‍☠️ Torrent Saver"
```

**ALERT-2** (title `Dependencies:`, Cancel button OFF):
```
Needed:
1) iSH with Location turned to "Always allow" (for background stay-alive)
2) Free local port 5001 
3) Web connection for downloading ~60 Mb of dependencies and GitHub scripts
```

**ALERT-BREW** (title `Homebrew install:`, Cancel button OFF):
```
The Homebrew install command is copied. In Terminal press ⌘V, then Return. When asked, type your Mac password (it isn't shown) and press Return. It can take a few minutes. When it finishes, re-run the shortcut and use "2) Install / update backend".
```

**ALERT-MAC** (title `Mac install:`, Cancel button OFF):
```
The install command is copied. In Terminal press ⌘V, then Return. It needs Homebrew (brew.sh) and installs rtorrent + scripts in your home folder ▸ gctorrent. The backend then runs in the background and starts at every login; no iSH needed. Torrents are saved to your Downloads folder. When it says "Setup done", re-run the shortcut and use "🏴‍☠️ Torrent Saver"
```

**ALERT-2-MAC** (title `Dependencies:`, Cancel button OFF):
```
Needed on a Mac:
1) Homebrew (brew.sh); no iSH
2) Free local port 5001
3) Torrents are saved to your Downloads folder
```

---

## URL / value reference

| Where | Value |
|---|---|
| `BaseURL` | `http://127.0.0.1:5001` |
| iSH App Store link | `itms-apps://apps.apple.com/app/id1436902243` |
| iSH app (Open App / bundle) | `app.ish.iSH` (name **iSH**) |
| Install command | see the **install script** Text above |
| Install command (Mac) | see the **install script (Mac)** Text above |
| Mac test | `Get Device Details → Device Model`, then `If DeviceModel contains Mac` |
| Terminal (Open App, Mac) | `com.apple.Terminal` (name **Terminal**) |
| Update ping | `POST [BaseURL]/detach` |
| Launch the app UI | `Open URLs [BaseURL]/app` |
| Timeouts | `WaitBridgeTimeoutSec = 10` seconds |
| Menu-loop guards | `Repeat 1000` (outer) / `Repeat 20` (each submenu) |

That's the whole thing. The `Repeat N` counts are just large upper bounds so the menus keep
re-showing until the user picks **Return/Exit** — the numbers aren't magic.
