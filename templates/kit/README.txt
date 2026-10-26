Claude Desktop via Airia - setup kit
====================================

This kit sets up Claude Desktop on your computer to run through your
company's Airia AI Gateway, billed to your own Claude plan. It takes about
five minutes. You sign in to Claude once; after that it just works.

Before you start
----------------
- Install Claude Desktop (https://claude.ai/download) if you don't have it.
- You need administrator rights on your computer (your Mac password, or
  "Yes" on the Windows admin prompt).
- Know which Claude account to sign in with: the one your company gave you
  (Pro / Max / Team / Enterprise). Usage is billed to that account.
- Unzip the whole kit first. Don't run anything from inside the zip.

KEEP THIS KIT PRIVATE. It contains an access key issued to you. Don't
forward it, and delete the zip once you've finished.


macOS
-----
1. Open Terminal (Applications > Utilities > Terminal).
2. Type  bash  followed by a space, drag "install.sh" from the macOS folder
   into the Terminal window, and press Return.
3. Enter your Mac password when asked. (Nothing appears as you type; that's
   normal.)
4. System Settings opens. Go to General > Device Management (called
   "Profiles" on older macOS), double-click
   "Claude Desktop Third-Party Inference (User Impersonation)",
   click Install, and enter your Mac password again.
5. Quit Claude Desktop completely (Cmd+Q) if it was open, then open it.
6. A browser tab opens asking you to authorize Claude. Sign in with your
   Claude account and click Authorize. Then go back to Claude Desktop.

Doing it by hand instead of step 2:
  sudo mkdir -p /usr/local/bin
  sudo install -m 755 macOS/airia-claude-cred-helper /usr/local/bin/
  then double-click the .mobileconfig file and continue from step 4.


Windows
-------
1. Right-click the zip > Extract All.
2. Open the Windows folder and double-click "install.bat".
   - If Windows says "Windows protected your PC", click More info > Run anyway.
   - Click Yes on the administrator prompt.
3. Wait for "Imported." and press any key to close the window.
4. Quit Claude Desktop completely (right-click its icon in the system tray >
   Quit) if it was open, then open it.
5. A browser tab opens asking you to authorize Claude. Sign in with your
   Claude account and click Authorize. Then go back to Claude Desktop.

Doing it by hand instead of step 2:
  - Copy airia-claude-cred-helper.ps1 to C:\Program Files\Airia\
    (create the Airia folder).
  - Double-click the .reg file and click Yes.
Install while signed in to Windows as yourself. If an IT account approves
the admin prompt, the settings land on that account instead of yours; ask
IT to install it for you through device management.


What to expect on first launch
------------------------------
- Claude shows "Running credential helper..." while it waits for you to
  sign in. The browser tab can open BEHIND Claude Desktop, so look for it.
- If the Claude Code command-line tool isn't installed, it is installed
  automatically first. This can add a minute.
- You have about 9 minutes to finish signing in. If you miss it, quit and
  reopen Claude Desktop to get the sign-in again.
- After this you won't be asked again for about a year.


Troubleshooting
---------------
- Browser shows a warning page from the Airia browser extension instead of
  the Claude sign-in: tell your IT admin to allow claude.ai/oauth/* .
- Signed in with the wrong Claude account, or Claude keeps failing to
  connect: reset and sign in again.
    macOS:   airia-claude-cred-helper --reset
    Windows: powershell -ExecutionPolicy Bypass -File "C:\Program Files\Airia\airia-claude-cred-helper.ps1" -Reset
  then quit and reopen Claude Desktop.
- Anything else: send your IT admin a screenshot of the error.
